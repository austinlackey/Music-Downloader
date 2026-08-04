import Foundation

/// A playlist occurrence for one library song.
nonisolated struct LibraryPlaylistMembership: Identifiable, Sendable, Hashable {
    var playlistID: UUID
    var name: String
    var position: Int
    var totalCount: Int

    var id: UUID { playlistID }
}
