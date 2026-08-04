import Foundation

/// Moves accepted staged files into the master library and records them.
///
/// The library is flat — one folder, one file per song. Nesting would mean
/// BingoBite's index has to reconcile paths that carry no meaning, and the
/// filenames are already `{artist} - {title}` and therefore self-describing.
enum LibraryImporter {

    struct Result {
        var imported: [LibraryEntry] = []
        var replaced: [LibraryEntry] = []
        var skipped: Int = 0
        var failures: [(title: String, error: String)] = []

        var totalAdded: Int { imported.count + replaced.count }
    }

    /// Applies each candidate's `action`, moving files into `libraryRoot`.
    ///
    /// Files are **moved**, not copied — staging is scratch space, and a move
    /// within the same volume is atomic and instant. Falls back to copy+delete
    /// across volumes.
    @MainActor
    static func merge(
        candidates: [MergeCandidate],
        into libraryRoot: URL,
        ledger: LibraryLedger
    ) async -> Result {
        var result = Result()
        try? FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)

        for candidate in candidates {
            switch candidate.action {
            case .skip:
                result.skipped += 1
                continue

            case .include, .replace:
                guard let sourceURL = candidate.track.fileURL,
                      FileManager.default.fileExists(atPath: sourceURL.path) else {
                    result.failures.append((candidate.displayTitle, "File is missing from staging."))
                    continue
                }

                let isReplace = candidate.action == .replace
                let existingFile = candidate.verdict.existingFile

                do {
                    let destination: URL
                    if isReplace, let existingFile {
                        // Overwrite in place so the library keeps one file per
                        // song and the filename users already know stays put.
                        destination = libraryRoot.appendingPathComponent(existingFile)
                        if FileManager.default.fileExists(atPath: destination.path) {
                            try FileManager.default.removeItem(at: destination)
                        }
                    } else {
                        destination = uniqueDestination(
                            for: libraryRoot.appendingPathComponent(sourceURL.lastPathComponent)
                        )
                    }

                    try move(from: sourceURL, to: destination)
                    candidate.track.fileURL = destination

                    guard var entry = LibraryEntry.make(
                        from: candidate.track,
                        libraryFileName: destination.lastPathComponent
                    ) else {
                        result.failures.append((candidate.displayTitle, "Could not build a library record."))
                        continue
                    }
                    // A replaced file is new content at an existing path, so it
                    // needs re-exporting even if the old one had been sent.
                    entry.exportedAt = nil

                    await ledger.insert(entry)
                    if isReplace {
                        result.replaced.append(entry)
                    } else {
                        result.imported.append(entry)
                    }
                } catch {
                    result.failures.append((candidate.displayTitle, error.localizedDescription))
                }
            }
        }

        return result
    }

    // MARK: - File moves

    private static func move(from source: URL, to destination: URL) throws {
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            // Cross-volume moves fail; fall back to copy then remove.
            try FileManager.default.copyItem(at: source, to: destination)
            try? FileManager.default.removeItem(at: source)
        }
    }

    /// Appends " (2)", " (3)"… when the destination name is already taken.
    /// Mirrors `DownloadStore.uniqueDestination` but has no "current file"
    /// exemption, since the source always lives outside the library.
    static func uniqueDestination(for desired: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: desired.path) else { return desired }
        let base = desired.deletingPathExtension().lastPathComponent
        let ext = desired.pathExtension
        let dir = desired.deletingLastPathComponent()
        for n in 2...999 {
            let candidate = dir
                .appendingPathComponent("\(base) (\(n))")
                .appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return desired
    }

    /// Removes a staging folder once its contents have been merged or
    /// explicitly skipped. Best-effort: a failure here is not worth surfacing.
    static func cleanUpStaging(at folder: URL) {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        let remaining = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        // Only remove when empty — leftover files mean something went wrong and
        // the user should still be able to recover them by hand.
        if remaining.isEmpty {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
