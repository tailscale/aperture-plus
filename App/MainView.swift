//
//  ContentView.swift
//  TailBrowse
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
    @State private var selectedBookmark: Bookmark?
    @State private var showConnectAlert: Bool = false
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
                    StatusView(viewModel: statusViewModel)
                }
                Group {
                    if manager.model.state == .Running {
                        BookmarkListItem(bookmark: HomePage.standard.bookmark, onSelect: handleTap)
                        BookMarkList(onSelect: handleTap)
                    }
                }
                .transition(.opacity)
            }
            // Drive the fade transition when the state changes.
            .animation(.easeInOut, value: manager.model.state)
            .navigationDestination(item: $selectedBookmark) { item in
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

                // Leading gear icon for Settings
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingSettingsSheet = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityIdentifier("settings-button")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("TailBrowser")
            .sheet(isPresented: $showingAddSheet) {
                BookmarkEditor(dismissAction: { showingAddSheet = false })
            }
            .fullScreenCover(isPresented: $showingSettingsSheet) {
                SettingsView(viewModel: SettingsViewModel(manager: manager),
                             dismissAction: { showingSettingsSheet = false })

            }
            .alert("Please Connect to Your Tailnet", isPresented: $showConnectAlert) {
                Button("OK", role: .cancel) { }
            }
            .toolbar(.visible, for: .bottomBar)
            .toolbarBackground(.automatic, for: .bottomBar)
            .toolbarBackground(.automatic, for: .navigationBar)
        } detail: {
            Text("Select an item")
        }
        .safeAreaPadding(.top)
    }

    private func handleTap(on item: Bookmark) {
        if statusViewModel.tsnetState == .Running {
            selectedBookmark = item
        } else {
            showConnectAlert = true
        }
    }

}

