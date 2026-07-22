//
//  ContentView.swift
//  Aperture
//
//  Created by Jonathan Nobels on 2025-12-16.
//

import SwiftUI
import SwiftData
import Combine
import TailscaleKit

struct MainView: View {
    @ObservedObject private var statusViewModel: StatusViewModel
    @ObservedObject private var browserViewModel: BrowserViewModel

    // Navigation and alert state
    @State private var showingAddSheet = false
    @State private var showingSettingsSheet = false

   private let manager: TSNetManager

    init(manager: TSNetManager) {
        self.manager = manager
        statusViewModel = StatusViewModel(manager: manager)
        browserViewModel = BrowserViewModel(model: manager.model)
    }

    var body: some View {
        NavigationSplitView {
            List {
                Section {
                    ApertureBrandHeader {
                        Button {
                            showingSettingsSheet = true
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 18))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("settings-button")
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 10, trailing: 8))

                Section {
                    StatusView(viewModel: statusViewModel)
                }
                Group {
                    if manager.model.state == .Running {
                        BookmarkListItem(bookmark: HomePage.standard.bookmark)
                            .accessibilityIdentifier("home-page-bookmark")
                        BookMarkList()
                    }
                }
            }
            // Bookmark rows are NavigationLinks carrying their Bookmark value;
            // tapping pushes the browser here. (NavigationLink is used
            // instead of a Button + manual selection because SwiftUI Buttons
            // inside List rows don't reliably fire their action on tap.)
            .navigationDestination(for: Bookmark.self) { item in
                if let url = URL(string: item.url) {
                    BrowserView(model: browserViewModel)
                        .onAppear() { [weak browserViewModel] in
                            logger.log("Loading intial url \(url)")
                            browserViewModel?.loadInitialURL(url)
                        }
                } else {
                    Text("Invalid bookmark")
                }
            }
            .toolbar {
                // Bottom toolbar for bookmarks
                ToolbarItemGroup(placement: .bottomBar) {
                    EditButton()
                    Spacer()
                    Button(action: { showingAddSheet = true }) {
                        Label("Add Bookmark", systemImage: "plus")
                    }
                    .accessibilityIdentifier("add-bookmark-button")
                    Spacer()
                }

            }
            // Drop the navigation bar entirely — the brand header above is
            // the sole "Aperture" branding, so a nav-bar title would be a
            // duplicate. The Settings gear now lives in the brand header.
            // (Hiding the primary's nav bar doesn't affect pushed views —
            // BrowserView shows its own nav bar with a back button.)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingAddSheet) {
                BookmarkEditor(dismissAction: { showingAddSheet = false })
            }
            .fullScreenCover(isPresented: $showingSettingsSheet) {
                SettingsView(viewModel: SettingsViewModel(manager: manager),
                             dismissAction: { showingSettingsSheet = false })

            }
            .toolbarBackground(.automatic, for: .bottomBar)
        } detail: {
            Text("Select an item")
        }
        .safeAreaPadding(.top)
    }

}

