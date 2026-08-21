//
//  TabBar.swift
//  Aperture
//
//  The Safari-style visible tab bar shown on iPad / regular width: a row of
//  tab "chips" (title + close), plus a trailing "+" to open a new Aperture-chat
//  tab. On iPhone (compact width) this bar is hidden and tab management happens
//  through the tab-overview button instead.
//
//  Unlike a plain scrollable row, the chips squeeze down to equal widths so all
//  open tabs always fit within the bar — no horizontal scrolling and no tabs
//  pushed off the right edge. Each chip is capped at a comfortable max width
//  (so one or two tabs don't stretch across the whole bar) and shrinks, with
//  the title truncating, as more tabs are opened. (Tab count is capped at 10,
//  and the window has a minimum width, so chips never collapse below their
//  icon+close minimum in practice.)
//

import SwiftUI

struct TabBar: View {
    @ObservedObject var tabManager: TabManager
    let onNewChat: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            SqueezingTabLayout(spacing: 6, maxTabWidth: 240, minTabWidth: 44) {
                ForEach(tabManager.tabs) { tab in
                    TabChip(
                        tab: tab,
                        isSelected: tabManager.currentTab?.id == tab.id,
                        onSelect: { tabManager.select(tab) },
                        onClose: { tabManager.closeTab(tab) }
                    )
                }
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
        .frame(height: 36)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

/// Lays out tab chips on a single row, squeezing them to equal widths so they
/// all fit the available width instead of overflowing. Each chip's width is
/// `min(maxTabWidth, available/count)`, floored at `minTabWidth`. With few tabs
/// the chips keep their natural (capped) width and pack against the "+"; with
/// many they compress and the title truncates.
private struct SqueezingTabLayout: Layout {
    var spacing: CGFloat
    var maxTabWidth: CGFloat
    var minTabWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let count = subviews.count
        guard count > 0 else { return .zero }
        let perTab = perTabWidth(available: proposal.width ?? .infinity, count: count)
        let total = perTab * CGFloat(count) + spacing * CGFloat(count - 1)
        let height = proposal.height ?? subviews.map { $0.dimensions(in: proposal).height }.max() ?? 28
        return CGSize(width: total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let count = subviews.count
        guard count > 0 else { return }
        let perTab = perTabWidth(available: bounds.width, count: count)
        var x = bounds.minX
        for subview in subviews {
            subview.place(at: CGPoint(x: x, y: bounds.minY),
                          proposal: ProposedViewSize(width: perTab, height: bounds.height))
            x += perTab + spacing
        }
    }

    private func perTabWidth(available: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let raw = (available - spacing * CGFloat(count - 1)) / CGFloat(count)
        return min(maxTabWidth, max(minTabWidth, raw))
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
                .truncationMode(.middle)
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
                .fill(isSelected ? Color.blue : Color.platformSecondarySystemBackground)
        )
        .onTapGesture { onSelect() }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tab-chip")
        .accessibilityLabel("\(tab.displayTitle) tab")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
    }
}
