import SwiftUI

#if canImport(UIKit)
import UIKit

extension Color {
    static let platformSystemBackground = Color(uiColor: .systemBackground)
    static let platformSecondarySystemBackground = Color(uiColor: .secondarySystemBackground)
    static let platformSystemGroupedBackground = Color(uiColor: .systemGroupedBackground)
    static let platformSeparator = Color(uiColor: .separator)
}
#else
import AppKit

extension Color {
    static let platformSystemBackground = Color(nsColor: .windowBackgroundColor)
    static let platformSecondarySystemBackground = Color(nsColor: .controlBackgroundColor)
    static let platformSystemGroupedBackground = Color(nsColor: .underPageBackgroundColor)
    static let platformSeparator = Color(nsColor: .separatorColor)
}
#endif
