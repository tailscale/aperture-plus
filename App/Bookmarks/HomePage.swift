//  HomePage.swift
//  Aperture
//
//  A workspace's home page — the URL the workspace's first chat tab loads.
//  Per-workspace (each identity can have its own home page), persisted as part
//  of the workspace's `WorkspaceDefinition` (the `Workspace` observes
//  `homePage.$url` and writes it back).
//
//  Previously this was a process-wide singleton (`HomePage.standard`) backed by
//  a single `UserDefaults` key; that assumed one identity. It's now an
//  `ObservableObject` instance owned by each `Workspace`.
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class HomePage: ObservableObject {
    /// The default home page loaded when the user hasn't set one. Points at
    /// the Aperture chat UI on the tailnet.
    static let defaultURL = "http://ai/chat"

    /// The current home-page URL. `@Published` so Settings' text field and the
    /// bookmarks sheet react to changes; the owning `Workspace` persists
    /// changes back into its definition.
    @Published var url: String

    init(url: String) {
        self.url = url
    }

    /// A synthetic "Home Page" bookmark row for the bookmarks sheet (not
    /// persisted in SwiftData — it's a convenience entry that always reflects
    /// the current home page).
    var bookmark: Bookmark {
        Bookmark(timestamp: Date(), name: "Home Page", url: url)
    }
}
