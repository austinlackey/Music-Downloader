import Foundation
import Observation

/// A single user-initiated download. Wraps one playlist URL (or single video)
/// and tracks per-track + overall progress.
@Observable
@MainActor
final class DownloadJob: Identifiable {
    let id: UUID
    let url: String
    var playlistTitle: String
    var folderURL: URL
    var tracks: [Track]
    var status: JobStatus
    var errorMessage: String?
    let createdAt: Date

    /// Where this job's files are destined. Library-mode jobs download to
    /// staging and only reach the library after merge review.
    var mode: DownloadMode
    /// Staging folder for library-mode jobs. Nil in fresh-folder mode.
    var stagingURL: URL?
    /// Video ids yt-dlp skipped because they were already in the library.
    /// Surfaced as "N already in your library" rather than silently vanishing.
    var skippedVideoIDs: [String] = []

    init(
        id: UUID = UUID(),
        url: String,
        playlistTitle: String,
        folderURL: URL,
        tracks: [Track] = [],
        status: JobStatus = .pending,
        createdAt: Date = .now,
        mode: DownloadMode = .freshFolder,
        stagingURL: URL? = nil,
        skippedVideoIDs: [String] = []
    ) {
        self.id = id
        self.url = url
        self.playlistTitle = playlistTitle
        self.folderURL = folderURL
        self.tracks = tracks
        self.status = status
        self.createdAt = createdAt
        self.mode = mode
        self.stagingURL = stagingURL
        self.skippedVideoIDs = skippedVideoIDs
    }

    /// True when this job is sitting in staging waiting for the user to review
    /// and merge it.
    var awaitsMerge: Bool { mode == .library && status == .staged }

    /// True once a library-mode job has been merged. At that point the staging
    /// folder is scratch history, not the playlist's source of truth.
    var isLibraryMerged: Bool { mode == .library && status == .merged }

    /// Tracks that actually downloaded and can be merged.
    var mergeableTracks: [Track] {
        tracks.filter { track in
            guard let fileURL = track.fileURL, track.status == .completed else { return false }
            guard let stagingURL else { return true }
            return Self.isInside(fileURL, root: stagingURL)
        }
    }

    /// Entries YouTube no longer serves — deleted, private, or region-blocked.
    /// Playlists routinely outlive their videos, so these are reported to the
    /// user but kept out of every count below: a job is not "43 of 50" when
    /// seven of those fifty stopped existing years ago.
    var unavailableTracks: [Track] {
        tracks.filter { $0.status == .unavailable }
    }

    /// Tracks that YouTube can actually still serve. The denominator for all
    /// progress and completion math.
    var availableTracks: [Track] {
        tracks.filter { $0.status != .unavailable }
    }

    var unavailableCount: Int { unavailableTracks.count }

    /// Average per-track progress, 0...1.
    var overallProgress: Double {
        let available = availableTracks
        guard !available.isEmpty else { return 0 }
        return available.map(\.progress).reduce(0, +) / Double(available.count)
    }

    var completedCount: Int {
        tracks.filter { $0.status == .completed }.count
    }

    var totalCount: Int { availableTracks.count }

    var isActive: Bool {
        status == .fetchingMetadata || status == .downloading || status == .pending
    }

    /// True when the download folder has been deleted or moved externally.
    var isFolderMissing: Bool {
        guard !isLibraryMerged else { return false }
        return !FileManager.default.fileExists(atPath: folderURL.path)
    }

    private static func isInside(_ fileURL: URL, root rootURL: URL) -> Bool {
        let root = rootURL.standardizedFileURL.path
        let file = fileURL.standardizedFileURL.path
        return file == root || file.hasPrefix(root + "/")
    }
}
