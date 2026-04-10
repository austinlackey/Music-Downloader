import Foundation

/// Resolved metadata for a single track, typically pulled from Genius and
/// injected into the mp3 via ffmpeg. Persisted with the Track snapshot.
nonisolated struct SongMetadata: Codable, Sendable, Hashable {
    var title: String
    var artist: String
    var album: String?
    var year: String?           // "2023" — extracted from Genius release_date
    var coverArtURL: URL?
    var geniusID: Int?
    var geniusURL: URL?

    /// Convenience factory for SwiftUI previews / settings placeholders.
    static let sample = SongMetadata(
        title: "Me at the zoo",
        artist: "jawed",
        album: "YouTube",
        year: "2005",
        coverArtURL: nil,
        geniusID: nil,
        geniusURL: nil
    )
}
