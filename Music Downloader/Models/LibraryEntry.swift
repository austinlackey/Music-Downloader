import Foundation

/// One song in the master library.
///
/// This single record serves two files: the private ledger
/// (`.bingobite/library-ledger.json`, which drives dedupe and export tracking)
/// and the public manifest (`bingobite-library.json`, which BingoBite reads).
/// Field names are snake_case to match the vocabulary the existing
/// `download_playlist.py` already emits.
nonisolated struct LibraryEntry: Codable, Sendable, Hashable, Identifiable {
    /// Stable identifier, also written into the file's tags. See `SongUID`.
    var uid: String
    /// Filename relative to the library root, including extension.
    var file: String
    var name: String
    var artist: String
    var album: String?
    var durationSeconds: Double?
    var year: String?
    var releaseDate: String?
    var genre: String?
    var coverArtURL: String?
    var sourceVideoID: String?
    var geniusURL: String?
    var geniusID: Int?
    var fileSize: Int64?
    /// User-defined fields, passed through to BingoBite in the manifest.
    var customFields: [CustomField]?

    /// When this entry was merged into the library.
    var addedAt: Date?
    /// When this song was last written into an export folder. `nil` means it
    /// has never been exported, which is what an incremental export selects on.
    var exportedAt: Date?

    var id: String { uid }

    enum CodingKeys: String, CodingKey {
        case uid
        case file
        case name
        case artist
        case album
        case durationSeconds = "duration_seconds"
        case year
        case releaseDate = "release_date"
        case genre
        case coverArtURL = "cover_art_url"
        case sourceVideoID = "source_video_id"
        case geniusURL = "genius_url"
        case geniusID = "genius_id"
        case fileSize = "file_size"
        case customFields = "custom_fields"
        case addedAt = "added_at"
        case exportedAt = "exported_at"
    }

    /// Builds an entry from an enriched track. Returns nil when the track has
    /// no file on disk — an unenriched or failed track has nothing to record.
    @MainActor
    static func make(from track: Track, libraryFileName: String) -> LibraryEntry? {
        guard track.fileURL != nil else { return nil }
        let metadata = track.metadata
        let size = track.fileURL.flatMap {
            (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init)
        }
        return LibraryEntry(
            uid: track.songUID,
            file: libraryFileName,
            name: metadata?.title ?? track.title,
            artist: metadata?.artist ?? "",
            album: metadata?.album,
            durationSeconds: track.sourceDuration,
            year: metadata?.year,
            releaseDate: metadata?.releaseDate,
            genre: metadata?.genre,
            coverArtURL: metadata?.coverArtURL?.absoluteString,
            sourceVideoID: SongUID.parse(track.songUID)?.videoID,
            geniusURL: metadata?.geniusURL?.absoluteString,
            geniusID: metadata?.geniusID,
            fileSize: size,
            customFields: metadata?.customFields,
            addedAt: .now,
            exportedAt: nil
        )
    }
}
