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
    /// Track only: YouTube no longer serves this video (deleted, private, or
    /// region-blocked). Not a failure — the playlist metadata simply outlived
    /// the video, so it is excluded from progress and completion math.
    case unavailable
    /// Library mode: downloaded and enriched, waiting for merge review.
    case staged
    /// Library mode: files are being moved into the library right now.
    case merging
    /// Library mode: merge review completed and applied.
    case merged

    var displayName: String {
        switch self {
        case .pending:          "Queued"
        case .fetchingMetadata: "Loading…"
        case .downloading:      "Downloading"
        case .completed:        "Completed"
        case .failed:           "Failed"
        case .cancelled:        "Cancelled"
        case .unavailable:      "Unavailable"
        case .staged:           "Ready to merge"
        case .merging:          "Merging…"
        case .merged:           "In library"
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
        case .unavailable:      "eye.slash"
        case .staged:           "tray.full.fill"
        case .merging:          "arrow.triangle.merge"
        case .merged:           "books.vertical.fill"
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
        case .unavailable:      .secondary
        case .staged:           .orange
        case .merging:          .accentColor
        case .merged:           .green
        }
    }

    var sortOrder: Int {
        switch self {
        case .downloading:      0
        case .fetchingMetadata: 1
        case .merging:          2
        case .pending:          3
        case .staged:           4
        case .completed:        5
        case .merged:           6
        case .failed:           7
        case .cancelled:        8
        case .unavailable:      9
        }
    }

    /// True when the job is waiting on the user rather than on the machine.
    var needsAttention: Bool { self == .staged }
}
