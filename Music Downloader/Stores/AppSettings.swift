import Foundation
import Observation

/// User-tunable preferences. Persisted via `UserDefaults`.
@Observable
@MainActor
final class AppSettings {
    private static let downloadRootKey    = "downloadRoot"
    private static let audioFormatKey     = "audioFormat"
    private static let geniusTokenKey     = "geniusToken"
    private static let renameTemplateKey  = "renameTemplate"
    private static let stripSearchNoiseKey = "stripSearchNoise"
    private static let libraryRootKey     = "libraryRoot"
    private static let stagingRootKey     = "stagingRoot"
    private static let exportRootKey      = "exportRoot"
    private static let defaultDownloadModeKey = "defaultDownloadMode"
    private static let libraryFormatKey   = "libraryFormat"

    var downloadRoot: URL {
        didSet {
            UserDefaults.standard.set(downloadRoot.path, forKey: Self.downloadRootKey)
            try? FileManager.default.createDirectory(
                at: downloadRoot,
                withIntermediateDirectories: true
            )
        }
    }

    // MARK: - Library

    /// The master library — one copy of every song, deduped. Downloads in
    /// library mode land here after passing merge review.
    var libraryRoot: URL {
        didSet {
            UserDefaults.standard.set(libraryRoot.path, forKey: Self.libraryRootKey)
            try? FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        }
    }

    /// Where library-mode downloads land before merge review. Kept out of the
    /// library so a half-finished job never pollutes it.
    var stagingRoot: URL {
        didSet {
            UserDefaults.standard.set(stagingRoot.path, forKey: Self.stagingRootKey)
            try? FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        }
    }

    /// Where export folders destined for the iPad are written.
    var exportRoot: URL {
        didSet {
            UserDefaults.standard.set(exportRoot.path, forKey: Self.exportRootKey)
            try? FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        }
    }

    /// Which mode the New Download sheet opens on.
    var defaultDownloadMode: DownloadMode {
        didSet { UserDefaults.standard.set(defaultDownloadMode.rawValue, forKey: Self.defaultDownloadModeKey) }
    }

    /// Format for library-bound downloads, separate from `audioFormat` so a
    /// one-off job can use anything without making the library unreadable.
    /// BingoBite cannot read tags from — or play — opus, so the library needs
    /// a format that round-trips.
    var libraryFormat: String {
        didSet { UserDefaults.standard.set(libraryFormat, forKey: Self.libraryFormatKey) }
    }

    /// True when the chosen library format can't carry a `SONG_UID` into
    /// BingoBite. Surfaced as a warning in Settings.
    var libraryFormatIsUnreadable: Bool {
        !Self.bingoBiteReadableFormats.contains(libraryFormat)
    }

    var audioFormat: String {
        didSet { UserDefaults.standard.set(audioFormat, forKey: Self.audioFormatKey) }
    }

    // MARK: - Phase 2: Genius enrichment

    /// Client Access Token from https://genius.com/api-clients.
    /// Stored in UserDefaults (user-chosen trade-off for simplicity).
    var geniusToken: String {
        didSet { UserDefaults.standard.set(geniusToken, forKey: Self.geniusTokenKey) }
    }

    /// Filename template for renaming tracks after enrichment.
    /// See `FilenameTemplate` for placeholder docs.
    var renameTemplate: String {
        didSet { UserDefaults.standard.set(renameTemplate, forKey: Self.renameTemplateKey) }
    }

    /// Strip text in parentheses/brackets from track titles before Genius search.
    var stripSearchNoise: Bool {
        didSet { UserDefaults.standard.set(stripSearchNoise, forKey: Self.stripSearchNoiseKey) }
    }

    init() {
        let defaults = UserDefaults.standard
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fallback = docs.appendingPathComponent("Music Downloader", isDirectory: true)

        if let saved = defaults.string(forKey: Self.downloadRootKey), !saved.isEmpty {
            self.downloadRoot = URL(fileURLWithPath: saved)
        } else {
            self.downloadRoot = fallback
        }
        self.audioFormat    = defaults.string(forKey: Self.audioFormatKey)    ?? "mp3"
        self.geniusToken    = defaults.string(forKey: Self.geniusTokenKey)    ?? ""
        self.renameTemplate = defaults.string(forKey: Self.renameTemplateKey) ?? FilenameTemplate.defaultTemplate
        self.stripSearchNoise = defaults.object(forKey: Self.stripSearchNoiseKey) as? Bool ?? true

        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first ?? docs
        self.libraryRoot = Self.savedURL(defaults, Self.libraryRootKey)
            ?? music.appendingPathComponent("BingoBite Library", isDirectory: true)
        self.exportRoot = Self.savedURL(defaults, Self.exportRootKey)
            ?? music.appendingPathComponent("BingoBite Exports", isDirectory: true)

        // Staging defaults inside Application Support rather than a user-facing
        // folder — it's scratch space between download and merge, not something
        // to browse.
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.stagingRoot = Self.savedURL(defaults, Self.stagingRootKey)
            ?? appSupport
                .appendingPathComponent("Music Downloader", isDirectory: true)
                .appendingPathComponent("Staging", isDirectory: true)

        self.defaultDownloadMode = defaults.string(forKey: Self.defaultDownloadModeKey)
            .flatMap(DownloadMode.init(rawValue:)) ?? .library
        self.libraryFormat = defaults.string(forKey: Self.libraryFormatKey) ?? "mp3"

        for directory in [self.downloadRoot, self.libraryRoot, self.stagingRoot, self.exportRoot] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private static func savedURL(_ defaults: UserDefaults, _ key: String) -> URL? {
        guard let path = defaults.string(forKey: key), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    static let supportedFormats: [String] = ["mp3", "m4a", "flac", "wav", "opus"]

    /// Formats BingoBite's `AudioTagReader` can parse and `AVAudioPlayer` can
    /// play on iPad. Opus is excluded on both counts.
    static let bingoBiteReadableFormats: [String] = ["mp3", "m4a", "flac", "wav"]
}
