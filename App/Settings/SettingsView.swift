//  Created by Jonathan Nobels on 2025-12-19.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    var dismissAction: () -> Void

    @State private var showLogoutAlert: Bool = false
    @State private var togglingExitNode: Bool = false

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
                    // workspace's tsnet profile and drops the tailnet.
                    StatusButton(text: "Logout",
                                 action: { showLogoutAlert = true },
                                 color: .red)
                        .accessibilityIdentifier("logout-button")
                }
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
                Text("Are you sure you want to log out?")
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            // Seed the exit-node diagnostic (availability + egress IP) so the
            // banner is populated when Settings opens, not only after a toggle.
            viewModel.runExitNodeDiagnostic()
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
