import Foundation

/// Renders a playlist as plain text the user can paste into BingoBite.
///
/// The format is shaped by one constraint: it has to survive a round trip
/// through Notes, Messages, or Mail, which rewrite text as you paste it.
///
///     #BingoBite Playlist: 2000s Bangers
///     Outkast — Hey Ya! [u:ytdl-PWgvGjAhvIw]
///
/// Rules that come from that constraint:
/// - **No tabs, no leading `1. `, no leading `- `** — each one makes Notes
///   convert the block into a list and eat the structure.
/// - Smart substitution rewrites `--` as `—` and straightens quotes, so the
///   writer emits ` — ` and the parser accepts every variant it might come
///   back as.
/// - The UID uses `-` instead of `:` inside the brackets, because `ytdl:` at
///   the start of a token gets link-detected and turned into a hyperlink.
/// - The UID is optional. A hand-typed `Artist — Title` line still matches,
///   just one rung lower.
///
/// The parsing half lives in BingoBite as `SongListParser`. Keep the two in
/// sync — this is a wire format between two apps.
nonisolated enum PlaylistTextExporter {

    static let headerPrefix = "#BingoBite Playlist:"
    static let separator = " — "

    /// UID token as it appears in the text, e.g. `[u:ytdl-dQw4w9WgXcQ]`.
    static func uidToken(for uid: String) -> String? {
        guard let parsed = SongUID.parse(uid) else { return nil }
        return "[u:\(parsed.namespace)-\(parsed.value)]"
    }

    /// Reverses `uidToken(for:)`.
    static func uid(fromToken token: String) -> String? {
        var body = token
        if body.hasPrefix("[") { body.removeFirst() }
        if body.hasSuffix("]") { body.removeLast() }
        guard body.hasPrefix("u:") else { return nil }
        body.removeFirst(2)
        guard let dash = body.firstIndex(of: "-") else { return nil }
        let namespace = String(body[body.startIndex..<dash])
        let value = String(body[body.index(after: dash)...])
        guard !namespace.isEmpty, !value.isEmpty else { return nil }
        return "\(namespace):\(value)"
    }

    // MARK: - Rendering

    /// Renders a job's enriched tracks as a pasteable song list.
    @MainActor
    static func render(job: DownloadJob) -> String {
        render(
            name: job.playlistTitle,
            songs: job.tracks.compactMap { track -> (artist: String, title: String, uid: String)? in
                // Unenriched tracks have no reliable artist, and a line with a
                // wrong artist matches worse than no line at all.
                guard let metadata = track.metadata else { return nil }
                return (metadata.artist, metadata.title, track.songUID)
            }
        )
    }

    /// Renders library entries as a pasteable song list.
    static func render(name: String, entries: [LibraryEntry]) -> String {
        render(
            name: name,
            songs: entries.map { (artist: $0.artist, title: $0.name, uid: $0.uid) }
        )
    }

    static func render(name: String, songs: [(artist: String, title: String, uid: String)]) -> String {
        var lines: [String] = ["\(headerPrefix) \(sanitizeHeader(name))"]
        for song in songs {
            var line = "\(sanitizeField(song.artist))\(separator)\(sanitizeField(song.title))"
            if let token = uidToken(for: song.uid) {
                line += " \(token)"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Sanitizing

    /// Strips anything that would break parsing on the way back in: newlines
    /// split one song into two, and a literal separator inside a field makes
    /// the artist/title split ambiguous.
    private static func sanitizeField(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: separator, with: " - ")
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func sanitizeHeader(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
