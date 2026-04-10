import Foundation
import Observation

/// A single audio track within a `DownloadJob`. One playlist entry → one Track.
@Observable
@MainActor
final class Track: Identifiable {
    /// YouTube video id (e.g. `dQw4w9WgXcQ`).
    let id: String
    var title: String
    var status: JobStatus = .pending
    /// 0.0 ... 1.0
    var progress: Double = 0
    var fileURL: URL?

    // Metadata enrichment (Phase 2)
    /// Original filename (without extension) as yt-dlp wrote it. Captured on
    /// first enrichment so "Revert to original" still works after rename.
    var originalFilename: String?
    var metadata: SongMetadata?
    var enrichmentStatus: EnrichmentStatus = .notStarted
    /// Top alternative Genius hits from the initial search, shown in the
    /// inspector sheet so the user can pick a different match.
    var alternativeMatches: [GeniusHitResult] = []

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}
