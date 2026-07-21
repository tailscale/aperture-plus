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
                    HStack {
                        Text("Current Exit Node")
                        Spacer()
                        Text(viewModel.exitNodeDisplayName)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Section {
                    StatusButton(text: "Logout", action: { showLogoutAlert = true })
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
    }
}
