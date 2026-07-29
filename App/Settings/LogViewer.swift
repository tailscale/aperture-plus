//
//  LogViewer.swift
//  Aperture
//
//  Shows the app's own recent log messages (from `LogRing`) inside the app.
//
//  This is the diagnostic channel for devices that can't be attached to a Mac
//  — no `log stream`, no Console.app. Every libtailscale/tsnet message and every
//  `logger.log(…)` call funnels through `Logger.log`, which feeds `LogRing`, so
//  this shows both. In particular it shows the `socks[n]` lines from
//  `SocksLogProxy`: which hosts reached the tailnet proxy and what the proxy
//  said about each — the key evidence for the "invalid URL" (-1000) failures.
//
//  Includes a filter box (default `socks` — the interesting lines) and Copy, so
//  the log can be pasted elsewhere. Newest lines are at the bottom.
//

import Combine
import SwiftUI
import UIKit

struct LogViewer: View {
    var dismissAction: () -> Void

    /// Pre-filled with `socks` because that's the reason this screen exists;
    /// clear it to see everything.
    @State private var filter: String = "socks"
    @State private var lines: [LogRing.Entry] = []
    @State private var filtered: [LogRing.Entry] = []
    @State private var total: Int = 0
    @State private var snapshotVersion: UInt64 = 0
    @State private var autoRefresh: Bool = true
    @State private var copied: Bool = false

    /// Re-read the ring buffer periodically so the view is live while browsing
    /// in another tab (the log keeps accumulating behind this sheet).
    private let tick = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private struct FilterRequest: Equatable, Sendable {
        let version: UInt64
        let text: String
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(.secondary)
                    TextField("Filter (e.g. socks, proxyConfig, error)", text: $filter)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.callout)
                        .accessibilityIdentifier("log-filter-field")
                    if !filter.isEmpty {
                        Button {
                            filter = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("log-filter-clear")
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()

                if filtered.isEmpty {
                    ContentUnavailableView(
                        lines.isEmpty ? "No log messages yet" : "No matching lines",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text(lines.isEmpty
                            ? "Messages appear here as the tailnet connects and pages load."
                            : "Nothing matches “\(filter)”. Clear the filter to see all \(lines.count) lines."))
                        .accessibilityIdentifier("log-empty")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(filtered) { entry in
                                    Text(entry.line)
                                        .font(.system(size: 11, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .foregroundStyle(color(for: entry.line))
                                }
                                // Anchor so we can pin to the newest line.
                                Color.clear.frame(height: 1).id("log-bottom")
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                        }
                        .accessibilityIdentifier("log-scroll")
                        .onChange(of: filtered.count) { _, _ in
                            guard autoRefresh else { return }
                            withAnimation(.none) { proxy.scrollTo("log-bottom", anchor: .bottom) }
                        }
                        .onAppear {
                            proxy.scrollTo("log-bottom", anchor: .bottom)
                        }
                    }
                }

                Divider()

                HStack {
                    Text(statusLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("log-status")
                    Spacer()
                    Toggle("Live", isOn: $autoRefresh)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityIdentifier("log-live-toggle")
                    Text("Live").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            .navigationTitle("Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismissAction() }
                        .accessibilityIdentifier("log-done-button")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        let entries = filtered
                        Task {
                            let text = await Task.detached(priority: .userInitiated) {
                                entries.map(\.line).joined(separator: "\n")
                            }.value
                            guard !Task.isCancelled else { return }
                            UIPasteboard.general.string = text
                            copied = true
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityIdentifier("log-copy-button")
                }
            }
            .task {
                await refresh()
            }
            .task(id: FilterRequest(version: snapshotVersion, text: filter)) {
                await updateFilter()
            }
            .onReceive(tick) { (_: Date) in
                guard autoRefresh else { return }
                Task { await refresh() }
            }
        }
    }

    private var statusLine: String {
        let shown = filtered.count
        let held = lines.count
        var s = "\(shown) shown / \(held) held"
        if total > held { s += " / \(total) total (older dropped)" }
        return s
    }

    /// Tint the lines that matter: proxy failures red, successes green, routing
    /// decisions blue. Everything else stays default.
    private func color(for line: String) -> Color {
        let l = line.lowercased()
        if l.contains("failed") || l.contains("error") { return .red }
        if l.contains("socks[") && l.contains(" ok ") { return .green }
        if l.contains("proxyconfig:") || l.contains("split tunnel") { return .blue }
        return .primary
    }

    /// Copying a wrapped ring can allocate and contend with log writers. Keep
    /// all of that work off the main actor so presenting/dismissing the sheet
    /// and its toolbar never wait for the logging lock.
    private func refresh() async {
        let snapshot = await Task.detached(priority: .utility) {
            LogRing.shared.snapshot()
        }.value
        // Concurrent timer refreshes can finish out of order; never roll the
        // view back to an older snapshot.
        guard snapshot.version > snapshotVersion else { return }
        lines = snapshot.entries
        total = snapshot.total
        snapshotVersion = snapshot.version
    }

    /// Lowercasing and searching thousands of lines is also background work.
    /// `.task(id:)` cancels obsolete searches as the user types or logs arrive.
    private func updateFilter() async {
        let source = lines
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let result = await Task.detached(priority: .userInitiated) {
            guard !query.isEmpty else { return source }
            return source.filter { $0.line.lowercased().contains(query) }
        }.value
        guard !Task.isCancelled else { return }
        filtered = result
    }
}
