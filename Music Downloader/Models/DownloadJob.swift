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

    init(
        id: UUID = UUID(),
        url: String,
        playlistTitle: String,
        folderURL: URL,
        tracks: [Track] = [],
        status: JobStatus = .pending,
        createdAt: Date = .now
    ) {
        self.id = id
        self.url = url
        self.playlistTitle = playlistTitle
        self.folderURL = folderURL
        self.tracks = tracks
        self.status = status
        self.createdAt = createdAt
    }

    /// Average per-track progress, 0...1.
    var overallProgress: Double {
        guard !tracks.isEmpty else { return 0 }
        return tracks.map(\.progress).reduce(0, +) / Double(tracks.count)
    }

    var completedCount: Int {
        tracks.filter { $0.status == .completed }.count
    }

    var totalCount: Int { tracks.count }

    var isActive: Bool {
        status == .fetchingMetadata || status == .downloading || status == .pending
    }
}
