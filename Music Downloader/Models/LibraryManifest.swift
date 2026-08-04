import Foundation

/// The public handoff format between Music Downloader and BingoBite.
///
/// Written as `bingobite-library.json` at the root of the library folder and
/// of every export folder. BingoBite treats it as a **hint layer, never as
/// truth** — it accelerates uid→file resolution and lets playlists be created
/// with zero typing, but the on-disk contents always win on conflict.
///
/// Mirrored in BingoBite as `Shared/Services/LibraryManifest.swift`. The
/// snake_case keys are the contract; don't rename them without changing both.
nonisolated struct LibraryManifest: Codable, Sendable {
    /// Bumped only for breaking shape changes. Readers should refuse a version
    /// they don't recognize rather than guessing.
    static let currentVersion = 1

    var manifestVersion: Int = LibraryManifest.currentVersion
    var generatedAt: Date
    var generator: String
    var libraryName: String?
    /// Songs whose files are present in *this* folder. For an incremental
    /// export that's the delta, not the whole library.
    var songs: [LibraryEntry]
    var playlists: [PlaylistDefinition]

    enum CodingKeys: String, CodingKey {
        case manifestVersion = "manifest_version"
        case generatedAt = "generated_at"
        case generator
        case libraryName = "library_name"
        case songs
        case playlists
    }

    /// A playlist described by song UIDs rather than file paths, so it survives
    /// renames and can reference songs delivered in an earlier export.
    nonisolated struct PlaylistDefinition: Codable, Sendable, Identifiable {
        var uuid: String
        var name: String
        var description: String?
        /// Ordered. BingoBite's card grids index into this positionally.
        var songUIDs: [String]

        var id: String { uuid }

        enum CodingKeys: String, CodingKey {
            case uuid
            case name
            case description
            case songUIDs = "song_uids"
        }
    }

    /// True when this manifest came from a version this build understands.
    var isReadable: Bool {
        manifestVersion <= LibraryManifest.currentVersion
    }
}
