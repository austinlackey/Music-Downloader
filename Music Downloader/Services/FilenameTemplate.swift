import Foundation

/// Renders a filename from a template string using resolved song metadata.
///
/// Placeholders:
/// - `{artist}`   — primary artist
/// - `{title}`    — song title
/// - `{album}`    — album name (empty if unknown)
/// - `{year}`     — 4-digit year (empty if unknown)
/// - `{track}`    — zero-padded two-digit track index
/// - `{original}` — original filename (no extension)
///
/// Missing values collapse to empty. Unknown placeholders are left alone.
/// The result is filesystem-sanitized.
nonisolated enum FilenameTemplate {
    static let defaultTemplate = "{artist} - {title}"

    static let placeholders: [(String, String)] = [
        ("{artist}",   "Primary artist"),
        ("{title}",    "Song title"),
        ("{album}",    "Album name"),
        ("{year}",     "Release year"),
        ("{track}",    "Track number"),
        ("{original}", "Original filename"),
    ]

    static func render(
        template: String,
        metadata: SongMetadata,
        trackNumber: Int?,
        originalName: String
    ) -> String {
        let values: [String: String] = [
            "{artist}":   metadata.artist,
            "{title}":    metadata.title,
            "{album}":    metadata.album ?? "",
            "{year}":     metadata.year ?? "",
            "{track}":    trackNumber.map { String(format: "%02d", $0) } ?? "",
            "{original}": originalName,
        ]
        var rendered = template
        for (key, value) in values {
            rendered = rendered.replacingOccurrences(of: key, with: value)
        }
        // Collapse any double spaces left behind by empty placeholders.
        while rendered.contains("  ") {
            rendered = rendered.replacingOccurrences(of: "  ", with: " ")
        }
        return sanitize(rendered)
    }

    /// Replace filesystem-unsafe characters with "-", then trim whitespace.
    static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?*\"<>|")
        let cleaned = name
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}
