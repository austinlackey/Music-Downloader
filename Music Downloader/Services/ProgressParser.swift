import Foundation

/// Events emitted by the yt-dlp Process bridge.
nonisolated enum YTDLPEvent: Sendable {
    case trackStarted(videoID: String, title: String, index: Int)
    case trackProgress(videoID: String, fraction: Double)
    case trackFinished(videoID: String, filePath: String)
    case trackUnavailable(videoID: String, reason: String, kind: UnavailableKind)
    case logLine(String)
    case failed(String)
    case finished
}

/// Why yt-dlp could not fetch a particular playlist entry.
///
/// Both kinds are per-entry, not per-run: neither should sink a job that is
/// otherwise fine. They differ in whether the video still exists, which is the
/// difference between "give up on it" and "sign in and try again".
nonisolated enum UnavailableKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// Deleted, private, terminated, or region-blocked. Nothing to retry.
    case removed
    /// Age-gated. YouTube still has the video; it wants a signed-in session
    /// before it will serve it.
    case ageRestricted

    var displayName: String {
        switch self {
        case .removed:       "Unavailable"
        case .ageRestricted: "Age-restricted"
        }
    }

    var symbolName: String {
        switch self {
        case .removed:       "eye.slash"
        case .ageRestricted: "person.crop.circle.badge.exclamationmark"
        }
    }

    /// Headline for the banner and popover grouping these entries.
    var groupTitle: String {
        switch self {
        case .removed:       "No longer on YouTube"
        case .ageRestricted: "Age-restricted"
        }
    }

    var groupExplanation: String {
        switch self {
        case .removed:
            "These were in the playlist but have since been deleted, made private, or blocked. They aren't counted in the totals."
        case .ageRestricted:
            "YouTube requires a signed-in, age-verified session for these. They aren't counted in the totals — sign in to YouTube in Safari or Chrome, then turn on browser cookies in Settings and re-run the download."
        }
    }
}

/// A playlist entry YouTube will not serve.
///
/// Old playlists accumulate these: the video is deleted, made private, blocked,
/// or age-gated, but the playlist still lists it. yt-dlp reports each one on
/// stderr and then exits non-zero, which would otherwise sink an
/// otherwise-fine run.
nonisolated struct UnavailableVideo: Sendable, Hashable {
    let videoID: String
    /// yt-dlp's own wording, trimmed of its trailing boilerplate.
    let reason: String
    let kind: UnavailableKind
}

/// Parses lines emitted by yt-dlp's `--progress-template` and `--print` flags.
///
/// The download invocation in `YTDLPService` uses pipe-delimited tags so we can
/// avoid the escaping minefield of JSON inside `--progress-template`:
///
/// - `DLSTART|<id>|<index>|<title>`         (from `--print before_dl:...`)
/// - `DLPROG|<id>|<downloaded>|<total>|<estimate>` (from `--progress-template`)
/// - `DLEND|<id>|<filepath>`                 (from `--print after_video:...`)
nonisolated enum ProgressParser {
    static func parse(line: String) -> YTDLPEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(
            separator: "|",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard let tag = parts.first else { return nil }

        switch tag {
        case "DLSTART" where parts.count >= 4:
            let id = parts[1]
            let index = Int(parts[2]) ?? 1
            let title = parts[3...].joined(separator: "|") // titles may contain |
            return .trackStarted(videoID: id, title: title, index: index)

        case "DLPROG" where parts.count >= 5:
            let id = parts[1]
            let downloaded = Double(parts[2]) ?? 0
            let totalKnown = Double(parts[3])
            let totalEst = Double(parts[4])
            let total = (totalKnown.flatMap { $0 > 0 ? $0 : nil })
                     ?? (totalEst.flatMap { $0 > 0 ? $0 : nil })
                     ?? 0
            let fraction = total > 0 ? min(downloaded / total, 1.0) : 0
            return .trackProgress(videoID: id, fraction: fraction)

        case "DLEND" where parts.count >= 3:
            let id = parts[1]
            let path = parts[2...].joined(separator: "|")
            return .trackFinished(videoID: id, filePath: path)

        default:
            return nil
        }
    }

    /// Phrases yt-dlp uses when YouTube itself refuses to serve a video.
    ///
    /// Deliberately narrow: anything not listed here (network drops, ffmpeg
    /// faults, throttling, bot checks) stays a real error and still fails
    /// the job. Matched case-insensitively against the message body.
    private static let removedPhrases = [
        "video unavailable",
        "this video is not available",
        "this video is no longer available",
        "video has been removed",
        "removed by the uploader",
        "private video",
        "who has blocked it in your country",
        "not available in your country",
        "account associated with this video has been terminated",
        "uploader has closed their youtube account",
        "violating youtube's terms of service",
        "this video has been removed for violating",
    ]

    /// Phrases for the age gate. Distinct from the list above because the
    /// video still exists — the run needs credentials, not a different video.
    ///
    /// Note the deliberate omission of "sign in to confirm you're not a bot",
    /// which is rate-limiting aimed at the whole run rather than one entry and
    /// must keep failing the job.
    private static let ageRestrictedPhrases = [
        "confirm your age",
        "age-restricted",
        "age restricted",
        "inappropriate for some users",
    ]

    /// Recognises a stderr line reporting a video YouTube will not serve.
    ///
    /// yt-dlp writes these as:
    /// `ERROR: [youtube] <id>: Video unavailable. This video is not available`
    /// `ERROR: [youtube] <id>: Sign in to confirm your age. This video may be…`
    ///
    /// Returns nil for any other error so genuine failures stay failures.
    static func unavailableVideo(from line: String) -> UnavailableVideo? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("ERROR:") else { return nil }

        // ERROR: [extractor] <videoID>: <message>
        guard let closingBracket = trimmed.firstIndex(of: "]") else { return nil }
        let afterBracket = trimmed[trimmed.index(after: closingBracket)...]
            .trimmingCharacters(in: .whitespaces)
        guard let colon = afterBracket.firstIndex(of: ":") else { return nil }

        let videoID = String(afterBracket[..<colon])
        guard isPlausibleVideoID(videoID) else { return nil }

        let message = afterBracket[afterBracket.index(after: colon)...]
            .trimmingCharacters(in: .whitespaces)
        let haystack = message.lowercased()

        // Age is checked first: YouTube's age-gate copy ("This video may be
        // inappropriate…") does not overlap the removal phrases, but checking
        // in this order keeps the classification stable if it ever does.
        let kind: UnavailableKind
        if ageRestrictedPhrases.contains(where: haystack.contains) {
            kind = .ageRestricted
        } else if removedPhrases.contains(where: haystack.contains) {
            kind = .removed
        } else {
            return nil
        }

        // "Video unavailable. This video is not available" → "Video unavailable"
        let reason = message
            .split(separator: ".", maxSplits: 1)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? message
        return UnavailableVideo(videoID: videoID, reason: reason, kind: kind)
    }

    /// True when a stderr line is an error we do NOT recognise as an
    /// unavailable video — i.e. something that should still fail the job.
    static func isHardError(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("ERROR:")
            && unavailableVideo(from: line) == nil
    }

    /// YouTube video ids are 11 characters of `[A-Za-z0-9_-]`.
    private static func isPlausibleVideoID(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy {
            ($0.isLetter || $0.isNumber) && $0.isASCII || $0 == "_" || $0 == "-"
        }
    }
}
