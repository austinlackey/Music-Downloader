import Foundation

/// Events emitted by the yt-dlp Process bridge.
nonisolated enum YTDLPEvent: Sendable {
    case trackStarted(videoID: String, title: String, index: Int)
    case trackProgress(videoID: String, fraction: Double)
    case trackFinished(videoID: String, filePath: String)
    case logLine(String)
    case failed(String)
    case finished
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
}
