import Foundation

/// Writes `bingobite-library.json` into a library or export folder.
nonisolated enum ManifestWriter {
    static let fileName = "bingobite-library.json"

    /// Atomically writes a manifest describing `songs` into `folder`.
    ///
    /// - Parameters:
    ///   - songs: entries whose files are present in this folder
    ///   - playlists: playlist definitions, which may reference UIDs from
    ///     earlier exports — BingoBite resolves them against its merged library
    static func write(
        songs: [LibraryEntry],
        playlists: [LibraryManifest.PlaylistDefinition] = [],
        libraryName: String?,
        to folder: URL,
        generatedAt: Date = .now
    ) throws {
        let manifest = LibraryManifest(
            generatedAt: generatedAt,
            generator: Self.generatorString,
            libraryName: libraryName,
            // Strip export bookkeeping — it's ledger state, not something
            // BingoBite should see or act on.
            songs: songs.map { entry in
                var copy = entry
                copy.exportedAt = nil
                return copy
            },
            playlists: playlists
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONEncoder.bingoBite.encode(manifest)
        try data.write(to: folder.appendingPathComponent(fileName), options: .atomic)
    }

    /// Reads a manifest back, for verification and for re-exporting an existing
    /// folder. Returns nil when absent or from a newer format version.
    static func read(from folder: URL) -> LibraryManifest? {
        let url = folder.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder.bingoBite.decode(LibraryManifest.self, from: data),
              manifest.isReadable
        else { return nil }
        return manifest
    }

    private static var generatorString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "Music Downloader \(version)"
    }
}
