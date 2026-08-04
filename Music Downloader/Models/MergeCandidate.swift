import Foundation
import SwiftUI

/// What to do with a staged track when merging into the library.
nonisolated enum MergeAction: String, Codable, Sendable, Hashable, CaseIterable {
    /// Copy into the library. Default for anything not flagged as a duplicate.
    case include
    /// Leave in staging, don't add. Default for confident duplicates.
    case skip
    /// Overwrite the library's existing copy with this one — the staged encode
    /// is sometimes better than what's already there.
    case replace

    var displayName: String {
        switch self {
        case .include: "Add"
        case .skip:    "Skip"
        case .replace: "Replace"
        }
    }

    var symbolName: String {
        switch self {
        case .include: "plus.circle.fill"
        case .skip:    "minus.circle"
        case .replace: "arrow.triangle.2.circlepath.circle.fill"
        }
    }
}

/// Why a staged track was considered a duplicate — the rung of the ladder it
/// matched on. Ordered from most to least confident.
nonisolated enum DuplicateVerdict: Codable, Sendable, Hashable {
    /// Nothing in the library matches.
    case unique
    /// Same YouTube video. Should have been caught pre-download; reaching merge
    /// review means the archive file was missing or stale.
    case sameVideo(existingFile: String)
    /// Same Genius song id — a different upload of the same song. The signal
    /// this whole feature exists for.
    case sameGeniusSong(existingFile: String)
    /// Normalized artist + title match, durations within 5s.
    case sameMetadata(existingFile: String, deltaSeconds: Double)
    /// Weaker: title-only match, or artist+title with a 5–20s gap. Could be a
    /// radio edit, a live version, or a genuinely different song.
    case probableMatch(existingFile: String, deltaSeconds: Double?)
    /// Fuzzy string similarity only. Never acted on automatically.
    case possibleMatch(existingFile: String, score: Double)

    /// True when this verdict is confident enough to pre-select "skip".
    var isConfidentDuplicate: Bool {
        switch self {
        case .sameVideo, .sameGeniusSong, .sameMetadata: true
        case .unique, .probableMatch, .possibleMatch: false
        }
    }

    /// The library file this collides with, if any.
    var existingFile: String? {
        switch self {
        case .unique: nil
        case .sameVideo(let f), .sameGeniusSong(let f), .sameMetadata(let f, _),
             .probableMatch(let f, _), .possibleMatch(let f, _): f
        }
    }

    var displayName: String {
        switch self {
        case .unique:           "New"
        case .sameVideo:        "Already downloaded"
        case .sameGeniusSong:   "Same song, different upload"
        case .sameMetadata:     "Same artist and title"
        case .probableMatch:    "Possible duplicate"
        case .possibleMatch:    "Similar title"
        }
    }

    var symbolName: String {
        switch self {
        case .unique:         "sparkles"
        case .sameVideo:      "arrow.down.circle.fill"
        case .sameGeniusSong: "doc.on.doc.fill"
        case .sameMetadata:   "equal.circle.fill"
        case .probableMatch:  "questionmark.circle.fill"
        case .possibleMatch:  "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .unique:                        .green
        case .sameVideo, .sameGeniusSong:    .secondary
        case .sameMetadata:                  .orange
        case .probableMatch, .possibleMatch: .yellow
        }
    }

    /// Which section of the merge review this row belongs in.
    var bucket: MergeBucket {
        switch self {
        case .unique:                                     .new
        case .sameVideo, .sameGeniusSong, .sameMetadata:  .duplicates
        case .probableMatch, .possibleMatch:              .review
        }
    }
}

/// The three sections of the merge review screen.
nonisolated enum MergeBucket: String, CaseIterable, Identifiable, Sendable {
    case new
    case duplicates
    case review

    var id: String { rawValue }

    var title: String {
        switch self {
        case .new:        "New"
        case .duplicates: "Duplicates"
        case .review:     "Needs a look"
        }
    }

    var explanation: String {
        switch self {
        case .new:        "Not in your library yet."
        case .duplicates: "Already in your library. Skipped unless you say otherwise."
        case .review:     "Might be duplicates. Added unless you skip them."
        }
    }
}

/// One staged track, paired with what dedupe decided about it and what the
/// user wants done. Built fresh each time merge review opens.
@Observable
@MainActor
final class MergeCandidate: Identifiable {
    /// Stored rather than computed from `track` so the `Identifiable`
    /// conformance stays readable off the MainActor, matching `Track`.
    nonisolated let id: String
    let track: Track
    let verdict: DuplicateVerdict
    var action: MergeAction

    init(track: Track, verdict: DuplicateVerdict) {
        self.id = track.songUID
        self.track = track
        self.verdict = verdict
        // Confident duplicates default to skip; everything else defaults to add.
        self.action = verdict.isConfidentDuplicate ? .skip : .include
    }

    var bucket: MergeBucket { verdict.bucket }

    var displayTitle: String { track.metadata?.title ?? track.title }
    var displayArtist: String { track.metadata?.artist ?? "Unknown Artist" }
}
