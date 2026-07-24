//  CrashCapture.swift
//  Aperture
//
//  Captures Go runtime panic/fatal output (and tsnet's own logs) to files in
//  the app container, and surfaces a previous run's crash dump on the next
//  launch via os_log (and, for UI tests, a debug label).
//
//  WHY THIS EXISTS
//
//  The overnight TestFlight crash was a SIGABRT raised from inside TailscaleKit
//  (the Go runtime hit a fatal condition, printed "panic:"/"fatal error:" plus
//  a goroutine stack dump to stderr (fd 2), then called kill(getpid(), SIGABRT)).
//  The crash report proved the *mechanism* but not the *reason*, because:
//
//    1. TailscaleKit is a precompiled, stripped xcframework, so every Go frame
//       showed as "TailscaleKit + <offset>" with no symbol. Fixed separately by
//       building libtailscale without `-ldflags -w` and bundling the dSYM.
//
//    2. The Go runtime writes its fatal/panic output to fd 2 (stderr), and
//       Aperture never redirected or captured fd 2 — `Logger.logFileHandle`
//       was nil (so tsnet's `s.s.Logf` went nowhere), and Go *runtime* panics
//       bypass `LogSink` entirely and write straight to fd 2. iOS does not
//       persist a dying process's stderr anywhere, so the panic message + stack
//       were lost with the process.
//
//  WHAT THIS DOES
//
//  At launch (before the tsnet node is created):
//
//    • Surface previous crash: if the previous run left a non-empty stderr.log
//      containing a Go fatal signature ("panic:" / "fatal error:" / "goroutine "),
//      log its contents through os_log under the io.tailscale.Aperture subsystem
//      so `log show --predicate 'process == "Aperture"'` reveals the reason that
//      was missing from the crash report, then rotate it to stderr.previous.log.
//
//    • Redirect stderr: dup2 a fresh stderr.log onto fd 2. The Go runtime's
//      fatal/panic output (and only that — os_log uses the logging daemon, not
//      fd 2; print() uses stdout) is now persisted to a file that survives the
//      crash and is retrievable from the app container.
//
//    • Capture tsnet logs: open tsnet.log and assign its fd to
//      `logger.logFileHandle` so TailscaleNode.init passes it to
//      `tailscale_set_logfd`, routing tsnet's own `s.s.Logf` output to a file
//      too. (tsnet.log is separate from stderr.log so stderr.log stays empty
//      unless a Go runtime fatal actually occurs — that's what makes the
//      "non-empty + signature = crashed" heuristic reliable.)
//
//  This mirrors the idea of the mature iOS app's `filch`-based stderr capture
//  (../ts/corp/xcode/ipn-go-bridge/log.go) — minus filch/logtail, which pull in
//  the full tailscale.com logging stack that libtailscale deliberately omits.
//
//  We deliberately do NOT skip the stderr redirect when running under the Xcode
//  debugger (the mature app does, because its `filch`/ReplaceStderr would also
//  swallow os_log's stderr mirror). Our redirect targets only fd 2, which os_log
//  doesn't use, so redirecting under the debugger is safe — and it keeps the
//  crash-capture UI test deterministic under `xcodebuild test`.

import Foundation
import Darwin
import os
import SwiftUI

enum CrashCapture {
    /// Directory for crash/tsnet logs, in the app's persistent Application
    /// Support (survives across launches and reboots, unlike NSTemporary).
    @MainActor static var logDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appending(path: "Aperture/Logs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir
    }()

    /// stderr.log (Go runtime panic/fatal output) from the PREVIOUS run,
    /// surfaced on the next launch. nil if there was no crash to report.
    /// Starts at the first crash-signature line (see surfacePreviousCapture).
    @MainActor static var previousCaptureSummary: String?

    /// The first crash-signature line from the previous run (e.g.
    /// "panic: TsnetCrashTest: ..." or "fatal error: ..."), for the UI test's
    /// short status assertion. nil if there was no crash.
    @MainActor static var previousCaptureHeadline: String?

    /// Set by the `-UITestCrashReport` launch arg so a UI test can read back
    /// `previousCaptureSummary` through a debug label (see CrashCaptureDebugView).
    @MainActor static var shouldShowDebugReport: Bool = false

    /// fd of the current run's stderr.log; kept open for the app's lifetime so
    /// the Go runtime can write to fd 2.
    @MainActor private static var stderrFd: Int32 = -1

    /// fd of tsnet.log, handed to `logger.logFileHandle` for `tailscale_set_logfd`.
    @MainActor private static var tsnetLogFd: Int32 = -1

    @MainActor private static var started = false

    /// Subsystem/category for the previous-crash surfacing (separate category
    /// so it's easy to grep for: `log show --predicate 'category == "crash"'`).
    nonisolated static let crashLog = OSLog(subsystem: ApertureLog.subsystem,
                                            category: "crash")

    /// Called once at launch, before the tsnet node is created. See the file
    /// header for the full rationale.
    @MainActor
    static func start() {
        guard !started else { return }
        started = true

        let args = ProcessInfo.processInfo.arguments
        shouldShowDebugReport = args.contains("-UITestCrashReport")

        // UI-test hook: start from a clean slate so the test's phase-1 crash is
        // the only thing in stderr.log. Harmless in normal use — the launch
        // argument is never set outside UI tests.
        if args.contains("-UITestClearCrashLogs") {
            clearCrashLogs()
        }

        // 1. Surface a crash from the previous run (if any) BEFORE reopening
        //    stderr.log, so we read the previous run's output, not our own.
        surfacePreviousCapture()

        // 2. Redirect fd 2 (Go runtime panic/fatal output) to a fresh stderr.log
        //    for THIS run. tsnet's own logs are routed to tsnet.log (step 3) via
        //    `tailscale_set_logfd`, which also redirects Go's stdlib `log` package,
        //    so only the Go runtime's own panic/fatal output (written directly to
        //    fd 2) reaches stderr.log — it stays empty unless a Go fatal occurs.
        //    (Under the Xcode debugger os_log mirrors to stderr too; the surfacing
        //    step skips past that noise via crashSignatures.)
        redirectStderr()

        // 3. Open tsnet.log and route tsnet's own `s.s.Logf` output to it via
        //    `tailscale_set_logfd` (TailscaleNode.init reads logFileHandle).
        openTsnetLog()
    }

    // MARK: - Previous crash

    /// Strings that appear in Go runtime fatal/panic output. Used to distinguish
    /// "the previous run crashed" from "stray bytes on stderr".
    private static let crashSignatures = ["panic:", "fatal error:", "goroutine ", "runtime: out of memory"]

    @MainActor
    static func surfacePreviousCapture() {
        let url = logDir.appending(path: "stderr.log")
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let text = String(data: data, encoding: .utf8), !text.isEmpty
        else { return }

        // Locate the first line that looks like a Go runtime fatal. Under the
        // XCUITest/Xcode debugger, os_log mirrors to stderr (fd 2), so stderr.log
        // can contain os_log noise AHEAD of the actual panic — skip past it to
        // the real crash line. In a real (TestFlight, no debugger) crash there's
        // no os_log mirroring, so the panic is the first line and this is a no-op.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let crashLineIdx = lines.firstIndex(where: { line in
            crashSignatures.contains { line.contains($0) }
        }) else {
            // No Go fatal signature — not a crash. Rotate it out silently so it
            // doesn't linger and false-positive a later run.
            try? FileManager.default.removeItem(at: url)
            return
        }

        let headline = String(lines[crashLineIdx]).trimmingCharacters(in: .whitespaces)
        // Summary = from the crash line onward (skips preceding os_log noise),
        // capped so the in-memory/os_log/UI copy stays manageable. The full
        // dump remains on disk in stderr.previous.log.
        let fromCrash = lines[crashLineIdx...].joined(separator: "\n")
        let summary = String(fromCrash.prefix(4000))
        previousCaptureHeadline = headline
        previousCaptureSummary = summary

        // Emit through unified logging so the reason shows up in
        // `log show --predicate 'process == "Aperture"'` — exactly the signal
        // that was missing from the overnight TestFlight crash report.
        os_log("=== PREVIOUS RUN CAPTURED GO RUNTIME FATAL (stderr.log) ===",
               log: crashLog, type: .error)
        os_log("%{public}@", log: crashLog, type: .error, summary)
        os_log("=== END PREVIOUS RUN CAPTURE ===", log: crashLog, type: .error)

        // Rotate so we don't re-surface the same crash on every subsequent launch.
        let prev = logDir.appending(path: "stderr.previous.log")
        try? FileManager.default.removeItem(at: prev)
        try? FileManager.default.moveItem(at: url, to: prev)
    }

    // MARK: - stderr redirect

    @MainActor
    static func redirectStderr() {
        let url = logDir.appending(path: "stderr.log")
        let path = url.path
        // O_TRUNC: start each run fresh; the previous run's output was already
        // surfaced/rotated above.
        let fd = path.withCString { cstr -> Int32 in
            Darwin.open(cstr, O_WRONLY | O_CREAT | O_TRUNC, mode_t(0o644))
        }
        guard fd >= 0 else {
            os_log("CrashCapture: open(stderr.log) failed: %d", log: crashLog, type: .error, errno)
            return
        }
        if Darwin.dup2(fd, STDERR_FILENO) < 0 {
            os_log("CrashCapture: dup2(stderr) failed: %d", log: crashLog, type: .error, errno)
            Darwin.close(fd)
            return
        }
        // Keep `fd` (now a duplicate of fd 2) open for the lifetime of the run
        // so the Go runtime can write to fd 2 at any time. (dup2 leaves both fds
        // valid; we could close the original, but holding it is harmless and
        // makes the intent explicit.)
        stderrFd = fd
    }

    // MARK: - tsnet log

    @MainActor
    static func openTsnetLog() {
        let url = logDir.appending(path: "tsnet.log")
        // Rotate if it's grown large, so an overnight run can't balloon it.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64, size > 4 * 1024 * 1024 {
            let old = logDir.appending(path: "tsnet.log.old")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        let fd = url.path.withCString { cstr -> Int32 in
            Darwin.open(cstr, O_WRONLY | O_CREAT | O_APPEND, mode_t(0o644))
        }
        guard fd >= 0 else {
            os_log("CrashCapture: open(tsnet.log) failed: %d", log: crashLog, type: .error, errno)
            return
        }
        tsnetLogFd = fd
        // TailscaleNode.init reads `logger.logFileHandle` (which is backed by
        // this global) and calls `tailscale_set_logfd` with it, routing tsnet's
        // `s.s.Logf` output here. See TSNet/Logging.swift.
        tsnetLogFileHandle = fd
    }

    @MainActor
    static func clearCrashLogs() {
        let names = ["stderr.log", "stderr.previous.log"]
        for name in names {
            try? FileManager.default.removeItem(at: logDir.appending(path: name))
        }
    }
}

// MARK: - Debug surface for the crash-capture UI test

/// A tiny, top-anchored label that exposes `CrashCapture.previousCaptureSummary`
/// under the `crash-capture-debug` accessibility identifier. Only shown when the
/// `-UITestCrashReport` launch argument is set, so it's invisible in normal use.
/// The UI test relaunches with that arg after inducing a crash and asserts the
/// label carries the captured "panic: TsnetCrashTest: ..." text.
struct CrashCaptureDebugView: View {
    /// First line of the captured dump (the "panic: ..." / "fatal error: ..."
    /// line), or a sentinel if there was no crash. Surfaced under its own
    /// identifier so the UI test can assert on a short, reliable string instead
    /// of a multi-kilobyte goroutine stack dump.
    private var statusLine: String {
        guard let h = CrashCapture.previousCaptureHeadline, !h.isEmpty else {
            return "NO CAPTURE"
        }
        return "CAPTURED: " + h
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(statusLine)
                .font(.caption.bold())
                .foregroundStyle(.red)
                .accessibilityIdentifier("crash-capture-status")
            ScrollView {
                // `.accessibilityIdentifier` on a Text exposes the identifier;
                // the element's `label` (what XCUITest reads) is the text content.
                Text(CrashCapture.previousCaptureSummary ?? "<no previous capture>")
                    .font(.system(size: 10, design: .monospaced))
                    .accessibilityIdentifier("crash-capture-debug")
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 240)
        }
        .padding(8)
        .background(.thinMaterial)
        .overlay(Rectangle().stroke(.red, lineWidth: 1))
        .padding(.top, 40)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }
}
