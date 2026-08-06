import Foundation

/// Wraps the bundled yt-dlp binary as an actor-isolated Process bridge.
///
/// All blocking work runs off the MainActor. Progress events flow back to the
/// caller via `AsyncStream<YTDLPEvent>`.
actor YTDLPService {
    /// One process per job. A single shared slot meant a second concurrent
    /// download overwrote the first's handle, so cancelling either one killed
    /// whichever happened to start last.
    private var running: [UUID: Process] = [:]

    /// One-shot metadata fetch using `--flat-playlist --dump-single-json`.
    /// Works for single videos AND playlists.
    func fetchMetadata(url: String) async throws -> PlaylistMetadata {
        let proc = Process()
        proc.executableURL = BinaryLocator.ytDlp
        proc.arguments = [
            "--flat-playlist",
            "--dump-single-json",
            "--no-warnings",
            url,
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? "yt-dlp exited \(proc.terminationStatus)"
            throw YTDLPError.processFailed(msg)
        }
        return try JSONDecoder().decode(PlaylistMetadata.self, from: data)
    }

    /// Streams a download. Yields progress events until the process exits.
    ///
    /// - Parameters:
    ///   - jobID: identifies this run so `cancel(jobID:)` kills only this process
    ///   - archiveURL: when set, passed as `--download-archive`, making yt-dlp
    ///     skip anything already listed. This is dedupe layer 1 — the skip
    ///     happens before any bytes are fetched.
    func download(
        url: String,
        outputDir: URL,
        format: String,
        jobID: UUID,
        archiveURL: URL? = nil
    ) -> AsyncStream<YTDLPEvent> {
        AsyncStream { continuation in
            Task {
                await self.runDownload(
                    url: url,
                    outputDir: outputDir,
                    format: format,
                    jobID: jobID,
                    archiveURL: archiveURL,
                    continuation: continuation
                )
            }
        }
    }

    /// Terminates only the given job's process. Other jobs keep running.
    func cancel(jobID: UUID) {
        running[jobID]?.terminate()
        running[jobID] = nil
    }

    /// Terminates every running download. Used on app teardown.
    func cancelAll() {
        for process in running.values { process.terminate() }
        running.removeAll()
    }

    // MARK: - Private

    private func runDownload(
        url: String,
        outputDir: URL,
        format: String,
        jobID: UUID,
        archiveURL: URL?,
        continuation: AsyncStream<YTDLPEvent>.Continuation
    ) async {
        let proc = Process()
        proc.executableURL = BinaryLocator.ytDlp
        let outputTemplate = outputDir
            .appendingPathComponent("%(title)s.%(ext)s")
            .path
        var arguments = [
            "--extract-audio",
            "--audio-format", format,
            "--audio-quality", "0",
            "--ffmpeg-location", BinaryLocator.binDirectory.path,
            "--output", outputTemplate,
            "--no-warnings",
            "--no-playlist-reverse",
            "--newline",
            "--progress-template",
            "DLPROG|%(info.id)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s",
            "--print", "before_dl:DLSTART|%(id)s|%(playlist_index|1)s|%(title)s",
            "--print", "after_move:DLEND|%(id)s|%(filepath)s",
        ]
        if let archiveURL {
            arguments += ["--download-archive", archiveURL.path]
        }
        arguments.append(url)
        proc.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        self.running[jobID] = proc

        do {
            try proc.run()
        } catch {
            continuation.yield(.failed("Failed to launch yt-dlp: \(error.localizedDescription)"))
            continuation.finish()
            self.running[jobID] = nil
            return
        }

        // Drain stderr concurrently. Reading it only after the process exits
        // deadlocks a playlist with many dead entries: yt-dlp blocks once the
        // 64 KB pipe buffer fills, stdout goes quiet, and the loop below waits
        // forever on a process that is itself waiting on us.
        let errHandle = errPipe.fileHandleForReading
        let stderrTask = Task<[String], Never> {
            var lines: [String] = []
            do {
                for try await line in errHandle.bytes.lines {
                    lines.append(line)
                    // Surface dead entries as they appear so the UI can mark
                    // the track instead of waiting for the run to end.
                    if let dead = ProgressParser.unavailableVideo(from: line) {
                        continuation.yield(
                            .trackUnavailable(videoID: dead.videoID, reason: dead.reason)
                        )
                    }
                }
            } catch {
                lines.append("stderr read error: \(error.localizedDescription)")
            }
            return lines
        }

        // Read stdout line-by-line via the async byte stream.
        do {
            for try await line in outPipe.fileHandleForReading.bytes.lines {
                if let event = ProgressParser.parse(line: line) {
                    continuation.yield(event)
                } else {
                    continuation.yield(.logLine(line))
                }
            }
        } catch {
            continuation.yield(.logLine("stdout read error: \(error.localizedDescription)"))
        }

        let errLines = await stderrTask.value
        proc.waitUntilExit()
        let status = proc.terminationStatus
        self.running[jobID] = nil

        let hardErrors = errLines.filter(ProgressParser.isHardError)
        let deadEntryCount = errLines.compactMap(ProgressParser.unavailableVideo).count

        if status == 0 {
            continuation.yield(.finished)
        } else if hardErrors.isEmpty && deadEntryCount > 0 {
            // yt-dlp exits non-zero when *any* playlist entry fails, so a
            // handful of deleted videos would otherwise sink the whole job.
            // Everything that went wrong was a dead entry, already reported
            // above as .trackUnavailable — the rest of the run was fine.
            continuation.yield(.finished)
        } else {
            // Prefer the recognised errors, but never swallow an unexplained
            // non-zero exit: fall back to the raw stderr so the cause survives.
            let msg = (hardErrors.isEmpty ? errLines : hardErrors)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            continuation.yield(.failed(msg.isEmpty ? "yt-dlp exited \(status)" : msg))
        }
        continuation.finish()
    }
}

nonisolated enum YTDLPError: LocalizedError {
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .processFailed(let msg): "yt-dlp failed: \(msg)"
        }
    }
}
