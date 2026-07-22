//
//  BookmarksSheet.swift
//  Aperture
//
//  A modal bookmarks picker presented from the browser toolbar. Tapping a
//  bookmark loads its URL in the current tab (and dismisses the sheet).
//

import SwiftUI

struct BookmarksSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (Bookmark) -> Void

    var body: some View {
        NavigationStack {
            List {
                BookmarkListItem(bookmark: HomePage.standard.bookmark, onSelect: handle)
                BookMarkList(onSelect: handle)
            }
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func handle(_ bookmark: Bookmark) {
        dismiss()
        onSelect(bookmark)
    }
}
