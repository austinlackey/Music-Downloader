import Foundation
import SwiftUI

/// Lifecycle state for a single track's metadata enrichment pass.
nonisolated enum EnrichmentStatus: Codable, Sendable, Hashable {
    case notStarted
    case searching
    case matched          // Genius hit resolved, tags not yet written
    case writing          // ffmpeg running
    case enriched         // tags written + file renamed
    case failed(String)
    case skipped          // user excluded this track

    var displayName: String {
        switch self {
        case .notStarted:    "Not enriched"
        case .searching:     "Searching Genius…"
        case .matched:       "Matched"
        case .writing:       "Writing tags…"
        case .enriched:      "Enriched"
        case .failed(let m): "Failed: \(m)"
        case .skipped:       "Skipped"
        }
    }

    var symbolName: String {
        switch self {
        case .notStarted:    "sparkles"
        case .searching:     "magnifyingglass"
        case .matched:       "checkmark.circle"
        case .writing:       "square.and.pencil"
        case .enriched:      "sparkles.rectangle.stack.fill"
        case .failed:        "exclamationmark.triangle.fill"
        case .skipped:       "minus.circle"
        }
    }

    var tint: Color {
        switch self {
        case .notStarted:    .secondary
        case .searching:     .accentColor
        case .matched:       .accentColor
        case .writing:       .accentColor
        case .enriched:      .purple
        case .failed:        .red
        case .skipped:       .secondary
        }
    }

    var isInFlight: Bool {
        switch self {
        case .searching, .writing, .matched: true
        default: false
        }
    }
}
