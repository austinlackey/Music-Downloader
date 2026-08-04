import Foundation

/// Builds an export folder to hand to the iPad.
///
/// Incremental by default: only songs never yet exported are copied, so a
/// weekly top-up moves a handful of files rather than the whole library. The
/// manifest still describes playlist definitions that may reference songs
/// delivered in an earlier export — BingoBite resolves those against its own
/// merged library, not against the folder it's importing.
enum ExportBuilder {

    enum Scope {
        /// Every song in the library. For first-time setup or a fresh iPad.
        case full
        /// Only songs with no `exportedAt` stamp.
        case newOnly

        var displayName: String {
            switch self {
            case .full:    "Everything"
            case .newOnly: "New since last export"
            }
        }
    }

    struct Result {
        var folderURL: URL
        var songsExported: Int
        var playlistsIncluded: Int
        var bytesCopied: Int64
        var failures: [(file: String, error: String)] = []

        var isEmpty: Bool { songsExported == 0 }
    }

    enum ExportError: LocalizedError {
        case nothingToExport

        var errorDescription: String? {
            switch self {
            case .nothingToExport:
                "Every song in your library has already been exported. Choose “Everything” to export them all again."
            }
        }
    }

    /// Writes an export folder and stamps the exported songs in the ledger.
    ///
    /// The ledger is only stamped **after** every file has been copied, so a
    /// failed or interrupted export doesn't cause songs to be skipped next time.
    static func build(
        scope: Scope,
        libraryRoot: URL,
        exportRoot: URL,
        ledger: LibraryLedger,
        playlists: [LibraryManifest.PlaylistDefinition],
        date: Date = .now
    ) async throws -> Result {
        let candidates: [LibraryEntry]
        switch scope {
        case .full:    candidates = await ledger.allEntries()
        case .newOnly: candidates = await ledger.unexportedEntries()
        }

        guard !candidates.isEmpty else { throw ExportError.nothingToExport }

        let folderURL = uniqueExportFolder(in: exportRoot, date: date)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        var result = Result(folderURL: folderURL, songsExported: 0, playlistsIncluded: 0, bytesCopied: 0)
        var exportedUIDs: [String] = []
        var exportedEntries: [LibraryEntry] = []

        for entry in candidates {
            let source = libraryRoot.appendingPathComponent(entry.file)
            guard FileManager.default.fileExists(atPath: source.path) else {
                // In the ledger but gone from disk — report it rather than
                // silently shipping a manifest that promises a missing file.
                result.failures.append((entry.file, "Missing from the library folder."))
                continue
            }
            let destination = folderURL.appendingPathComponent(entry.file)
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: source, to: destination)
                result.songsExported += 1
                result.bytesCopied += entry.fileSize ?? 0
                exportedUIDs.append(entry.uid)
                exportedEntries.append(entry)
            } catch {
                result.failures.append((entry.file, error.localizedDescription))
            }
        }

        // Only ship playlist definitions that can actually be satisfied — every
        // song either in this export or already delivered by an earlier one.
        let deliverable = Set(await ledger.allEntries().filter {
            $0.exportedAt != nil || exportedUIDs.contains($0.uid)
        }.map(\.uid))
        let usablePlaylists = playlists.filter { playlist in
            !playlist.songUIDs.isEmpty && playlist.songUIDs.allSatisfy { deliverable.contains($0) }
        }
        result.playlistsIncluded = usablePlaylists.count

        try ManifestWriter.write(
            songs: exportedEntries,
            playlists: usablePlaylists,
            libraryName: libraryRoot.lastPathComponent,
            to: folderURL,
            generatedAt: date
        )

        await ledger.markExported(uids: exportedUIDs, at: date)
        return result
    }

    /// `BingoBite Export 2026-07-31`, suffixed if that name is taken so two
    /// exports on the same day don't collide.
    private static func uniqueExportFolder(in root: URL, date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let base = "BingoBite Export \(formatter.string(from: date))"

        let first = root.appendingPathComponent(base, isDirectory: true)
        guard FileManager.default.fileExists(atPath: first.path) else { return first }
        for n in 2...99 {
            let candidate = root.appendingPathComponent("\(base) (\(n))", isDirectory: true)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return first
    }

    // MARK: - Playlist definitions from jobs

    /// Turns merged library-mode jobs into playlist definitions.
    ///
    /// A job is a playlist the user actually downloaded, so recreating it in
    /// BingoBite is exactly what they want. Only tracks that survived merge
    /// review — and are therefore in the library — are included.
    @MainActor
    static func playlistDefinitions(
        from jobs: [DownloadJob],
        libraryUIDs: Set<String>
    ) -> [LibraryManifest.PlaylistDefinition] {
        var definitions: [LibraryManifest.PlaylistDefinition] = []
        for job in jobs {
            guard job.mode == .library, job.status == .merged else { continue }
            var uids: [String] = []
            for track in job.tracks where libraryUIDs.contains(track.songUID) {
                uids.append(track.songUID)
            }
            guard !uids.isEmpty else { continue }
            definitions.append(
                LibraryManifest.PlaylistDefinition(
                    uuid: job.id.uuidString,
                    name: job.playlistTitle,
                    description: nil,
                    songUIDs: uids
                )
            )
        }
        return definitions
    }
}
