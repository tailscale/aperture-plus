//  Bookmark.swift
//  Aperture
//
//  A SwiftData-backed saved URL. Each workspace owns its own
//  `ModelContainer` (see `Workspace.modelContainer`), so bookmarks are
//  per-identity — a URL like `http://ai/chat` means a different node on a
//  different tailnet, so they shouldn't be shared across workspaces.
//

import Foundation
import SwiftData

@Model
final class Bookmark {
    var timestamp: Date
    var name: String
    var url: String

    init(timestamp: Date, name: String, url: String) {
        self.timestamp = timestamp
        self.name = name
        self.url = url
    }
}
