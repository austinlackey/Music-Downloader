import Foundation

/// The durable record of what's in the master library.
///
/// Lives inside the library folder at `.bingobite/library-ledger.json`, so it
/// travels with the library rather than living in Application Support. That
/// matters: point the app at a library folder restored from a backup and the
/// dedupe history comes back with it.
///
/// Deliberately **not** derived from `jobs.json` — `DownloadStore.remove(_:)`
/// prunes jobs, and deriving from them would silently un-dedupe every track of
/// a removed job.
actor LibraryLedger {
    private let libraryRoot: URL
    private var entries: [String: LibraryEntry] = [:]   // keyed by uid
    private var loaded = false

    init(libraryRoot: URL) {
        self.libraryRoot = libraryRoot
    }

    private var ledgerURL: URL {
        libraryRoot
            .appendingPathComponent(".bingobite", isDirectory: true)
            .appendingPathComponent("library-ledger.json")
    }

    private var archiveURL: URL {
        libraryRoot
            .appendingPathComponent(".bingobite", isDirectory: true)
            .appendingPathComponent("archive.txt")
    }

    // MARK: - Loading

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: ledgerURL),
              let decoded = try? JSONDecoder.bingoBite.decode([LibraryEntry].self, from: data)
        else { return }
        entries = Dictionary(decoded.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Forces a re-read on next access. Used after the library root changes.
    func invalidate() {
        loaded = false
        entries = [:]
    }

    // MARK: - Reading

    func allEntries() -> [LibraryEntry] {
        loadIfNeeded()
        return entries.values.sorted {
            $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending
        }
    }

    func snapshot() -> DedupeEngine.LibrarySnapshot {
        DedupeEngine.LibrarySnapshot(entries: allEntries())
    }

    func contains(uid: String) -> Bool {
        loadIfNeeded()
        return entries[uid] != nil
    }

    func entry(uid: String) -> LibraryEntry? {
        loadIfNeeded()
        return entries[uid]
    }

    /// Every source video id currently in the library — dedupe layer 1.
    func videoIDs() -> Set<String> {
        loadIfNeeded()
        return Set(entries.values.compactMap(\.sourceVideoID))
    }

    /// Entries never yet written to an export folder.
    func unexportedEntries() -> [LibraryEntry] {
        allEntries().filter { $0.exportedAt == nil }
    }

    // MARK: - Writing

    func insert(_ entry: LibraryEntry) {
        loadIfNeeded()
        entries[entry.uid] = entry
        persist()
    }

    func insert(_ newEntries: [LibraryEntry]) {
        guard !newEntries.isEmpty else { return }
        loadIfNeeded()
        for entry in newEntries { entries[entry.uid] = entry }
        persist()
    }

    func remove(uid: String) {
        loadIfNeeded()
        entries[uid] = nil
        persist()
    }

    /// Stamps the given uids as exported. Called after an export folder is
    /// successfully written, so a failed export doesn't skip songs next time.
    func markExported(uids: [String], at date: Date = .now) {
        guard !uids.isEmpty else { return }
        loadIfNeeded()
        for uid in uids {
            entries[uid]?.exportedAt = date
        }
        persist()
    }

    /// Clears every export stamp, so the next incremental export behaves like a
    /// full one. Used when setting up a replacement iPad.
    func resetExportState() {
        loadIfNeeded()
        for uid in entries.keys {
            entries[uid]?.exportedAt = nil
        }
        persist()
    }

    private func persist() {
        let directory = ledgerURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder.bingoBite.encode(allEntries()) else { return }
        try? data.write(to: ledgerURL, options: .atomic)
    }

    // MARK: - yt-dlp archive

    /// Writes the `--download-archive` file yt-dlp consults to skip videos it
    /// has already fetched, and returns its URL.
    ///
    /// Regenerated from the ledger before every run rather than being appended
    /// to by yt-dlp, so a video the user *rejected* in merge review doesn't
    /// stay permanently skipped.
    func writeArchiveFile() -> URL? {
        loadIfNeeded()
        let ids = videoIDs()
        guard !ids.isEmpty else {
            // No archive is better than an empty one — yt-dlp would still
            // create and append to it, quietly re-introducing the stale-skip
            // problem above.
            try? FileManager.default.removeItem(at: archiveURL)
            return nil
        }
        // yt-dlp's archive format is "<extractor> <id>" per line.
        let body = ids.sorted().map { "youtube \($0)" }.joined(separator: "\n") + "\n"
        let directory = archiveURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try body.write(to: archiveURL, atomically: true, encoding: .utf8)
            return archiveURL
        } catch {
            return nil
        }
    }
}

// MARK: - Shared coder configuration

extension JSONEncoder {
    /// ISO-8601 dates and stable key order, so the ledger and manifest diff
    /// cleanly and are readable when something goes wrong.
    static var bingoBite: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension JSONDecoder {
    static var bingoBite: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
