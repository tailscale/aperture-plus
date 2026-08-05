//  Created by Jonathan Nobels on 2025-12-19.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    var dismissAction: () -> Void

    @State private var showLogoutAlert: Bool = false
    @State private var togglingExitNode: Bool = false
    @State private var routeTestHost: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Name")) {
                    TextField("Tailnet HostName", text: $viewModel.tailnetHostName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit {
                            viewModel.setTailnetHostName(viewModel.tailnetHostName)
                        }
                    Text("The name of this node on your Tailnet")
                        .font(Font.caption2)
                }

                Section(header: Text("Home Page")) {
                    TextField("Home Page", text: $viewModel.homePage)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("home-page-field")
                        // Persist on every change — not only on Submit (Return).
                        // A fresh SettingsViewModel is built each time the
                        // settings cover is presented, and it seeds `homePage`
                        // from UserDefaults, so a value that was never written
                        // back (e.g. the user typed a URL then tapped Done
                        // without pressing Return) would be lost on reopen.
                        .onChange(of: viewModel.homePage) { _, newValue in
                            viewModel.setHomePage(newValue)
                        }
                }

                Section(header: Text("Exit Node")) {
                    Toggle(isOn: Binding(
                        get: { viewModel.exitNodeEnabled },
                        set: { newValue in
                            togglingExitNode = true
                            viewModel.setExitNodeEnabled(newValue)
                            // UI will update via Combine when prefs arrives
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                togglingExitNode = false
                            }
                        }
                    )) {
                        HStack {
                            Text("Enable Auto Exit Node")
                            if togglingExitNode {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .accessibilityIdentifier("exit-node-toggle")
                    HStack {
                        Text("Current Exit Node")
                        Spacer()
                        Text(viewModel.exitNodeDisplayName)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    // Live diagnostic banner: shows how many exit nodes are
                    // available, and the egress IP a fetch through tsnet sees
                    // (or the error — a blackhole makes it fail). This is the
                    // ground truth for whether the toggle actually does
                    // anything: with 0 exit nodes, `auto:any` blackholes all
                    // non-tailnet traffic, so the ipify fetch through the SOCKS
                    // proxy should FAIL.
                    if let diag = viewModel.exitNodeDiagnostic {
                        exitNodeDiagnosticBanner(diag)
                    }
                }

                Section {
                    // Red (destructive) so Logout doesn't read as the
                    // tempting default blue "go" button — it deletes the
                    // entire session and all of its local data.
                    StatusButton(text: "Logout",
                                 action: { showLogoutAlert = true },
                                 color: .red)
                        .accessibilityIdentifier("logout-button")
                }

                // Diagnostics last: this section is informational and can be
                // long (it lists every proxy rule), so keeping it below Logout
                // leaves the primary controls above the fold.
                routingSection
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismissAction() }
                        .accessibilityIdentifier("settings-done-button")
                }
            }
            .alert("Logout", isPresented: $showLogoutAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Logout", role: .destructive) {
                    viewModel.logout()
                    dismissAction()
                }
            } message: {
                Text("This will delete this session, including its tabs, bookmarks, and website data.")
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            // Seed the exit-node diagnostic (availability + egress IP) so the
            // banner is populated when Settings opens, not only after a toggle.
            viewModel.runExitNodeDiagnostic()
        }
    }

    // MARK: - Routing (split tunnel) diagnostic

    /// Shows which hosts are routed through the tsnet proxy and lets the user
    /// test any host. This exists because the iPad that hit the `-1000`
    /// ("invalid URL") bug can't be attached to a Mac, so `log stream` is
    /// unavailable — this is the on-device ground truth for the split tunnel.
    @ViewBuilder
    private var routingSection: some View {
        Section(header: Text("Routing")) {
            if viewModel.proxyEverything {
                Text("⚠️ ALL traffic is going through the tailnet (Exit Node is on). Public sites only work if the exit node is actually working — otherwise they fail with “invalid URL”. Turn Exit Node off to browse the internet directly.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("routing-proxy-everything-warning")
            } else if let policy = viewModel.proxyPolicy {
                Text("Tailnet hosts go through the proxy; everything else loads directly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(policy.matchDomains.count) proxy rule(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("routing-rule-count")
                DisclosureGroup("Show rules") {
                    ForEach(policy.matchDomains, id: \.self) { rule in
                        Text(rule)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .accessibilityIdentifier("routing-rules-disclosure")
                if !policy.shortNamesWithheldAsPublicTLD.isEmpty {
                    Text("Short names also matching a public domain (reached via their full tailnet name): \(policy.shortNamesWithheldAsPublicTLD.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("routing-withheld-names")
                }
            } else {
                Text("Not connected yet — no routing rules applied.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("routing-not-connected")
            }

            TextField("Test a host or URL", text: $routeTestHost)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityIdentifier("routing-test-field")
            if let explanation = viewModel.routeExplanation(for: routeTestHost) {
                Text(explanation)
                    .font(.caption.monospaced())
                    .foregroundStyle(explanation.contains("DIRECT") ? Color.secondary : Color.green)
                    .accessibilityIdentifier("routing-test-result")
            }
        }
    }

    // MARK: - Exit node diagnostic banner

    /// The banner shown inside the Exit Node section: availability + egress IP
    /// (or error). Color-coded: orange when there are no exit nodes (toggling
    /// would blackhole internet), green when the fetch succeeded, red on fetch
    /// error.
    @ViewBuilder
    private func exitNodeDiagnosticBanner(_ diag: ExitNodeDiagnostic) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Availability line.
            if diag.availableExitNodeCount == 0 {
                Text("⚠️ No exit nodes in your tailnet — enabling will blackhole internet through tsnet.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("exit-node-none-available")
            } else {
                Text("\(diag.availableExitNodeCount) exit node(s) available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("exit-node-available-count")
            }

            // Egress IP / error line.
            if diag.fetching {
                Text("Checking tsnet egress IP…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("exit-node-fetching")
            } else if let ip = diag.fetchedIP {
                Text("tsnet egress IP: \(ip)")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("exit-node-egress-ip")
            } else if let err = diag.fetchError {
                Text("tsnet fetch failed: \(err)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("exit-node-fetch-error")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("exit-node-diagnostic-banner")
    }
}
