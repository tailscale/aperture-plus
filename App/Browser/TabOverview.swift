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
    @ObservedObject var tabManager: TabManager
    let onNewChat: () -> Void
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.flexible(), spacing: 16),
                           GridItem(.flexible(), spacing: 16)]

    var body: some View {
        NavigationStack {
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
                                onSelect: {
                                    tabManager.select(tab)
                                    dismiss()
                                },
                                onClose: { tabManager.closeTab(tab) }
                            )
                        }
                    }
                    .padding(16)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Tabs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onNewChat()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityIdentifier("new-chat-tab-button")
                    .accessibilityLabel("New Chat Tab")
                }
            }
        }
    }
}

private struct TabCard: View {
    @ObservedObject var tab: BrowserTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        Button {
            onSelect()
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                // Card "preview" area — a placeholder glyph (WKWebView doesn't
                // expose a snapshot API). The title/url below identify the tab.
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? Color.blue.opacity(0.12) : Color(.secondarySystemBackground))
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
                    .fill(Color(.systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.blue : Color(.separator), lineWidth: isSelected ? 2 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.5))
            }
            .buttonStyle(.plain)
            .padding(6)
            .accessibilityLabel("Close Tab")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tab.displayTitle) — \(tab.displayURL)")
    }
}
