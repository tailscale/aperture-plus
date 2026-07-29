// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

import Foundation

let kJsonNewline = UInt8(ascii: "\n")

/// A MessageConsumer consumes incoming messages from the IPNBus and handles any
/// potential errors.
public protocol MessageConsumer: Actor {
     func notify(_ notify: Ipn.Notify)
     func error(_ error: Error)
}


/// MessageProcessor pulls queued Decodable messages from a MessageReader, deserializes them
/// and forwards the deserialized objects and any errors to the consumer.
public class MessageProcessor: @unchecked Sendable {
    let consumer: any MessageConsumer
    let reader: MessageReader
    let workQueue = OperationQueue()
    var logger: LogSink?


    private let stateLock = NSLock()
    private var cancelled = false
    private var drainScheduled = false
    private var drainRequested = false

    init(consumer: any MessageConsumer, logger: LogSink?) async {
        workQueue.maxConcurrentOperationCount = 1
        workQueue.name = "io.tailscale.ipn.MessageProcessor.workQueue"

        self.logger = logger
        self.consumer = consumer
        self.reader = MessageReader()
    }

    deinit {
        cancel()
        reader.stop()
    }

    func start(_ request: URLRequest, config: URLSessionConfiguration, errorHandler: (@Sendable (Error) -> Void)? = nil) {
        workQueue.addOperation { [weak self] in
            guard let self = self else { return }
            logger?.log("Starting MessageProcessor for \(request.url?.absoluteString ?? "nil")")
            cancel()
            let errorHandler = errorHandler ?? { [weak self] error in
                self?.processError(error)
            }

            stateLock.withLock {
                cancelled = false
                drainScheduled = false
                drainRequested = false
            }
            reader.start(
                request,
                config: config,
                messagesAvailableHandler: { [weak self] in self?.messagesAvailable() },
                errorHandler: errorHandler
            )
        }
    }

    public func cancel() {
        stateLock.withLock {
            cancelled = true
            drainScheduled = false
            drainRequested = false
        }
        reader.stop()
    }

    /// Edge-triggered by MessageReader's URLSession delegate as soon as a
    /// complete message arrives. Coalesces bursts into one drain operation,
    /// while a post-drain reschedule closes the arrival race without polling.
    private func messagesAvailable() {
        let shouldDrain = stateLock.withLock {
            guard !cancelled else { return false }
            if drainScheduled {
                drainRequested = true
                return false
            }
            drainScheduled = true
            return true
        }
        guard shouldDrain else { return }
        reader.drain { [weak self] messages in
            guard let self else { return }
            let redrain = stateLock.withLock {
                drainScheduled = false
                let requested = drainRequested
                drainRequested = false
                return requested
            }
            for message in messages {
                processMessage(message)
            }
            // If bytes arrived after drain captured the queue but before the
            // flag was cleared, their signal was coalesced. Drain once more to
            // close that race without periodic wakeups.
            if redrain { messagesAvailable() }
        }
    }

    func processMessage(_ data: Data) {
        workQueue.addOperation { [weak self] in
            guard let self else { return }
            let lines = data.split(separator: kJsonNewline)
            for line in lines {
                do {
                    let notify = try JSONDecoder().decode(Ipn.Notify.self, from: line)
                    Task {
                        await consumer.notify(notify)
                    }
                } catch {
                    let path: String
                    let detail: String
                    switch error {
                    case let DecodingError.keyNotFound(key, context):
                        path = Self.codingPath(context.codingPath, appending: key)
                        detail = "keyNotFound(\(key.stringValue)): \(context.debugDescription)"
                    case let DecodingError.typeMismatch(type, context):
                        path = Self.codingPath(context.codingPath)
                        detail = "typeMismatch(\(type)): \(context.debugDescription)"
                    case let DecodingError.valueNotFound(type, context):
                        path = Self.codingPath(context.codingPath)
                        detail = "valueNotFound(\(type)): \(context.debugDescription)"
                    case let DecodingError.dataCorrupted(context):
                        path = Self.codingPath(context.codingPath)
                        detail = "dataCorrupted: \(context.debugDescription)"
                    default:
                        path = "<unknown>"
                        detail = String(describing: error)
                    }
                    logger?.log("Failed to decode IPN message at \(path): \(detail)")
                    // Keep the raw payload as a second line for diagnostics,
                    // but put the actionable decoding error first so it is not
                    // hidden behind a multi-kilobyte netmap dump.
                    logger?.log("Undecodable IPN payload: \(String(data: line, encoding: .utf8) ?? "<non-UTF8>")")
                }
            }
        }
    }

    private static func codingPath(_ path: [any CodingKey], appending key: (any CodingKey)? = nil) -> String {
        let keys = path + (key.map { [$0] } ?? [])
        guard !keys.isEmpty else { return "<root>" }
        return keys.map { key in
            if let index = key.intValue { return "[\(index)]" }
            return key.stringValue
        }.joined(separator: ".").replacingOccurrences(of: ".[", with: "[")
    }

    func processError(_ error: Error) {
        Task {
            await consumer.error(error)
        }
    }
}
