//  Created by Jonathan Nobels on 2025-12-18.
//

import SwiftUI
import SwiftData

struct BookMarkList: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort:\Bookmark.timestamp, order: .reverse) private var bookmarks: [Bookmark]

    var body: some View {
        ForEach(bookmarks) { item in
            BookmarkListItem(bookmark: item)
        }
        .onDelete(perform: deleteItems)
    }

    private func deleteItems(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(bookmarks[index])
            }
        }
    }
}

struct BookmarkListItem: View {
    let bookmark: Bookmark

    var body: some View {
        NavigationLink(value: bookmark) {
            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.name)
                    .font(.body)
                Text(bookmark.url)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
