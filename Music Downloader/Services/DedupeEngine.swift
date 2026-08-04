import Foundation

/// Decides whether a staged track is already in the library.
///
/// Pure — no file access, no actor isolation, no state. Everything it needs is
/// passed in, which makes each rung of the ladder independently testable.
///
/// The ladder runs most-confident first and stops at the first hit:
///
/// 1. Same YouTube video id
/// 2. Same Genius song id  ← catches "different upload, same song"
/// 3. Normalized artist + title, durations within 5s
/// 4. Title-only, or artist + title with a 5–20s gap
/// 5. Fuzzy similarity ≥ 0.90
nonisolated enum DedupeEngine {

    /// Durations this close are treated as the same recording.
    static let sameRecordingTolerance: Double = 5
    /// Beyond this, a metadata match is probably a different song entirely.
    static let probableMatchTolerance: Double = 20
    /// Minimum similarity before a fuzzy match is even worth showing.
    static let fuzzyThreshold: Double = 0.90

    /// A library snapshot in the shape the ladder needs. Built once per merge
    /// review rather than per candidate.
    struct LibrarySnapshot {
        var byVideoID: [String: LibraryEntry] = [:]
        var byGeniusID: [Int: LibraryEntry] = [:]
        var byNormalizedKey: [String: LibraryEntry] = [:]
        var byNormalizedTitle: [String: LibraryEntry] = [:]
        /// Kept in insertion order for the fuzzy pass, which has to scan.
        var all: [LibraryEntry] = []

        init(entries: [LibraryEntry]) {
            all = entries
            for entry in entries {
                if let videoID = entry.sourceVideoID, !videoID.isEmpty {
                    byVideoID[videoID] = entry
                }
                if let geniusID = entry.geniusID {
                    byGeniusID[geniusID] = entry
                }
                let key = DedupeEngine.normalizedKey(artist: entry.artist, title: entry.name)
                if !key.isEmpty, byNormalizedKey[key] == nil {
                    byNormalizedKey[key] = entry
                }
                let titleKey = DedupeEngine.normalize(entry.name)
                if !titleKey.isEmpty, byNormalizedTitle[titleKey] == nil {
                    byNormalizedTitle[titleKey] = entry
                }
            }
        }
    }

    /// What the ladder needs to know about a staged track. Decoupled from
    /// `Track` so this stays testable without a MainActor.
    struct Candidate {
        var videoID: String?
        var geniusID: Int?
        var artist: String
        var title: String
        var duration: Double?
    }

    // MARK: - The ladder

    static func classify(_ candidate: Candidate, against library: LibrarySnapshot) -> DuplicateVerdict {
        // L1 — same source video.
        if let videoID = candidate.videoID, let hit = library.byVideoID[videoID] {
            return .sameVideo(existingFile: hit.file)
        }

        // L2 — same Genius song, different upload.
        if let geniusID = candidate.geniusID, let hit = library.byGeniusID[geniusID] {
            return .sameGeniusSong(existingFile: hit.file)
        }

        // L3/L4 — normalized artist + title, split by how close the durations are.
        let key = normalizedKey(artist: candidate.artist, title: candidate.title)
        if !key.isEmpty, let hit = library.byNormalizedKey[key] {
            let delta = durationDelta(candidate.duration, hit.durationSeconds)
            switch delta {
            case .some(let d) where d <= sameRecordingTolerance:
                return .sameMetadata(existingFile: hit.file, deltaSeconds: d)
            case .some(let d) where d <= probableMatchTolerance:
                return .probableMatch(existingFile: hit.file, deltaSeconds: d)
            case .some(let d):
                // Same artist and title but minutes apart — an extended mix or
                // a live cut. Worth showing, not worth auto-skipping.
                return .probableMatch(existingFile: hit.file, deltaSeconds: d)
            case .none:
                // No duration on one side. Metadata alone is a strong signal,
                // but without a duration to corroborate it, don't auto-skip.
                return .probableMatch(existingFile: hit.file, deltaSeconds: nil)
            }
        }

        // L4b — title matches but the artist doesn't. Common when one side has
        // a featured artist baked into the artist field.
        let titleKey = normalize(candidate.title)
        if !titleKey.isEmpty, let hit = library.byNormalizedTitle[titleKey] {
            return .probableMatch(
                existingFile: hit.file,
                deltaSeconds: durationDelta(candidate.duration, hit.durationSeconds)
            )
        }

        // L5 — fuzzy. Only reached when everything above missed.
        if !key.isEmpty {
            var best: (entry: LibraryEntry, score: Double)?
            for entry in library.all {
                let entryKey = normalizedKey(artist: entry.artist, title: entry.name)
                guard !entryKey.isEmpty else { continue }
                let score = similarity(key, entryKey)
                if score >= fuzzyThreshold, score > (best?.score ?? 0) {
                    best = (entry, score)
                }
            }
            if let best {
                return .possibleMatch(existingFile: best.entry.file, score: best.score)
            }
        }

        return .unique
    }

    // MARK: - Normalization

    /// Noise that appears in YouTube titles but never distinguishes two songs.
    private static let noisePatterns = [
        #"\(.*?\)"#,
        #"\[.*?\]"#,
        #"\bfeat\.?\b.*$"#,
        #"\bft\.?\b.*$"#,
        #"\bofficial\s+(music\s+)?video\b"#,
        #"\bofficial\s+audio\b"#,
        #"\blyrics?\b"#,
        #"\blyric\s+video\b"#,
        #"\bremaster(ed)?(\s+\d{4})?\b"#,
        #"\bhd\b"#,
        #"\b4k\b"#,
        #"\baudio\b"#,
        #"\bhq\b"#,
    ]

    /// Lowercase, strip accents, strip bracketed noise and marketing suffixes,
    /// drop everything that isn't alphanumeric, collapse whitespace.
    ///
    /// The goal is that "Song Title (Official Video) [HD]" and
    /// "Song Title - Remastered 2011" both reduce to "songtitle".
    static func normalize(_ raw: String) -> String {
        var text = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        for pattern in noisePatterns {
            text = text.replacingOccurrences(
                of: pattern,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        let stripped = text.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        return String(String.UnicodeScalarView(stripped))
    }

    /// The composite key both sides of a comparison reduce to.
    static func normalizedKey(artist: String, title: String) -> String {
        let a = normalize(artist)
        let t = normalize(title)
        guard !t.isEmpty else { return "" }
        return a.isEmpty ? t : "\(a)|\(t)"
    }

    // MARK: - Duration

    /// Absolute gap in seconds, or nil when either side is unknown.
    static func durationDelta(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard let lhs, let rhs, lhs > 0, rhs > 0 else { return nil }
        return abs(lhs - rhs)
    }

    // MARK: - Fuzzy matching

    /// Normalized Levenshtein similarity in 0...1, where 1 is identical.
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs { return 1 }
        if lhs.isEmpty || rhs.isEmpty { return 0 }
        let distance = levenshtein(Array(lhs), Array(rhs))
        let longest = max(lhs.count, rhs.count)
        return 1 - (Double(distance) / Double(longest))
    }

    /// Two-row Levenshtein — O(n·m) time, O(min(n,m)) space.
    private static func levenshtein(_ lhs: [Character], _ rhs: [Character]) -> Int {
        // Iterate over the shorter string to keep the row small.
        let (short, long) = lhs.count <= rhs.count ? (lhs, rhs) : (rhs, lhs)
        var previous = Array(0...short.count)
        var current = [Int](repeating: 0, count: short.count + 1)

        for (i, longChar) in long.enumerated() {
            current[0] = i + 1
            for (j, shortChar) in short.enumerated() {
                let substitution = previous[j] + (longChar == shortChar ? 0 : 1)
                current[j + 1] = min(
                    previous[j + 1] + 1,   // deletion
                    current[j] + 1,        // insertion
                    substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[short.count]
    }
}
