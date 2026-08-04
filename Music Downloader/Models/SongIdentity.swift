import Foundation

/// A stable identifier for a song, written into the audio file itself as a
/// TXXX frame so it survives renames, folder moves, and being copied to
/// another device.
///
/// The UID is **deterministic from the source video ID**, not random. That is
/// the whole point: if a file is deleted and later re-downloaded, it mints the
/// same UID, and every BingoBite playlist referencing it relinks itself with no
/// user action. A random UUID would break that.
///
/// This file is mirrored verbatim in BingoBite as `Shared/Models/SongUID.swift`.
/// Keep the two in sync — the key names and value grammar are the contract
/// between the two apps.
nonisolated enum SongUID {

    // MARK: - TXXX keys

    /// The stable song identifier. Value is `ytdl:<videoID>` or `mdl:<uuid>`.
    static let uidKey = "SONG_UID"
    /// The raw YouTube video ID, kept separately so dedupe can compare it
    /// without parsing the UID grammar.
    static let sourceVideoIDKey = "SOURCE_VIDEO_ID"
    /// Genius song ID as a decimal string. The signal that catches "same song,
    /// different upload".
    static let geniusIDKey = "GENIUS_ID"

    /// Every key this scheme writes, for callers that need to strip or audit them.
    static let allKeys = [uidKey, sourceVideoIDKey, geniusIDKey]

    // MARK: - Namespaces

    static let youtubeNamespace = "ytdl"
    static let localNamespace = "mdl"

    // MARK: - Minting

    /// The UID for a track downloaded from YouTube. Deterministic.
    static func mint(videoID: String) -> String {
        "\(youtubeNamespace):\(videoID)"
    }

    /// The UID for a track with no source video (imported, hand-added).
    /// Random by necessity — there is nothing stable to derive from.
    static func mintLocal() -> String {
        "\(localNamespace):\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
    }

    // MARK: - Parsing

    struct Parsed: Equatable {
        let namespace: String
        let value: String

        var isYouTube: Bool { namespace == SongUID.youtubeNamespace }
        /// The source video ID when this UID came from YouTube.
        var videoID: String? { isYouTube ? value : nil }
    }

    /// Splits a UID into its namespace and value. Returns nil for anything
    /// that isn't a well-formed UID, including empty strings.
    static func parse(_ uid: String?) -> Parsed? {
        guard let uid else { return nil }
        let trimmed = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(of: ":") else { return nil }
        let namespace = String(trimmed[trimmed.startIndex..<separator])
        let value = String(trimmed[trimmed.index(after: separator)...])
        guard !namespace.isEmpty, !value.isEmpty else { return nil }
        return Parsed(namespace: namespace, value: value)
    }

    /// True when the string is a UID this scheme would recognize.
    static func isValid(_ uid: String?) -> Bool {
        parse(uid) != nil
    }
}
