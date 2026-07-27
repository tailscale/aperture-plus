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
    @State private var lines: [String] = []
    @State private var total: Int = 0
    @State private var autoRefresh: Bool = true
    @State private var copied: Bool = false

    /// Re-read the ring buffer periodically so the view is live while browsing
    /// in another tab (the log keeps accumulating behind this sheet).
    private let tick = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private var filtered: [String] {
        let f = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !f.isEmpty else { return lines }
        return lines.filter { $0.lowercased().contains(f) }
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
                                ForEach(Array(filtered.enumerated()), id: \.offset) { idx, line in
                                    Text(line)
                                        .font(.system(size: 11, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .foregroundStyle(color(for: line))
                                        .id(idx)
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
                        UIPasteboard.general.string = filtered.joined(separator: "\n")
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityIdentifier("log-copy-button")
                }
            }
            .onAppear(perform: refresh)
            .onReceive(tick) { (_: Date) in
                if autoRefresh { refresh() }
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

    private func refresh() {
        lines = LogRing.shared.snapshot()
        total = LogRing.shared.totalLogged
    }
}
