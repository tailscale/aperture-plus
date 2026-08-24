// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//
//  TabOverview.swift
//  Aperture
//
//  The Safari-style tab overview — a full-screen grid of cards representing
//  each open tab, presented from the tab-overview button. Tapping a card
//  selects that tab and dismisses; the close button on a card closes it; the
//  toolbar "+" opens a new Aperture-chat tab. Used on iPhone (where there's no
//  persistent tab bar) and reachable on iPad too.
//

import SwiftUI

struct TabOverview: View {
    @ObservedObject var workspaceManager: WorkspaceManager
    /// Native Mac windows pin their tab overview to that window's workspace.
    /// iOS passes nil and retains its workspace selector/active-workspace flow.
    var pinnedWorkspaceID: UUID? = nil
    @Environment(\.dismiss) private var dismiss

    private var presentedWorkspace: Workspace? {
        if let pinnedWorkspaceID {
            return workspaceManager.workspace(id: pinnedWorkspaceID)
        }
        return workspaceManager.activeWorkspace
    }

    var body: some View {
        NavigationStack {
            Group {
                if let workspace = presentedWorkspace {
                    WorkspaceTabGrid(tabManager: workspace.tabManager) { tab in
                        workspace.tabManager.select(tab)
                        dismiss()
                    }
                    .id(workspace.id)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Tabs")
#if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
#if canImport(UIKit)
                ToolbarItem(placement: .principal) {
                    sessionMenu
                }
#endif
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        presentedWorkspace?.tabManager.openChatTab()
                        dismiss()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(presentedWorkspace?.tabManager.canOpenNewTab != true)
                    .accessibilityIdentifier("new-chat-tab-button")
                    .accessibilityLabel("New Chat Tab")
                }
            }
        }
    }

    @ViewBuilder
    private var sessionMenu: some View {
        Menu {
            ForEach(workspaceManager.workspaces) { workspace in
                Button {
                    workspaceManager.selectWorkspace(id: workspace.id)
                } label: {
                    WorkspaceMenuLabel(
                        workspace: workspace,
                        isSelected: workspaceManager.activeWorkspace?.id == workspace.id
                    )
                }
                .accessibilityIdentifier("workspace-row-\(workspace.id.uuidString)")
                .accessibilityValue(
                    workspaceManager.activeWorkspace?.id == workspace.id ? "Selected" : ""
                )
                #if canImport(UIKit)
                // iOS has no window-close gesture, so a logged-out workspace
                // (still at NeedsLogin, never connected) that you don't want —
                // e.g. one you added by mistake — needs a way to be removed
                // without going through Settings → Logout. On macOS the
                // equivalent is closing the workspace's window (see
                // WorkspaceWindowRoot.onDisappear); here a logged-out row gets
                // a destructive "Delete" item, mirroring that cleanup. The last
                // workspace is never offered for deletion (deleting it would
                // just seed a replacement — pointless from a menu).
                if workspace.statusViewModel.needsAuth,
                   workspaceManager.workspaces.count > 1 {
                    Button(role: .destructive) {
                        workspaceManager.deleteWorkspace(id: workspace.id)
                    } label: {
                        Label("Delete \(workspace.identifier)", systemImage: "trash")
                    }
                    .accessibilityIdentifier("delete-workspace-\(workspace.id.uuidString)")
                }
                #endif
            }
            Divider()
            Button {
                workspaceManager.addWorkspace()
            } label: {
                Label("New Session", systemImage: "plus")
            }
            .accessibilityIdentifier("add-workspace-button")
        } label: {
            HStack(spacing: 5) {
                // The full login · tailnet · hostname identifier is useful in
                // the expanded menu, but cannot fit between Done and +. Use a
                // compact tailnet name for the collapsed selector instead.
                Text(compactActiveSessionName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
        }
        .accessibilityIdentifier("session-selector-menu")
        .accessibilityLabel("Session")
        .accessibilityValue(compactActiveSessionName)
        .accessibilityHint(workspaceManager.activeWorkspace?.identifier ?? "Sessions")
    }

    private var compactActiveSessionName: String {
        guard let workspace = workspaceManager.activeWorkspace else { return "Sessions" }
        let tailnet = workspace.identity.tailnetName?
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let name: String
        if let tailnet, !tailnet.isEmpty {
            // Most tailnet DNS names end in .ts.net. That suffix adds no useful
            // distinction here and consumes scarce navigation-bar width.
            name = tailnet.hasSuffix(".ts.net")
                ? String(tailnet.dropLast(".ts.net".count))
                : tailnet
        } else {
            // Before identity discovery, the generated hostname is compact and
            // unique; the default display name ("Aperture") is identical for
            // every new session and therefore unsuitable for a switcher.
            name = workspace.definition.hostname
        }
        return abbreviated(name, maximumLength: 22)
    }

    /// Preserve both ends, where generated names and domains tend to carry
    /// their distinguishing information, while keeping the toolbar stable.
    private func abbreviated(_ value: String, maximumLength: Int) -> String {
        guard value.count > maximumLength else { return value }
        let prefixLength = (maximumLength - 1) / 2
        let suffixLength = maximumLength - prefixLength - 1
        return "\(value.prefix(prefixLength))…\(value.suffix(suffixLength))"
    }

    private struct WorkspaceTabGrid: View {
        @ObservedObject var tabManager: TabManager
        let onSelect: (BrowserTab) -> Void

        private let columns = [GridItem(.flexible(), spacing: 16),
                               GridItem(.flexible(), spacing: 16)]

        var body: some View {
            ScrollView {
                if tabManager.tabs.isEmpty {
                    ContentUnavailableView("No Open Tabs",
                                           systemImage: "square.on.square",
                                           description: Text("Tap + to open an Aperture chat."))
                        .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(tabManager.tabs) { tab in
                            TabCard(
                                tab: tab,
                                isSelected: tabManager.currentTab?.id == tab.id,
                                onSelect: { onSelect(tab) },
                                onClose: { tabManager.closeTab(tab) }
                            )
                        }
                    }
                    .padding(16)
                }
            }
            .background(Color.platformSystemGroupedBackground)
        }
    }
}

private struct WorkspaceMenuLabel: View {
    @ObservedObject var workspace: Workspace
    let isSelected: Bool

    var body: some View {
        if isSelected {
            Label(workspace.identifier, systemImage: "checkmark")
        } else {
            Text(workspace.identifier)
        }
    }
}

private struct TabCard: View {
    @ObservedObject var tab: BrowserTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                // Card "preview" area — a placeholder glyph (WKWebView doesn't
                // expose a snapshot API). The title/url below identify the tab.
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? Color.blue.opacity(0.12) : Color.platformSecondarySystemBackground)
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                }
                .frame(height: 150)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(tab.displayTitle)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        ConnectionTypeIcon(type: tab.connectionType)
                    }
                    Text(tab.displayURL)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.platformSystemBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.blue : Color.platformSeparator, lineWidth: isSelected ? 2 : 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture { onSelect() }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("tab-card-\(tab.id.uuidString)")
            .accessibilityLabel("\(tab.displayTitle) — \(tab.displayURL)")
            .accessibilityAddTraits(.isButton)

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.5))
                    // Generous independent hit target for pointer use on iPad
                    // apps running on macOS.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("close-tab-\(tab.id.uuidString)")
            .accessibilityLabel("Close Tab")
        }
    }
}
