import SwiftUI
import SwiftData
import AppIntents
import AppKit
import TailscaleKit

/// Native macOS entry point. A persisted Tailscale workspace can have several
/// browser windows open at once (Cmd+N opens a new one in the current
/// workspace). Each window is value-addressed by a `WorkspaceWindowHandle`;
/// the windowID keeps windows distinct while the workspaceID pins a window to
/// its tailnet identity. Closing a window releases only that window; the
/// workspace/node/session remains available from the Window menu. Experimental
/// disposable Linux VM windows are separate scenes and currently use Apple's
/// NAT while the workspace-owned userspace bridge is developed.

/// Value carried by a workspace browser window. `windowID` keeps every window
/// independent so a workspace can have several windows open at once: the
/// value-based `WindowGroup` dedupes by this whole struct, so distinct
/// windowIDs produce distinct windows while the same handle raises its
/// existing window. `workspaceID` pins the window to its tailnet identity.
struct WorkspaceWindowHandle: Codable, Hashable {
    let windowID: UUID
    let workspaceID: UUID
}

/// Ensures a workspace window is open on launch even when the app is launched
/// non-frontmost (XCUITest's `app.launch()`, `open -g`), where SwiftUI scenes
/// never become `.active` and `.defaultLaunchBehavior(.presented)` therefore
/// does not fire — leaving the app running with no window, so every Mac UI
/// test timed out at its first `app.windows` wait. `applicationDidFinishLaunching`
/// (which AppKit calls regardless of activation) drives this: it captures
/// `openWindow` from `MacWorkspaceCommands` (the menu bar is always built at
/// launch) into this shared holder, then calls it for the launch handle.
/// `openWindow(id:value:)` is idempotent — opening an already-open value raises
/// that window instead of duplicating — so using the SAME handle as
/// `defaultValue`/`.presented` composes safely (no duplicate launch window).
@MainActor
private final class WindowOpener {
    static let shared = WindowOpener()
    var openWindow: OpenWindowAction?
    var workspaceManager: WorkspaceManager?
    var launchHandle: WorkspaceWindowHandle?
    private var attempts = 0
    func openWorkspaceWindow() {
        guard let action = openWindow, let wm = workspaceManager else {
            // The Commands/menu that populate these may build just after launch.
            attempts += 1
            guard attempts < 40 else { return }  // ~2s of retries at 50ms
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                WindowOpener.shared.openWorkspaceWindow()
            }
            return
        }
        // Reuse the launch handle (the same value `.presented`/`defaultValue`
        // uses) so the fallback opens/raises the same window instead of a
        // duplicate. Fall back to a fresh handle if it was never set.
        let handle = launchHandle ?? WorkspaceWindowHandle(
            windowID: UUID(),
            workspaceID: wm.activeWorkspace?.id ?? wm.addWorkspace().id)
        action(id: "workspace", value: handle)
    }
}

/// Captures the hosting `NSWindow` of a SwiftUI scene so native window-key
/// notifications can drive "most recently focused workspace" tracking.
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        onWindow(nsView.window)
    }
}

/// Tracks which workspace each open `NSWindow` belongs to and, via
/// `NSWindow.didBecomeKeyNotification`, which workspace was most recently
/// focused. Per-scene `scenePhase` does not reliably fire `.active` on macOS
/// when another window closes and this one becomes key, so the Cmd+N
/// "reopen last-focused workspace" logic is driven from here instead.
@MainActor
private final class MacWindowFocusTracker {
    static let shared = MacWindowFocusTracker()
    weak var workspaceManager: WorkspaceManager?
    /// Maps a live `NSWindow` (by `ObjectIdentifier`) to its `(windowID, workspaceID)`.
    private var windowToWorkspace: [ObjectIdentifier: (windowID: UUID, workspaceID: UUID)] = [:]
    private var keyObserver: Any?

    private init() {
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Extract the Sendable window reference before crossing into the
            // MainActor task (NSNotification itself is not Sendable).
            let window = note.object as? NSWindow
            Task { @MainActor in self?.windowBecameKey(window) }
        }
    }

    /// Called from `WorkspaceWindowRoot` once its hosting `NSWindow` is known.
    /// Records the open window and, if it is already key, marks it focused.
    /// Safe to call during a SwiftUI view update: it only mutates this tracker's
    /// non-published map synchronously, and defers the `@Published` workspace-manager
    /// mutation to a MainActor task so it never publishes during a view update.
    func register(window: NSWindow, windowID: UUID, workspaceID: UUID) {
        let key = ObjectIdentifier(window)
        // Skip the manager call entirely if already registered for this window;
        // updateNSView fires on every view re-render, so without this guard
        // every render would re-publish and spin.
        let already = windowToWorkspace[key]
        windowToWorkspace[key] = (windowID, workspaceID)
        let isKey = window.isKeyWindow
        guard already == nil || already?.workspaceID != workspaceID || already?.windowID != windowID || isKey
        else { return }
        Task { @MainActor [weak self] in
            self?.workspaceManager?.windowDidOpen(windowID: windowID, workspaceID: workspaceID)
            if isKey {
                self?.workspaceManager?.windowBecameKey(windowID: windowID, workspaceID: workspaceID)
            }
        }
    }

    /// Called from `WorkspaceWindowRoot.onDisappear` to drop the closed window.
    func unregister(workspaceID: UUID) {
        windowToWorkspace = windowToWorkspace.filter { $0.value.workspaceID != workspaceID }
    }

    private func windowBecameKey(_ window: NSWindow?) {
        guard let window,
              let (windowID, workspaceID) = windowToWorkspace[ObjectIdentifier(window)]
        else { return }
        workspaceManager?.windowBecameKey(windowID: windowID, workspaceID: workspaceID)
    }
}

private final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            WindowOpener.shared.openWorkspaceWindow()
        }
    }
}

@main
struct ApertureMacApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: MacAppDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var workspaceManager: WorkspaceManager
    @State private var vmSupervisor: WorkspaceVMSupervisor
    /// The handle for the single launch window. Shared by `defaultValue`/
    /// `.presented` and `WindowOpener` so both launch paths produce the SAME
    /// value — `openWindow(id:value:)` is idempotent, so the fallback raises
    /// the `.presented` window instead of opening a duplicate.
    @State private var launchHandle: WorkspaceWindowHandle

    init() {
        let manager = WorkspaceManager()
        let supervisor = WorkspaceVMSupervisor(workspaceManager: manager)
        manager.vmManager = supervisor
        _workspaceManager = State(initialValue: manager)
        _vmSupervisor = State(initialValue: supervisor)
        _launchHandle = State(initialValue: WorkspaceWindowHandle(
            windowID: UUID(),
            workspaceID: manager.activeWorkspace?.id ?? manager.addWorkspace().id))
        supervisor.startDesiredVMs()
    }

    var body: some Scene {
        WindowGroup(
            "Aperture+",
            id: "workspace",
            for: WorkspaceWindowHandle.self
        ) { handle in
            WorkspaceWindowRoot(
                workspaceManager: workspaceManager,
                handle: handle
            )
            .frame(minWidth: 720, minHeight: 480)
        } defaultValue: {
            launchHandle
        }
        .defaultSize(width: 1100, height: 760)
        // A value-based WindowGroup does not auto-present a window on launch
        // (it opens only via `openWindow` or state restoration). Without this,
        // a fresh launch — or relaunch after the app was terminated with no
        // open windows — shows no window at all: the process runs (tsnet
        // starts) but there's nothing to interact with, and clicking the Dock
        // icon of a running-with-no-windows app does nothing either. `.presented`
        // makes the workspace scene present itself on launch using `defaultValue`
        // when there is no saved state to restore, which is exactly the
        // always-show-a-window behavior a single-window-by-default browser
        // needs. (macOS 15.0+; the target is macOS 26.0.)
        .defaultLaunchBehavior(.presented)
        // Opt out of AppKit window state restoration. The workspace list and
        // each workspace's tsnet state are persisted in workspaces.json +
        // per-workspace dirs, so NSWindow restoration is not load-bearing —
        // and leaving it enabled makes the app hostage to macOS's
        // "Aperture unexpectedly quit while reopening windows" guard. That
        // dialog is driven by talagent's per-app `restorecount.plist`: once
        // the count is non-zero (after a crash or an abrupt UI-test terminate
        // mid-restoration), the next launch blocks on a Reopen/Don't-Reopen
        // modal — and under XCUITest the dialog is suppressed, so the app
        // comes up with NO window at all and every test times out at its
        // first `app.windows` wait. Disabling scene restoration stops the
        // app from participating in that flow, so launches are deterministic
        // for both users and the test harness.
        .restorationBehavior(.disabled)
        .commands {
            MacWorkspaceCommands(workspaceManager: workspaceManager, launchHandle: launchHandle)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                workspaceManager.willEnterBackground()
            case .inactive:
                break
            case .active:
                workspaceManager.willEnterForeground()
            @unknown default:
                break
            }
        }

        WindowGroup("Linux VM (Experimental)", id: "experimental-vm", for: ExperimentalVMRequest.self) { request in
            ExperimentalVMView(
                id: request.wrappedValue.id,
                workspace: workspaceManager.workspace(
                    id: request.wrappedValue.workspaceID
                )
            )
        } defaultValue: {
            ExperimentalVMRequest(
                id: UUID(),
                workspaceID: workspaceManager.activeWorkspace?.id
                    ?? workspaceManager.addWorkspace().id
            )
        }
        .defaultSize(width: 960, height: 640)
        .restorationBehavior(.disabled)

        Settings {
            MacSettingsHost(workspaceManager: workspaceManager)
        }
    }
}

private struct WorkspaceWindowRoot: View {
    @ObservedObject var workspaceManager: WorkspaceManager
    @Binding var handle: WorkspaceWindowHandle
    @Environment(\.dismissWindow) private var dismissWindow

    private var workspaceID: UUID { handle.workspaceID }

    private var resolvedWorkspace: Workspace? {
        workspaceManager.workspace(id: workspaceID) ?? workspaceManager.activeWorkspace
    }

    var body: some View {
        if let workspace = resolvedWorkspace {
            TabbedBrowserView(
                workspaceManager: workspaceManager,
                pinnedWorkspaceID: workspace.id
            )
            .navigationTitle(workspace.identifier)
            .background(WindowAccessor { window in
                // Grab the hosting NSWindow so NSWindow key notifications can
                // drive focus tracking (per-scene scenePhase is unreliable on
                // macOS for become-key). Registering is idempotent.
                guard let window else { return }
                MacWindowFocusTracker.shared.workspaceManager = workspaceManager
                MacWindowFocusTracker.shared.register(
                    window: window, windowID: handle.windowID, workspaceID: workspaceID)
            })
            .onAppear {
                // Closing the last tab closes this workspace's window (and the
                // workspace persists, reachable from the Window menu) instead of
                // silently churning a replacement home-page tab. Reopening the
                // window creates a fresh home-page tab (see `ensureTab` in
                // `WorkspaceRoot`).
                workspace.tabManager.onLastTabClosed = { dismissWindow() }
                MacWindowFocusTracker.shared.workspaceManager = workspaceManager
            }
            .onDisappear {
                // Drop this window from the open/focus tracker before any
                // workspace cleanup so the Window menu and Cmd+N see it gone.
                MacWindowFocusTracker.shared.unregister(workspaceID: workspaceID)
                workspaceManager.windowDidClose(workspaceID: workspaceID)
                // Closing a native workspace window deletes the workspace when
                // it was never connected (still at NeedsLogin) and it isn't the
                // last one. A fresh Ctrl-Cmd+N workspace that you close right
                // away shouldn't linger in the Window menu — it has no session
                // data worth keeping. Connected workspaces are preserved
                // (closing a window keeps the workspace, reachable from the
                // Window menu), and the last workspace is never auto-deleted,
                // so closing the final window just leaves the app running with
                // no windows rather than churning a replacement node.
                if let ws = workspaceManager.workspace(id: workspaceID),
                   ws.statusViewModel.needsAuth,
                   workspaceManager.workspaces.count > 1 {
                    workspaceManager.deleteWorkspace(id: workspaceID)
                }
            }
        } else {
            ProgressView("Restoring Workspace…")
        }
    }
}

private struct FocusAddressRequestedKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct ShowLogsRequestedKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

struct BrowserTabManagerKey: FocusedValueKey {
    typealias Value = TabManager
}

extension FocusedValues {
    var focusAddressRequested: Binding<Bool>? {
        get { self[FocusAddressRequestedKey.self] }
        set { self[FocusAddressRequestedKey.self] = newValue }
    }

    var showLogsRequested: Binding<Bool>? {
        get { self[ShowLogsRequestedKey.self] }
        set { self[ShowLogsRequestedKey.self] = newValue }
    }

    var browserTabManager: TabManager? {
        get { self[BrowserTabManagerKey.self] }
        set { self[BrowserTabManagerKey.self] = newValue }
    }
}

private struct MacWorkspaceCommands: Commands {
    @ObservedObject var workspaceManager: WorkspaceManager
    let launchHandle: WorkspaceWindowHandle
    @Environment(\.openWindow) private var openWindow
    @FocusedBinding(\.focusAddressRequested) private var focusAddressRequested
    @FocusedBinding(\.showLogsRequested) private var showLogsRequested
    @FocusedValue(\.browserTabManager) private var focusedTabManager

    private var targetTabManager: TabManager? {
        focusedTabManager ?? workspaceManager.activeWorkspace?.tabManager
    }

    /// The workspace a new window (Cmd+N) should open in: the most recently
    /// focused workspace, falling back to the persisted active one.
    private var currentWorkspaceID: UUID? {
        workspaceManager.currentWorkspaceID
    }

    /// Cmd+N opens a new window in the current workspace only when it doesn't
    /// already have one (a second window in the same workspace would share one
    /// `TabManager` and fight it, so duplicates are refused). So Cmd+N does
    /// nothing while the current workspace's window is open, and reopens the
    /// last-focused workspace after ALL windows are closed.
    private var canNewWindow: Bool {
        guard let wsID = currentWorkspaceID,
              !workspaceManager.hasOpenWindow(wsID)
        else { return false }
        return true
    }

    var body: some Commands {
        let _ = {
            WindowOpener.shared.openWindow = openWindow
            WindowOpener.shared.workspaceManager = workspaceManager
            WindowOpener.shared.launchHandle = launchHandle
        }()
        CommandGroup(replacing: .newItem) {
            // Cmd+N: a new browser window in the current (most-recently-focused)
            // workspace — but only if that workspace doesn't already have a
            // window open (one window per workspace). When a window is already
            // open this is a no-op; after all windows are closed it reopens the
            // last-focused one. A fresh windowID produces a distinct window.
            Button("New Window") {
                guard let wsID = currentWorkspaceID,
                      !workspaceManager.hasOpenWindow(wsID) else { return }
                openWindow(id: "workspace",
                           value: WorkspaceWindowHandle(windowID: UUID(), workspaceID: wsID))
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(!canNewWindow)

            // Ctrl-Cmd+N: a new workspace (a new tsnet identity / window).
            // Shift-Cmd+N is reserved for a future incognito/ephemeral mode.
            Button("New Workspace") {
                let workspace = workspaceManager.addWorkspace()
                openWindow(id: "workspace",
                           value: WorkspaceWindowHandle(windowID: UUID(), workspaceID: workspace.id))
            }
            .keyboardShortcut("n", modifiers: [.command, .control])

            // Thundersnap is managed from workspace Settings. Its lifecycle is
            // intentionally not tied to a disposable console window.
        }

        // The standard Window menu lists only windows that are currently open.
        // Add every persisted workspace so a closed window can be recreated;
        // passing the same value raises an already-open window instead.
        CommandGroup(after: .newItem) {
            Button("New Tab") {
                targetTabManager?.openChatTab()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(targetTabManager?.canOpenNewTab != true)

            // Closes the current tab. Closing the last tab closes the workspace
            // window: `TabManager.closeTab` calls `onLastTabClosed` (set by
            // `WorkspaceWindowRoot`) which dismisses the window, and reopening
            // from the Window menu creates a fresh home-page tab. This is the
            // sole Cmd+W command on macOS (the hidden shortcut buttons in
            // `BrowserRootContent` are gated to iOS), so it uniquely owns the
            // shortcut and wins over the system window-close.
            Button("Close Tab") {
                targetTabManager?.closeCurrentTab()
            }
            .keyboardShortcut("w", modifiers: .command)

            Divider()

            Button("Focus Location") {
                focusAddressRequested = true
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(focusAddressRequested == nil)

            Button("Reload Page") {
                targetTabManager?.currentTab?.viewModel.reload()
            }
            .keyboardShortcut("r", modifiers: .command)

            Button("Show Logs") {
                showLogsRequested = true
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(showLogsRequested == nil)

            Divider()

            Button("Show Previous Tab") {
                targetTabManager?.selectPreviousTab()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])

            Button("Show Next Tab") {
                targetTabManager?.selectNextTab()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
        }

        // The standard Window menu lists only windows that are currently open.
        // Add every persisted workspace so a closed window can be recreated.
        // If the workspace already has an open window, reuse its windowID so the
        // idempotent `openWindow` raises it; otherwise open a fresh window.
        CommandGroup(before: .windowArrangement) {
            Divider()
            ForEach(workspaceManager.workspaces) { workspace in
                Button(workspace.identifier) {
                    let windowID = workspaceManager.openWorkspaceWindows[workspace.id] ?? UUID()
                    openWindow(id: "workspace",
                               value: WorkspaceWindowHandle(windowID: windowID, workspaceID: workspace.id))
                }
            }
            Divider()
        }
    }
}

/// macOS app-menu Settings (Cmd+,). Hosts the SAME shared `SettingsView` the
/// browser/gear sheet uses, so there is one settings codebase across iOS and
/// macOS. "Done" closes the settings window (`dismissWindow`); Logout deletes
/// the active workspace's session exactly as it does from the in-window sheet.
private struct MacSettingsHost: View {
    @ObservedObject var workspaceManager: WorkspaceManager
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        if let ws = workspaceManager.activeWorkspace {
            SettingsView(
                viewModel: SettingsViewModel(
                    workspace: ws,
                    deleteSession: { workspaceManager.deleteWorkspace(id: ws.id) },
                    vmManager: workspaceManager.vmManager
                ),
                dismissAction: { dismissWindow() }
            )
        } else {
            ContentUnavailableView(
                "No Workspace",
                systemImage: "person.crop.circle.badge.questionmark",
                description: Text("Open a workspace window to configure it.")
            )
        }
    }
}
