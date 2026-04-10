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

    var downloadRoot: URL {
        didSet {
            UserDefaults.standard.set(downloadRoot.path, forKey: Self.downloadRootKey)
            try? FileManager.default.createDirectory(
                at: downloadRoot,
                withIntermediateDirectories: true
            )
        }
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

        try? FileManager.default.createDirectory(
            at: self.downloadRoot,
            withIntermediateDirectories: true
        )
    }

    static let supportedFormats: [String] = ["mp3", "m4a", "flac", "wav", "opus"]
}
