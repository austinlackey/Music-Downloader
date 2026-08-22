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
    /// Why YouTube refused to serve this video, when `status == .unavailable`.
    /// yt-dlp's own wording, e.g. "Video unavailable" or "Private video".
    var unavailableReason: String?
    /// Whether the video is gone for good or merely age-gated. Drives whether
    /// the UI offers a retry.
    var unavailableKind: UnavailableKind?
    /// Why the last download attempt failed, when `status == .failed`. Only
    /// set for per-track downloads (re-download, one-off add) — a whole-job
    /// failure is reported on the job.
    var errorMessage: String?

    // Metadata enrichment (Phase 2)
    /// Original filename (without extension) as yt-dlp wrote it. Captured on
    /// first enrichment so "Revert to original" still works after rename.
    var originalFilename: String?
    var metadata: SongMetadata?
    var enrichmentStatus: EnrichmentStatus = .notStarted
    /// Top alternative Genius hits from the initial search, shown in the
    /// inspector sheet so the user can pick a different match.
    var alternativeMatches: [GeniusHitResult] = []

    /// Stable cross-app identifier, written into the file's tags and read back
    /// by BingoBite. Derived from the video id so re-downloading a deleted
    /// track mints the same UID and playlists relink themselves.
    var songUID: String

    /// Duration in seconds as reported by yt-dlp's flat-playlist metadata,
    /// captured before download. Used by dedupe to tell two uploads of the
    /// same song apart from two genuinely different songs.
    var sourceDuration: Double?

    /// What merge review should do with this track. Only meaningful for tracks
    /// in a staged, library-mode job.
    var mergeAction: MergeAction = .include

    /// True when a file was expected but no longer exists on disk.
    var isFileMissing: Bool {
        guard let url = fileURL else { return false }
        return !FileManager.default.fileExists(atPath: url.path)
    }

    init(id: String, title: String, songUID: String? = nil) {
        self.id = id
        self.title = title
        // A synthesized placeholder id (single videos with no metadata id)
        // must not become `ytdl:single` — that would collide across every
        // such download. Fall back to a random local UID instead.
        self.songUID = songUID
            ?? (Self.isPlausibleVideoID(id) ? SongUID.mint(videoID: id) : SongUID.mintLocal())
    }

    /// YouTube video ids are 11 characters of `[A-Za-z0-9_-]`.
    private static func isPlausibleVideoID(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy {
            $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || $0 == "_" || $0 == "-"
        }
    }
}
