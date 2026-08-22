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
    /// Why the whole run failed, when it failed for a reason the user can act
    /// on. Drives the banner that offers the remedy, so it is persisted --
    /// relaunching the app does not un-stale the bundled downloader.
    var failureKind: RunFailureKind?
    let createdAt: Date

    /// Where this job's files are destined. Library-mode jobs download to
    /// staging and only reach the library after merge review.
    var mode: DownloadMode
    /// Staging folder for library-mode jobs. Nil in fresh-folder mode.
    var stagingURL: URL?
    /// Video ids yt-dlp skipped because they were already in the library.
    /// Surfaced as "N already in your library" rather than silently vanishing.
    var skippedVideoIDs: [String] = []

    /// Audio files found in this playlist's folder that no track accounts for.
    /// Populated by a folder refresh and deliberately not persisted — the
    /// folder is the source of truth, so a stale list would be worse than none.
    var discoveredFiles: [DiscoveredFile] = []
    /// When the folder was last reconciled against disk.
    var lastFolderScan: Date?

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

    /// Unavailable entries split by cause, since the two need different copy
    /// and only one of them is worth retrying.
    func unavailableTracks(of kind: UnavailableKind) -> [Track] {
        unavailableTracks.filter { ($0.unavailableKind ?? .removed) == kind }
    }

    /// True when at least one entry failed the age gate — the case a retry
    /// with browser cookies can actually fix.
    var hasAgeRestrictedTracks: Bool {
        unavailableTracks.contains { $0.unavailableKind == .ageRestricted }
    }

    /// Tracks whose file was expected on disk but isn't there any more.
    var missingTracks: [Track] {
        tracks.filter(\.isFileMissing)
    }

    /// The folder a refresh should reconcile against, or nil when this job has
    /// no folder of its own.
    ///
    /// A merged library job's `folderURL` is the whole library root, shared
    /// with every other playlist — scanning it would report every unrelated
    /// library song as a new file, so those jobs get no folder sync.
    var syncFolderURL: URL? {
        if let stagingURL, status == .staged { return stagingURL }
        return mode == .freshFolder ? folderURL : nil
    }

    /// Why folder sync is unavailable, for the disabled button's tooltip.
    var folderSyncUnavailableReason: String? {
        guard syncFolderURL == nil else { return nil }
        return "This playlist lives in your library, which is shared with every other playlist. Refresh only works on a playlist that owns its folder."
    }

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
