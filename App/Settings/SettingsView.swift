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
        settingsContainer
#if os(macOS)
        // Keep the shared, single-column grouped form used on iOS instead of
        // macOS's default two-column preferences layout. The latter turns
        // TextField prompts into a second label column and leaves large,
        // uneven gaps between these phone-sized settings sections.
        .frame(minWidth: 480, idealWidth: 520, minHeight: 560, idealHeight: 660)
#endif
#if canImport(UIKit)
        .presentationDetents([.medium, .large])
#endif
        .onAppear {
            // Seed the exit-node diagnostic (availability + egress IP) so the
            // banner is populated when Settings opens, not only after a toggle.
            viewModel.runExitNodeDiagnostic()
        }
    }

    @ViewBuilder
    private var settingsContainer: some View {
#if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.title2.bold())
                Spacer()
                Button("Done") { dismissAction() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("settings-done-button")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            settingsForm
                .formStyle(.grouped)
        }
        .alert("Logout", isPresented: $showLogoutAlert) {
            logoutAlertActions
        } message: {
            logoutAlertMessage
        }
#else
        NavigationStack {
            settingsForm
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismissAction() }
                        .accessibilityIdentifier("settings-done-button")
                }
            }
        }
        .alert("Logout", isPresented: $showLogoutAlert) {
            logoutAlertActions
        } message: {
            logoutAlertMessage
        }
#endif
    }

    private var settingsForm: some View {
        Form {
            settingsSections
        }
    }

    @ViewBuilder
    private var settingsSections: some View {
                Section(header: Text("Name")) {
                    TextField("Tailnet HostName", text: $viewModel.tailnetHostName)
#if canImport(UIKit)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
#endif
                        .onSubmit {
                            viewModel.setTailnetHostName(viewModel.tailnetHostName)
                        }
                    Text("The name of this node on your Tailnet")
                        .font(Font.caption2)
                }

                Section(header: Text("Home Page")) {
                    TextField("Home Page", text: $viewModel.homePage)
#if canImport(UIKit)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
#endif
                        .accessibilityIdentifier("home-page-field")
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
                    // Never let "auto:any" blackhole public traffic when the
                    // current netmap has no exit-node-capable peer. Keep an
                    // already-enabled toggle usable so the user can turn it off
                    // if the selected peer disappears.
                    .disabled(!viewModel.exitNodeEnabled && viewModel.availableExitNodes.isEmpty)
                    HStack {
                        Text("Current Exit Node")
                        Spacer()
                        Text(viewModel.exitNodeDisplayName)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let diag = viewModel.exitNodeDiagnostic {
                        exitNodeDiagnosticBanner(diag)
                    }
                }

                Section {
                    StatusButton(text: "Logout",
                                 action: { showLogoutAlert = true },
                                 color: .red)
                        .accessibilityIdentifier("logout-button")
                }

                routingSection
    }

    @ViewBuilder
    private var logoutAlertActions: some View {
        Button("Cancel", role: .cancel) { }
        Button("Logout", role: .destructive) {
            viewModel.logout()
            dismissAction()
        }
    }

    private var logoutAlertMessage: some View {
        Text("This will delete this session, including its tabs, bookmarks, and website data.")
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
#if canImport(UIKit)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
#endif
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
