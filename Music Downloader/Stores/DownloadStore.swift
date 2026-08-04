import AppKit
import Foundation
import Observation

/// Owns the list of `DownloadJob`s and orchestrates downloads via `YTDLPService`
/// and metadata enrichment via `GeniusService` + `MetadataWriter`.
@Observable
@MainActor
final class DownloadStore {
    var jobs: [DownloadJob] = []
    var libraryRevision = 0

    private let service = YTDLPService()
    private let genius = GeniusService()
    private let writer = MetadataWriter()
    private let persistenceURL: URL

    /// One ledger per library root, rebuilt when the user repoints the library
    /// in Settings.
    private var ledgerCache: (root: URL, ledger: LibraryLedger)?

    private func ledger(for root: URL) -> LibraryLedger {
        if let cached = ledgerCache, cached.root == root { return cached.ledger }
        let ledger = LibraryLedger(libraryRoot: root)
        ledgerCache = (root, ledger)
        return ledger
    }

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("Music Downloader", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.persistenceURL = dir.appendingPathComponent("jobs.json")
        load()
    }

    // MARK: - Public actions: Download

    /// Adds a new job and starts the metadata→download pipeline asynchronously.
    ///
    /// In `.library` mode files land in staging and the job ends at `.staged`,
    /// waiting for merge review — nothing reaches the library unreviewed.
    func startDownload(url: String, mode: DownloadMode, settings: AppSettings) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let job = DownloadJob(
            url: trimmed,
            playlistTitle: "Loading…",
            folderURL: mode == .library ? settings.libraryRoot : settings.downloadRoot,
            mode: mode
        )
        jobs.insert(job, at: 0)

        // The library keeps its own format so a one-off job in an exotic format
        // can't make the library unreadable to BingoBite.
        let format = mode == .library ? settings.libraryFormat : settings.audioFormat
        Task {
            await self.execute(
                job: job,
                format: format,
                root: settings.downloadRoot,
                libraryRoot: settings.libraryRoot,
                stagingRoot: settings.stagingRoot
            )
        }
    }

    func cancel(_ job: DownloadJob) {
        Task {
            await service.cancel(jobID: job.id)
            job.status = .cancelled
            persist()
        }
    }

    func remove(_ job: DownloadJob) {
        if job.isActive { cancel(job) }
        jobs.removeAll { $0.id == job.id }
        persist()
    }

    func revealInFinder(_ job: DownloadJob) {
        if job.isLibraryMerged,
           let libraryFile = job.tracks.compactMap(\.fileURL).first {
            NSWorkspace.shared.activateFileViewerSelecting([libraryFile.deletingLastPathComponent()])
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([job.folderURL])
    }

    func revealTrackInFinder(_ track: Track) {
        guard let url = track.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Backfills skipped playlist rows from the library ledger. This repairs
    /// older staged jobs that only remembered the YouTube title for songs that
    /// were already in the central library.
    func hydrateLibraryReferences(job: DownloadJob, settings: AppSettings) async {
        guard job.mode == .library, !job.skippedVideoIDs.isEmpty else { return }

        let entries = await ledger(for: settings.libraryRoot).allEntries()
        let byVideoID = Dictionary(
            entries.compactMap { entry in
                entry.sourceVideoID.map { ($0, entry) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let skipped = Set(job.skippedVideoIDs)
        var changed = false

        for track in job.tracks where skipped.contains(track.id) {
            guard let entry = byVideoID[track.id] else { continue }

            let fileURL = settings.libraryRoot.appendingPathComponent(entry.file)
            if track.songUID != entry.uid {
                track.songUID = entry.uid
                changed = true
            }
            if track.fileURL != fileURL {
                track.fileURL = fileURL
                changed = true
            }
            if track.metadata == nil || track.metadata?.title != entry.name || track.metadata?.artist != entry.artist {
                track.metadata = Self.metadata(from: entry, fallbackTitle: track.title)
                changed = true
            }
            if track.sourceDuration == nil, let duration = entry.durationSeconds {
                track.sourceDuration = duration
                changed = true
            }
            if track.enrichmentStatus != .enriched {
                track.enrichmentStatus = .enriched
                changed = true
            }
        }

        if changed { persist() }
    }

    // MARK: - Public actions: Enrichment

    /// Bulk-enrich completed, file-backed tracks in a job. Throttled to 5
    /// in-flight requests. Normal runs pick up only tracks that are not already
    /// enriched; force runs re-query Genius and rewrite tags for every file.
    func enrich(job: DownloadJob, settings: AppSettings, force: Bool = false) {
        guard !settings.geniusToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            job.errorMessage = GeniusError.missingToken.localizedDescription
            return
        }
        let token = settings.geniusToken
        let template = settings.renameTemplate
        let stripNoise = settings.stripSearchNoise

        Task { [weak self] in
            guard let self else { return }
            let pending = job.tracks.filter {
                guard $0.fileURL != nil, $0.status == .completed, !$0.isFileMissing else { return false }
                if force { return true }
                return $0.enrichmentStatus != .enriched && $0.enrichmentStatus != .skipped
            }
            let semaphore = AsyncSemaphore(permits: 5)
            await withTaskGroup(of: Void.self) { group in
                for track in pending {
                    group.addTask { [weak self] in
                        await semaphore.wait()
                        defer { Task { await semaphore.signal() } }
                        try? await Task.sleep(for: .milliseconds(150))
                        await self?.enrichOne(
                            track: track,
                            in: job,
                            token: token,
                            template: template,
                            stripNoise: stripNoise,
                            libraryRoot: settings.libraryRoot
                        )
                    }
                }
            }
            self.persist()
        }
    }

    /// Re-apply enrichment to a single track using a specific Genius hit.
    /// Used by the inspector's "Apply alternative" button.
    func applyMatch(
        _ hit: GeniusHitResult,
        to track: Track,
        in job: DownloadJob,
        settings: AppSettings
    ) {
        let token = settings.geniusToken
        let template = settings.renameTemplate
        Task { [weak self] in
            await self?.applyHit(
                hit,
                to: track,
                in: job,
                token: token,
                template: template,
                libraryRoot: settings.libraryRoot
            )
            self?.persist()
        }
    }

    /// Save user-edited metadata directly (no Genius fetch). Writes ID3 tags,
    /// updates the track model, and optionally renames the file.
    func saveManualMetadata(
        track: Track,
        in job: DownloadJob,
        metadata: SongMetadata,
        coverArtData: Data?,
        settings: AppSettings
    ) {
        let template = settings.renameTemplate
        Task { [weak self] in
            guard let self, let currentURL = track.fileURL else { return }

            // Capture original filename on first edit for revert support.
            if track.originalFilename == nil {
                track.originalFilename = currentURL.deletingPathExtension().lastPathComponent
            }

            track.enrichmentStatus = .writing

            do {
                try await writer.write(
                    metadata: metadata,
                    coverArtData: coverArtData,
                    songUID: track.songUID,
                    sourceVideoID: SongUID.parse(track.songUID)?.videoID,
                    to: currentURL
                )
                track.metadata = metadata

                // Rename according to template if title or artist are set.
                if !metadata.title.isEmpty, !metadata.artist.isEmpty {
                    let index = (job.tracks.firstIndex(where: { $0.id == track.id }) ?? 0) + 1
                    let renderedBase = FilenameTemplate.render(
                        template: template,
                        metadata: metadata,
                        trackNumber: index,
                        originalName: track.originalFilename ?? currentURL.deletingPathExtension().lastPathComponent
                    )
                    let ext = currentURL.pathExtension
                    var newURL = currentURL.deletingLastPathComponent()
                        .appendingPathComponent(renderedBase)
                        .appendingPathExtension(ext)

                    if newURL != currentURL {
                        newURL = Self.uniqueDestination(for: newURL, current: currentURL)
                        try FileManager.default.moveItem(at: currentURL, to: newURL)
                        track.fileURL = newURL
                    }
                }

                track.enrichmentStatus = .enriched
                await syncLibraryRecordIfNeeded(for: track, in: job, libraryRoot: settings.libraryRoot)
            } catch {
                track.enrichmentStatus = .failed(error.localizedDescription)
            }

            self.persist()
        }
    }

    /// Revert all tracks in a job to their original yt-dlp filenames and clear
    /// all Genius metadata so the job can be re-enriched from scratch.
    func clearAllMetadata(job: DownloadJob, settings: AppSettings) {
        Task { [weak self] in
            guard let self else { return }
            for track in job.tracks where track.fileURL != nil {
                // Revert filename if it was renamed.
                if let current = track.fileURL,
                   let original = track.originalFilename,
                   current.deletingPathExtension().lastPathComponent != original {
                    let ext = current.pathExtension
                    let dest = current.deletingLastPathComponent()
                        .appendingPathComponent(original)
                        .appendingPathExtension(ext)
                    do {
                        let safeDest = Self.uniqueDestination(for: dest, current: current)
                        try FileManager.default.moveItem(at: current, to: safeDest)
                        track.fileURL = safeDest
                    } catch {
                        // Non-fatal — continue clearing metadata for the rest.
                    }
                }
                track.metadata = nil
                track.enrichmentStatus = .notStarted
                track.alternativeMatches = []
                await syncLibraryRecordIfNeeded(for: track, in: job, libraryRoot: settings.libraryRoot)
            }
            self.persist()
        }
    }

    /// Rename a track back to its original yt-dlp filename. Tags stay written;
    /// this only undoes the rename.
    func revertFilename(_ track: Track, in job: DownloadJob, settings: AppSettings) {
        guard let current = track.fileURL,
              let original = track.originalFilename else { return }
        let ext = current.pathExtension
        let newURL = current.deletingLastPathComponent()
            .appendingPathComponent(original)
            .appendingPathExtension(ext)
        do {
            if FileManager.default.fileExists(atPath: newURL.path), newURL != current {
                try FileManager.default.removeItem(at: newURL)
            }
            try FileManager.default.moveItem(at: current, to: newURL)
            track.fileURL = newURL
            Task {
                await syncLibraryRecordIfNeeded(for: track, in: job, libraryRoot: settings.libraryRoot)
                persist()
            }
        } catch {
            track.enrichmentStatus = .failed("Revert failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Download pipeline

    private func execute(
        job: DownloadJob,
        format: String,
        root: URL,
        libraryRoot: URL,
        stagingRoot: URL
    ) async {
        job.status = .fetchingMetadata
        do {
            let metadata = try await service.fetchMetadata(url: job.url)
            let playlistTitle = metadata.title
                ?? metadata.entries?.first?.title
                ?? "Untitled"
            job.playlistTitle = playlistTitle

            // Build the entry list. For single videos, synthesize one entry.
            let entries: [PlaylistMetadata.Entry] = metadata.entries
                ?? [PlaylistMetadata.Entry(
                        id: metadata.id ?? "single",
                        title: metadata.title,
                        duration: nil
                   )]

            // Pick the destination and, in library mode, work out what yt-dlp
            // is going to skip so the UI can say so rather than silently
            // showing fewer tracks than the playlist has.
            let folder: URL
            var archiveURL: URL?
            var knownVideoIDs = Set<String>()
            var knownEntriesByVideoID: [String: LibraryEntry] = [:]
            if job.mode == .library {
                let staging = stagingRoot.appendingPathComponent(job.id.uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                job.stagingURL = staging
                job.folderURL = staging
                folder = staging

                let ledger = ledger(for: libraryRoot)
                archiveURL = await ledger.writeArchiveFile()
                let knownEntries = await ledger.allEntries()
                knownEntriesByVideoID = Dictionary(
                    knownEntries.compactMap { entry in
                        entry.sourceVideoID.map { ($0, entry) }
                    },
                    uniquingKeysWith: { first, _ in first }
                )
                knownVideoIDs = Set(knownEntriesByVideoID.keys)
                job.skippedVideoIDs = entries.map(\.id).filter { knownVideoIDs.contains($0) }
            } else {
                folder = root.appendingPathComponent(Self.sanitize(playlistTitle), isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                job.folderURL = folder
            }

            let skipped = Set(job.skippedVideoIDs)
            job.tracks = entries.map { entry in
                let libraryEntry = knownEntriesByVideoID[entry.id]
                let track = Track(
                    id: entry.id,
                    title: entry.title ?? libraryEntry?.name ?? entry.id,
                    songUID: libraryEntry?.uid
                )
                // Captured pre-download; dedupe uses it to tell two uploads of
                // the same song from two different songs.
                track.sourceDuration = entry.duration ?? libraryEntry?.durationSeconds
                if job.mode == .library, skipped.contains(entry.id) {
                    // Keep already-library tracks in the job so this download
                    // still represents the full playlist when exported to
                    // BingoBite. They point at the library file for playback
                    // and re-enrichment, while merge review ignores them
                    // because they are outside this job's staging folder.
                    track.status = .completed
                    track.progress = 1
                    if let libraryEntry {
                        track.fileURL = libraryRoot.appendingPathComponent(libraryEntry.file)
                        track.metadata = Self.metadata(from: libraryEntry, fallbackTitle: track.title)
                        track.enrichmentStatus = .enriched
                    } else {
                        track.enrichmentStatus = .skipped
                    }
                }
                return track
            }

            // Everything was already in the library — nothing to fetch.
            if job.mode == .library && job.tracks.allSatisfy({ skipped.contains($0.id) }) {
                job.status = job.mode == .library ? .merged : .completed
                job.folderURL = libraryRoot
                if let staging = job.stagingURL {
                    LibraryImporter.cleanUpStaging(at: staging)
                }
                job.stagingURL = nil
                persist()
                return
            }

            job.status = .downloading
            for await event in await service.download(
                url: job.url,
                outputDir: folder,
                format: format,
                jobID: job.id,
                archiveURL: archiveURL
            ) {
                apply(event, to: job)
            }

            if job.status == .downloading {
                let allCompleted = job.tracks.allSatisfy { $0.status == .completed }
                let anyCompleted = job.tracks.contains { $0.status == .completed }
                if job.mode == .library {
                    // A partial download is still worth reviewing — the tracks
                    // that did land are usable.
                    job.status = anyCompleted ? .staged : .failed
                } else {
                    job.status = allCompleted ? .completed : .failed
                }
            }
        } catch {
            job.status = .failed
            job.errorMessage = error.localizedDescription
        }
        persist()
    }

    // MARK: - Merge pipeline

    /// Classifies every downloaded track in a staged job against the library.
    /// Builds the ladder snapshot once, then runs each track through it.
    func prepareMerge(job: DownloadJob, settings: AppSettings) async -> [MergeCandidate] {
        let snapshot = await ledger(for: settings.libraryRoot).snapshot()
        return job.mergeableTracks.map { track in
            let candidate = DedupeEngine.Candidate(
                videoID: SongUID.parse(track.songUID)?.videoID,
                geniusID: track.metadata?.geniusID,
                artist: track.metadata?.artist ?? "",
                title: track.metadata?.title ?? track.title,
                duration: track.sourceDuration
            )
            return MergeCandidate(
                track: track,
                verdict: DedupeEngine.classify(candidate, against: snapshot)
            )
        }
    }

    /// Applies the user's per-track decisions, moving accepted files into the
    /// library and refreshing the manifest.
    @discardableResult
    func commitMerge(
        _ candidates: [MergeCandidate],
        job: DownloadJob,
        settings: AppSettings
    ) async -> LibraryImporter.Result {
        job.status = .merging
        let ledger = ledger(for: settings.libraryRoot)

        let result = await LibraryImporter.merge(
            candidates: candidates,
            into: settings.libraryRoot,
            ledger: ledger
        )

        // Rewrite the manifest from the ledger so it always describes the whole
        // library, not just this merge.
        let entries = await ledger.allEntries()
        try? ManifestWriter.write(
            songs: entries,
            libraryName: settings.libraryRoot.lastPathComponent,
            to: settings.libraryRoot
        )

        if let staging = job.stagingURL {
            LibraryImporter.cleanUpStaging(at: staging)
        }

        job.folderURL = settings.libraryRoot
        job.stagingURL = nil
        job.status = .merged
        if !result.failures.isEmpty {
            job.errorMessage = "\(result.failures.count) track(s) could not be merged."
        }
        persist()
        return result
    }

    /// Every song currently in the library, for the Library view.
    func libraryEntries(settings: AppSettings) async -> [LibraryEntry] {
        await repairMissingLibraryLinks(settings: settings)
        return await ledger(for: settings.libraryRoot).allEntries()
    }

    /// Playlists, derived from merged library-mode jobs, that reference a
    /// library song UID.
    func playlistsContaining(uid: String) -> [LibraryPlaylistMembership] {
        jobs.compactMap { job in
            guard job.mode == .library, job.status == .merged else { return nil }
            guard let index = job.tracks.firstIndex(where: { $0.songUID == uid }) else { return nil }
            return LibraryPlaylistMembership(
                playlistID: job.id,
                name: job.playlistTitle,
                position: index + 1,
                totalCount: job.tracks.count
            )
        }
        .sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Repairs stale ledger file paths using the job list as a secondary index.
    ///
    /// This covers the case where a library song was renamed from a job before
    /// the ledger-sync fix existed: the audio file is fine, the job track points
    /// at it, but the library ledger still points at the old filename.
    @discardableResult
    func repairMissingLibraryLinks(settings: AppSettings) async -> Int {
        let root = settings.libraryRoot
        let ledger = ledger(for: root)
        let entries = await ledger.allEntries()
        var repaired = 0

        let tracksByUID = Dictionary(
            jobs
                .filter { $0.mode == .library }
                .flatMap(\.tracks)
                .compactMap { track -> (String, Track)? in
                    guard let fileURL = track.fileURL,
                          FileManager.default.fileExists(atPath: fileURL.path),
                          isInside(fileURL, root: root)
                    else { return nil }
                    return (track.songUID, track)
                },
            uniquingKeysWith: { first, _ in first }
        )

        for entry in entries {
            let currentURL = root.appendingPathComponent(entry.file)
            guard let track = tracksByUID[entry.uid] else { continue }

            let storedCoverArtURL = entry.coverArtURL
            let trackCoverArtURL = track.metadata?.coverArtURL?.absoluteString
            let pathIsMissing = !FileManager.default.fileExists(atPath: currentURL.path)
            let coverArtIsMissing = storedCoverArtURL == nil && trackCoverArtURL != nil

            if pathIsMissing || coverArtIsMissing {
                await syncLibraryRecordIfNeeded(for: track, libraryRoot: root, preserveExportStamp: false)
                repaired += 1
            }
        }

        if repaired > 0 {
            persist()
        }
        return repaired
    }

    /// How many library songs have never been written to an export folder.
    func unexportedCount(settings: AppSettings) async -> Int {
        await ledger(for: settings.libraryRoot).unexportedEntries().count
    }

    // MARK: - Export

    /// Builds an export folder for the iPad, including playlist definitions
    /// derived from merged library jobs.
    func exportForIPad(
        scope: ExportBuilder.Scope,
        settings: AppSettings
    ) async throws -> ExportBuilder.Result {
        let ledger = ledger(for: settings.libraryRoot)
        let libraryUIDs = Set(await ledger.allEntries().map(\.uid))
        let playlists = ExportBuilder.playlistDefinitions(from: jobs, libraryUIDs: libraryUIDs)

        return try await ExportBuilder.build(
            scope: scope,
            libraryRoot: settings.libraryRoot,
            exportRoot: settings.exportRoot,
            ledger: ledger,
            playlists: playlists
        )
    }

    /// Clears every export stamp so the next incremental export sends
    /// everything again. For setting up a replacement iPad.
    func resetExportState(settings: AppSettings) async {
        await ledger(for: settings.libraryRoot).resetExportState()
    }

    /// Drops the cached ledger so the next read picks up a repointed library.
    func libraryRootChanged() {
        ledgerCache = nil
    }

    private func apply(_ event: YTDLPEvent, to job: DownloadJob) {
        switch event {
        case .trackStarted(let id, let title, _):
            if let track = job.tracks.first(where: { $0.id == id }) {
                track.status = .downloading
                if track.title.isEmpty || track.title == id {
                    track.title = title
                }
            } else if let single = job.tracks.first, job.tracks.count == 1 {
                single.status = .downloading
                if single.title.isEmpty { single.title = title }
            }

        case .trackProgress(let id, let fraction):
            if let track = job.tracks.first(where: { $0.id == id }) {
                track.progress = fraction
            } else if job.tracks.count == 1 {
                job.tracks[0].progress = fraction
            }

        case .trackFinished(let id, let path):
            let target = job.tracks.first(where: { $0.id == id })
                ?? (job.tracks.count == 1 ? job.tracks.first : nil)
            if let target {
                target.status = .completed
                target.progress = 1
                target.fileURL = URL(fileURLWithPath: path)
                // Remember original yt-dlp filename so "Revert" works post-rename.
                if target.originalFilename == nil {
                    target.originalFilename = URL(fileURLWithPath: path)
                        .deletingPathExtension()
                        .lastPathComponent
                }
            }

        case .failed(let msg):
            job.status = .failed
            job.errorMessage = msg

        case .finished, .logLine:
            break
        }
    }

    // MARK: - Enrichment pipeline

    private func enrichOne(
        track: Track,
        in job: DownloadJob,
        token: String,
        template: String,
        stripNoise: Bool = true,
        libraryRoot: URL? = nil
    ) async {
        guard track.fileURL != nil else { return }
        track.enrichmentStatus = .searching

        do {
            let hits = try await genius.search(query: track.title, token: token, stripNoise: stripNoise)
            guard let top = hits.first else { throw GeniusError.noMatch }
            track.alternativeMatches = Array(hits.prefix(5))
            await applyHit(
                top,
                to: track,
                in: job,
                token: token,
                template: template,
                libraryRoot: libraryRoot
            )
        } catch {
            track.enrichmentStatus = .failed(error.localizedDescription)
        }
    }

    private func applyHit(
        _ hit: GeniusHitResult,
        to track: Track,
        in job: DownloadJob,
        token: String,
        template: String,
        libraryRoot: URL? = nil
    ) async {
        guard track.fileURL != nil else { return }
        // Capture original filename on first enrichment for revert.
        if track.originalFilename == nil {
            track.originalFilename = track.fileURL!.deletingPathExtension().lastPathComponent
        }

        track.enrichmentStatus = .matched

        do {
            let metadata = try await genius.metadataFor(hit: hit, token: token)

            // Download cover art if available (non-fatal on failure).
            var coverData: Data? = nil
            if let coverURL = metadata.coverArtURL {
                coverData = try? await genius.fetchCoverArt(url: coverURL)
            }

            // Re-read fileURL after awaits — another task may have renamed
            // the file while we were fetching metadata / cover art.
            guard let currentURL = track.fileURL else { return }

            track.enrichmentStatus = .writing
            try await writer.write(
                metadata: metadata,
                coverArtData: coverData,
                songUID: track.songUID,
                sourceVideoID: SongUID.parse(track.songUID)?.videoID,
                to: currentURL
            )
            track.metadata = metadata

            // Rename according to template.
            let index = (job.tracks.firstIndex(where: { $0.id == track.id }) ?? 0) + 1
            let renderedBase = FilenameTemplate.render(
                template: template,
                metadata: metadata,
                trackNumber: index,
                originalName: track.originalFilename ?? currentURL.deletingPathExtension().lastPathComponent
            )
            let ext = currentURL.pathExtension
            var newURL = currentURL.deletingLastPathComponent()
                .appendingPathComponent(renderedBase)
                .appendingPathExtension(ext)

            if newURL != currentURL {
                // Avoid clobbering a sibling with the same name.
                newURL = Self.uniqueDestination(for: newURL, current: currentURL)
                try FileManager.default.moveItem(at: currentURL, to: newURL)
                track.fileURL = newURL
            }

            track.enrichmentStatus = .enriched
            if let libraryRoot {
                await syncLibraryRecordIfNeeded(for: track, in: job, libraryRoot: libraryRoot)
            }
        } catch {
            track.enrichmentStatus = .failed(error.localizedDescription)
        }
    }

    private func syncLibraryRecordIfNeeded(
        for track: Track,
        in job: DownloadJob,
        libraryRoot: URL
    ) async {
        guard job.mode == .library else { return }
        await syncLibraryRecordIfNeeded(for: track, libraryRoot: libraryRoot, preserveExportStamp: false)
    }

    private func syncLibraryRecordIfNeeded(
        for track: Track,
        libraryRoot: URL,
        preserveExportStamp: Bool
    ) async {
        guard let fileURL = track.fileURL,
              isInside(fileURL, root: libraryRoot),
              var entry = LibraryEntry.make(
                  from: track,
                  libraryFileName: relativePath(of: fileURL, under: libraryRoot)
              )
        else { return }

        let ledger = ledger(for: libraryRoot)
        let existing = await ledger.entry(uid: track.songUID)
        entry.addedAt = existing?.addedAt ?? entry.addedAt
        // Metadata/filename changes have to be exported again for BingoBite to
        // receive them, even when the audio content did not change.
        entry.exportedAt = preserveExportStamp ? existing?.exportedAt : nil
        await ledger.insert(entry)

        let entries = await ledger.allEntries()
        try? ManifestWriter.write(
            songs: entries,
            libraryName: libraryRoot.lastPathComponent,
            to: libraryRoot
        )
        libraryRevision += 1
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func isInside(_ fileURL: URL, root rootURL: URL) -> Bool {
        let root = Self.normalizedPath(rootURL)
        let file = Self.normalizedPath(fileURL)
        return file == root || file.hasPrefix(root + "/")
    }

    private func relativePath(of fileURL: URL, under rootURL: URL) -> String {
        let root = Self.normalizedPath(rootURL)
        let file = Self.normalizedPath(fileURL)
        guard file.hasPrefix(root + "/") else { return fileURL.lastPathComponent }
        return String(file.dropFirst(root.count + 1))
    }

    private static func metadata(from entry: LibraryEntry, fallbackTitle: String) -> SongMetadata {
        SongMetadata(
            title: entry.name.isEmpty ? fallbackTitle : entry.name,
            artist: entry.artist,
            album: entry.album,
            year: entry.year,
            coverArtURL: entry.coverArtURL.flatMap(URL.init(string:)),
            geniusID: entry.geniusID,
            geniusURL: entry.geniusURL.flatMap(URL.init(string:)),
            genre: entry.genre,
            comments: nil,
            songDescription: nil,
            annotations: nil,
            featuredArtists: nil,
            producerArtists: nil,
            writerArtists: nil,
            credits: nil,
            recordingLocation: nil,
            language: nil,
            releaseDate: entry.releaseDate,
            mediaLinks: nil,
            songRelationships: nil
        )
    }

    /// If `desired` already exists (and isn't the file we're moving), append " (2)", " (3)", etc.
    private static func uniqueDestination(for desired: URL, current: URL) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: desired.path) || desired == current { return desired }
        let base = desired.deletingPathExtension().lastPathComponent
        let ext = desired.pathExtension
        let dir = desired.deletingLastPathComponent()
        for n in 2...999 {
            let candidate = dir.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) || candidate == current {
                return candidate
            }
        }
        return desired
    }

    // MARK: - Persistence

    private struct JobSnapshot: Codable {
        let id: UUID
        let url: String
        let playlistTitle: String
        let folderPath: String
        let status: JobStatus
        let errorMessage: String?
        let createdAt: Date
        let tracks: [TrackSnapshot]
        // Optional so existing jobs.json files still decode.
        let mode: DownloadMode?
        let stagingPath: String?
        let skippedVideoIDs: [String]?
    }
    private struct TrackSnapshot: Codable {
        let id: String
        let title: String
        let status: JobStatus
        let progress: Double
        let filePath: String?
        let originalFilename: String?
        let metadata: SongMetadata?
        let enrichmentStatus: EnrichmentStatus?
        let alternativeMatches: [GeniusHitResult]?
        /// Optional so pre-existing jobs.json files still decode. On load, a
        /// missing UID is re-minted from the video id, which yields the same
        /// value it would have had.
        let songUID: String?
        let sourceDuration: Double?
    }

    private func persist() {
        let snapshots: [JobSnapshot] = jobs.map { job in
            // An interrupted merge is resumable — the un-moved files are still
            // in staging — so freeze it back to .staged rather than .cancelled.
            let persistedStatus: JobStatus
            if job.status == .merging {
                persistedStatus = .staged
            } else if job.isActive {
                persistedStatus = .cancelled
            } else {
                persistedStatus = job.status
            }
            return JobSnapshot(
                id: job.id,
                url: job.url,
                playlistTitle: job.playlistTitle,
                folderPath: job.folderURL.path,
                status: persistedStatus,
                errorMessage: job.errorMessage,
                createdAt: job.createdAt,
                tracks: job.tracks.map { track in
                    // Freeze any in-flight enrichment as failed so we don't
                    // resurrect a spinner on next launch.
                    let frozen: EnrichmentStatus = track.enrichmentStatus.isInFlight
                        ? .notStarted
                        : track.enrichmentStatus
                    return TrackSnapshot(
                        id: track.id,
                        title: track.title,
                        status: track.status == .downloading ? .cancelled : track.status,
                        progress: track.progress,
                        filePath: track.fileURL?.path,
                        originalFilename: track.originalFilename,
                        metadata: track.metadata,
                        enrichmentStatus: frozen,
                        alternativeMatches: track.alternativeMatches,
                        songUID: track.songUID,
                        sourceDuration: track.sourceDuration
                    )
                },
                mode: job.mode,
                stagingPath: job.stagingURL?.path,
                skippedVideoIDs: job.skippedVideoIDs
            )
        }
        do {
            let data = try JSONEncoder().encode(snapshots)
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            // Best-effort.
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: persistenceURL),
              let snapshots = try? JSONDecoder().decode([JobSnapshot].self, from: data)
        else { return }

        self.jobs = snapshots.map { snap in
            let job = DownloadJob(
                id: snap.id,
                url: snap.url,
                playlistTitle: snap.playlistTitle,
                folderURL: URL(fileURLWithPath: snap.folderPath),
                tracks: snap.tracks.map { ts in
                    let t = Track(id: ts.id, title: ts.title, songUID: ts.songUID)
                    t.status = ts.status
                    t.progress = ts.progress
                    if let p = ts.filePath { t.fileURL = URL(fileURLWithPath: p) }
                    t.originalFilename = ts.originalFilename
                    t.metadata = ts.metadata
                    t.enrichmentStatus = ts.enrichmentStatus ?? .notStarted
                    t.alternativeMatches = ts.alternativeMatches ?? []
                    t.sourceDuration = ts.sourceDuration
                    return t
                },
                status: snap.status,
                createdAt: snap.createdAt,
                mode: snap.mode ?? .freshFolder,
                stagingURL: snap.stagingPath.map { URL(fileURLWithPath: $0) },
                skippedVideoIDs: snap.skippedVideoIDs ?? []
            )
            job.errorMessage = snap.errorMessage
            if job.isLibraryMerged,
               let libraryFile = job.tracks.compactMap(\.fileURL).first {
                job.folderURL = libraryFile.deletingLastPathComponent()
                job.stagingURL = nil
            }
            return job
        }
    }

    // MARK: - Helpers

    private static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?*\"<>|")
        return name
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
