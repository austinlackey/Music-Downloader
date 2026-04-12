import AppKit
import Foundation
import Observation

/// Owns the list of `DownloadJob`s and orchestrates downloads via `YTDLPService`
/// and metadata enrichment via `GeniusService` + `MetadataWriter`.
@Observable
@MainActor
final class DownloadStore {
    var jobs: [DownloadJob] = []

    private let service = YTDLPService()
    private let genius = GeniusService()
    private let writer = MetadataWriter()
    private let persistenceURL: URL

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
    func startDownload(url: String, settings: AppSettings) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let job = DownloadJob(
            url: trimmed,
            playlistTitle: "Loading…",
            folderURL: settings.downloadRoot
        )
        jobs.insert(job, at: 0)

        Task { await self.execute(job: job, format: settings.audioFormat, root: settings.downloadRoot) }
    }

    func cancel(_ job: DownloadJob) {
        Task {
            await service.cancel()
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
        NSWorkspace.shared.activateFileViewerSelecting([job.folderURL])
    }

    func revealTrackInFinder(_ track: Track) {
        guard let url = track.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Public actions: Enrichment

    /// Bulk-enrich every completed track in a job. Throttled to 5 in-flight requests.
    /// Re-running picks up only tracks that aren't already `.enriched`.
    func enrich(job: DownloadJob, settings: AppSettings) {
        guard !settings.geniusToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            job.errorMessage = GeniusError.missingToken.localizedDescription
            return
        }
        let token = settings.geniusToken
        let template = settings.renameTemplate

        Task { [weak self] in
            guard let self else { return }
            let pending = job.tracks.filter {
                $0.fileURL != nil && $0.enrichmentStatus != .enriched && $0.enrichmentStatus != .skipped
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
                            template: template
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
            await self?.applyHit(hit, to: track, in: job, token: token, template: template)
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
            } catch {
                track.enrichmentStatus = .failed(error.localizedDescription)
            }

            self.persist()
        }
    }

    /// Rename a track back to its original yt-dlp filename. Tags stay written;
    /// this only undoes the rename.
    func revertFilename(_ track: Track, in job: DownloadJob) {
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
            persist()
        } catch {
            track.enrichmentStatus = .failed("Revert failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Download pipeline

    private func execute(job: DownloadJob, format: String, root: URL) async {
        job.status = .fetchingMetadata
        do {
            let metadata = try await service.fetchMetadata(url: job.url)
            let playlistTitle = metadata.title
                ?? metadata.entries?.first?.title
                ?? "Untitled"
            job.playlistTitle = playlistTitle

            let folder = root.appendingPathComponent(
                Self.sanitize(playlistTitle),
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true
            )
            job.folderURL = folder

            // Build the track list. For single videos, synthesize one entry.
            let entries: [PlaylistMetadata.Entry] = metadata.entries
                ?? [PlaylistMetadata.Entry(
                        id: metadata.id ?? "single",
                        title: metadata.title,
                        duration: nil
                   )]
            job.tracks = entries.map {
                Track(id: $0.id, title: $0.title ?? $0.id)
            }

            job.status = .downloading
            for await event in await service.download(
                url: job.url,
                outputDir: folder,
                format: format
            ) {
                apply(event, to: job)
            }

            if job.status == .downloading {
                job.status = job.tracks.allSatisfy { $0.status == .completed }
                    ? .completed
                    : .failed
            }
        } catch {
            job.status = .failed
            job.errorMessage = error.localizedDescription
        }
        persist()
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
        template: String
    ) async {
        guard track.fileURL != nil else { return }
        track.enrichmentStatus = .searching

        do {
            let hits = try await genius.search(query: track.title, token: token)
            guard let top = hits.first else { throw GeniusError.noMatch }
            track.alternativeMatches = Array(hits.prefix(5))
            await applyHit(top, to: track, in: job, token: token, template: template)
        } catch {
            track.enrichmentStatus = .failed(error.localizedDescription)
        }
    }

    private func applyHit(
        _ hit: GeniusHitResult,
        to track: Track,
        in job: DownloadJob,
        token: String,
        template: String
    ) async {
        guard let currentURL = track.fileURL else { return }
        // Capture original filename on first enrichment for revert.
        if track.originalFilename == nil {
            track.originalFilename = currentURL.deletingPathExtension().lastPathComponent
        }

        track.enrichmentStatus = .matched

        do {
            let metadata = try await genius.metadataFor(hit: hit, token: token)

            // Download cover art if available (non-fatal on failure).
            var coverData: Data? = nil
            if let coverURL = metadata.coverArtURL {
                coverData = try? await genius.fetchCoverArt(url: coverURL)
            }

            track.enrichmentStatus = .writing
            try await writer.write(
                metadata: metadata,
                coverArtData: coverData,
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
        } catch {
            track.enrichmentStatus = .failed(error.localizedDescription)
        }
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
    }

    private func persist() {
        let snapshots: [JobSnapshot] = jobs.map { job in
            let persistedStatus: JobStatus = job.isActive ? .cancelled : job.status
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
                        alternativeMatches: track.alternativeMatches
                    )
                }
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
                    let t = Track(id: ts.id, title: ts.title)
                    t.status = ts.status
                    t.progress = ts.progress
                    if let p = ts.filePath { t.fileURL = URL(fileURLWithPath: p) }
                    t.originalFilename = ts.originalFilename
                    t.metadata = ts.metadata
                    t.enrichmentStatus = ts.enrichmentStatus ?? .notStarted
                    t.alternativeMatches = ts.alternativeMatches ?? []
                    return t
                },
                status: snap.status,
                createdAt: snap.createdAt
            )
            job.errorMessage = snap.errorMessage
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
