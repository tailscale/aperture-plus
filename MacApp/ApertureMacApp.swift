import SwiftUI
import TailscaleKit

/// Native macOS entry point.
///
/// This deliberately contains no Virtualization framework code yet. The first
/// milestone is a distributable, signed native app carrying the virtualization
/// entitlement; browser and VM functionality will be added incrementally.
@main
struct ApertureMacApp: App {
    var body: some Scene {
        WindowGroup {
            NativeMacFoundationView()
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 1100, height: 760)

        Settings {
            NativeMacSettingsView()
        }
    }
}

private struct NativeMacFoundationView: View {
    var body: some View {
        ContentUnavailableView(
            "Aperture for Mac",
            systemImage: "network",
            description: Text("The native macOS foundation is ready. Browser functionality is being ported next.")
        )
        .accessibilityIdentifier("mac-foundation-view")
    }
}

private struct NativeMacSettingsView: View {
    var body: some View {
        Form {
            LabeledContent("Platform", value: "Native macOS")
            Text("Virtual machine functionality is not implemented yet.")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 460)
        .accessibilityIdentifier("mac-settings-view")
    }
}
