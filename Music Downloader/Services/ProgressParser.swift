import Foundation

/// Events emitted by the yt-dlp Process bridge.
nonisolated enum YTDLPEvent: Sendable {
    case trackStarted(videoID: String, title: String, index: Int)
    case trackProgress(videoID: String, fraction: Double)
    case trackFinished(videoID: String, filePath: String)
    case trackUnavailable(videoID: String, reason: String)
    case logLine(String)
    case failed(String)
    case finished
}

/// A playlist entry YouTube will not serve any more.
///
/// Old playlists accumulate these: the video is deleted, made private, or
/// blocked, but the playlist still lists it. yt-dlp reports each one on stderr
/// and then exits non-zero, which would otherwise sink an otherwise-fine run.
nonisolated struct UnavailableVideo: Sendable, Hashable {
    let videoID: String
    /// yt-dlp's own wording, trimmed of its trailing boilerplate.
    let reason: String
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
    /// faults, throttling, sign-in walls) stays a real error and still fails
    /// the job. Matched case-insensitively against the message body.
    private static let unavailablePhrases = [
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

    /// Recognises a stderr line reporting a video YouTube no longer serves.
    ///
    /// yt-dlp writes these as:
    /// `ERROR: [youtube] <id>: Video unavailable. This video is not available`
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
        guard unavailablePhrases.contains(where: haystack.contains) else { return nil }

        // "Video unavailable. This video is not available" → "Video unavailable"
        let reason = message
            .split(separator: ".", maxSplits: 1)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? message
        return UnavailableVideo(videoID: videoID, reason: reason)
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
