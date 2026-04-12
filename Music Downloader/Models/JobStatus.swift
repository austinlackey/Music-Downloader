import Foundation
import SwiftUI

/// Lifecycle state for a download job or an individual track within one.
enum JobStatus: String, Codable, Hashable, Sendable {
    case pending
    case fetchingMetadata
    case downloading
    case completed
    case failed
    case cancelled

    var displayName: String {
        switch self {
        case .pending:          "Queued"
        case .fetchingMetadata: "Loading…"
        case .downloading:      "Downloading"
        case .completed:        "Completed"
        case .failed:           "Failed"
        case .cancelled:        "Cancelled"
        }
    }

    var symbolName: String {
        switch self {
        case .pending:          "clock"
        case .fetchingMetadata: "magnifyingglass"
        case .downloading:      "arrow.down.circle"
        case .completed:        "checkmark.circle.fill"
        case .failed:           "exclamationmark.triangle.fill"
        case .cancelled:        "xmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .pending:          .secondary
        case .fetchingMetadata: .accentColor
        case .downloading:      .accentColor
        case .completed:        .green
        case .failed:           .red
        case .cancelled:        .secondary
        }
    }

    var sortOrder: Int {
        switch self {
        case .downloading:      0
        case .fetchingMetadata: 1
        case .pending:          2
        case .completed:        3
        case .failed:           4
        case .cancelled:        5
        }
    }
}
