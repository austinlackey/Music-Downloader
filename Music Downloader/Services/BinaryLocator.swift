import Foundation

/// Resolves bundled `yt-dlp` and `ffmpeg` binaries shipped inside the app's
/// `Contents/Resources/bin` directory.
nonisolated enum BinaryLocator {
    static let ytDlp: URL = locate("yt-dlp")
    static let ffmpeg: URL = locate("ffmpeg")

    /// Directory containing the bundled binaries (used for `--ffmpeg-location`).
    static var binDirectory: URL {
        ytDlp.deletingLastPathComponent()
    }

    private static func locate(_ name: String) -> URL {
        guard let url = Bundle.main.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "bin"
        ) else {
            fatalError("Bundled binary missing: \(name). Did the 'Copy & Sign Vendored Binaries' build phase run?")
        }
        return url
    }
}
