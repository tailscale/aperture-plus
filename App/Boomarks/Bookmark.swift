//  Created by Jonathan Nobels on 2025-12-16.
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

final class HomePage {
    /// The default home page loaded when the user hasn't set one. Points at
    /// the Aperture chat UI on the tailnet.
    static let defaultURL = "http://ai/chat"

    let key: String

    static var standard = HomePage(key: "default_homepage")

    init(key: String) {
        self.key = key
    }

    var url: String {
        get {
            UserDefaults.standard.string(forKey: "homepage") ?? HomePage.defaultURL
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "homepage")

        }
    }

    var bookmark: Bookmark {
        Bookmark(timestamp: Date(), name: "Home Page", url: url)
    }
}
