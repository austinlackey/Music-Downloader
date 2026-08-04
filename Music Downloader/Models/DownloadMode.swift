import Foundation
import SwiftUI

/// Where a download's files end up.
///
/// Follows the `JobStatus` convention of carrying its own presentation, so
/// views can render a mode without a switch statement of their own.
enum DownloadMode: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    /// Today's behavior: one folder per playlist under the download root,
    /// nothing skipped, nothing deduped.
    case freshFolder
    /// Skip anything already in the library, download the rest to staging,
    /// then merge into the library after review.
    case library

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .freshFolder: "New Folder"
        case .library:     "Library"
        }
    }

    var symbolName: String {
        switch self {
        case .freshFolder: "folder.badge.plus"
        case .library:     "books.vertical"
        }
    }

    var tint: Color {
        switch self {
        case .freshFolder: .secondary
        case .library:     .accentColor
        }
    }

    /// One-line explanation shown under the mode picker.
    var explanation: String {
        switch self {
        case .freshFolder:
            "Downloads every track to its own folder. Nothing is skipped."
        case .library:
            "Skips tracks already in your library, then asks before merging the rest in."
        }
    }
}
