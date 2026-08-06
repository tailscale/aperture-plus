//  Created by Jonathan Nobels on 2025-12-17.
//

import SwiftUI
import SwiftData

struct BookmarkEditor: View {
    @Environment(\.modelContext) private var modelContext

    var dismissAction: () -> Void

    @State private var newName: String
    @State private var newURLString: String

    // Custom initializer to seed state from initial values
    init(dismissAction: @escaping () -> Void, initialName: String? = nil, initialURLString: String? = nil) {
        self.dismissAction = dismissAction
        newName = initialName ?? ""
        newURLString = initialURLString ?? ""
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Details")) {
                    TextField("Name", text: $newName)
#if canImport(UIKit)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
#endif
                        .accessibilityIdentifier("bookmark-name-field")
                    TextField("URL", text: $newURLString)
#if canImport(UIKit)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
#endif
                        .accessibilityIdentifier("bookmark-url-field")
                }
            }
            .navigationTitle("New Bookmark")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismissAction()
                    }
                    .accessibilityIdentifier("bookmark-cancel-button")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        addItem()
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("bookmark-save-button")
                }
            }
        }
#if canImport(UIKit)
        .presentationDetents([.medium, .large])
#endif
    }

    private var canSave: Bool {
        // Require non-empty name and a valid URL that URL(string:) can parse and has a scheme/host
        guard !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let trimmed = newURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else { return false }
        return true
    }

    private func addItem() {
        guard canSave else { return }
        withAnimation {
            let trimmedURL = newURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            let newItem = Bookmark(timestamp: Date(), name: trimmedName, url: trimmedURL)
            modelContext.insert(newItem)
        }
        dismissAction()
    }
}

