import Foundation

/// Minimal projection of `yt-dlp --flat-playlist --dump-single-json` output.
///
/// For a single video URL, `entries` is `nil` and the top-level `id`/`title`
/// describe that one video. For a playlist URL, `title` is the playlist name
/// and `entries` lists the videos.
nonisolated struct PlaylistMetadata: Decodable, Sendable {
    let id: String?
    let title: String?
    let entries: [Entry]?

    nonisolated struct Entry: Decodable, Sendable {
        let id: String
        let title: String?
        let duration: Double?
    }
}
