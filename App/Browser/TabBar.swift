//
//  TabBar.swift
//  Aperture
//
//  The Safari-style visible tab bar shown on iPad / regular width: a
//  horizontal, scrollable row of tab "chips" (title + close), plus a trailing
//  "+" to open a new Aperture-chat tab. On iPhone (compact width) this bar is
//  hidden and tab management happens through the tab-overview button instead.
//

import SwiftUI

struct TabBar: View {
    @ObservedObject var tabManager: TabManager
    let onNewChat: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tabManager.tabs) { tab in
                    TabChip(
                        tab: tab,
                        isSelected: tabManager.currentTab?.id == tab.id,
                        onSelect: { tabManager.select(tab) },
                        onClose: { tabManager.closeTab(tab) }
                    )
                }
                Button {
                    onNewChat()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("new-chat-tab-button")
                .accessibilityLabel("New Chat Tab")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .frame(height: 36)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct TabChip: View {
    @ObservedObject var tab: BrowserTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left")
                .font(.system(size: 10))
                .foregroundStyle(isSelected ? .white : .secondary)

            ConnectionTypeIcon(type: tab.connectionType)

            Text(tab.displayTitle)
                .font(.system(size: 13))
                .lineLimit(1)
                .foregroundStyle(isSelected ? .white : .primary)

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Tab")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.blue : Color(.secondarySystemBackground))
        )
        .onTapGesture { onSelect() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tab.displayTitle) tab")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
    }
}
