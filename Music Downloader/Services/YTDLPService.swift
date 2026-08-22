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
    ///
    /// - Parameter singleVideo: adds `--no-playlist` so a watch URL copied out
    ///   of a playlist describes just that video rather than the playlist it
    ///   happened to be playing from.
    func fetchMetadata(
        url: String,
        cookiesFromBrowser: String? = nil,
        singleVideo: Bool = false
    ) async throws -> PlaylistMetadata {
        let proc = Process()
        proc.executableURL = BinaryLocator.ytDlp
        proc.arguments = [
            "--flat-playlist",
            "--dump-single-json",
            "--no-warnings",
        ]
            + (singleVideo ? ["--no-playlist"] : [])
            + Self.cookieArguments(cookiesFromBrowser)
            + [url]
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
        archiveURL: URL? = nil,
        cookiesFromBrowser: String? = nil,
        singleVideo: Bool = false
    ) -> AsyncStream<YTDLPEvent> {
        AsyncStream { continuation in
            Task {
                await self.runDownload(
                    url: url,
                    outputDir: outputDir,
                    format: format,
                    jobID: jobID,
                    archiveURL: archiveURL,
                    cookiesFromBrowser: cookiesFromBrowser,
                    singleVideo: singleVideo,
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

    /// `--cookies-from-browser <name>`, or nothing when the user hasn't opted in.
    ///
    /// The only way past YouTube's age gate: it wants a signed-in session, and
    /// borrowing one from an already-signed-in browser is what yt-dlp's own
    /// error message tells you to do.
    private static func cookieArguments(_ browser: String?) -> [String] {
        guard let browser,
              !browser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [] }
        return ["--cookies-from-browser", browser]
    }

    /// Reads a pipe line by line, calling `onLine` for each and returning the
    /// full transcript when the pipe reaches EOF.
    ///
    /// Deliberately *not* `FileHandle.bytes.lines`: that iterator performs a
    /// synchronous `read(2)`, and a `Task {}` started inside an actor inherits
    /// that actor's executor. Draining stderr that way parked the whole
    /// `YTDLPService` actor inside a blocking read, so the stdout drain could
    /// never run. yt-dlp then filled the 64 KB stdout pipe and blocked in
    /// `write()`, while we blocked reading a stderr that would never speak
    /// again — a deadlock that stalled long playlists partway through with no
    /// error, and which `--progress` made far more likely by multiplying how
    /// much yt-dlp writes. `readabilityHandler` is event-driven and delivers on
    /// its own queue, so neither pipe can starve the other.
    private nonisolated static func drain(
        _ handle: FileHandle,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> [String] {
        await withCheckedContinuation { continuation in
            let accumulator = LineAccumulator()
            handle.readabilityHandler = { fileHandle in
                let chunk = fileHandle.availableData
                guard !chunk.isEmpty else {
                    // Empty read means EOF: the process closed its end.
                    fileHandle.readabilityHandler = nil
                    guard let lines = accumulator.finish(emit: onLine) else { return }
                    continuation.resume(returning: lines)
                    return
                }
                accumulator.consume(chunk, emit: onLine)
            }
        }
    }

    private func runDownload(
        url: String,
        outputDir: URL,
        format: String,
        jobID: UUID,
        archiveURL: URL?,
        cookiesFromBrowser: String?,
        singleVideo: Bool,
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
            // `--print` implies quiet mode, and quiet mode suppresses progress
            // output — including our own `--progress-template`. Without this
            // every track's progress bar sits at 0% for the whole download and
            // only jumps when DLEND lands. `--progress` forces it back on.
            "--progress",
            // Cap progress output at 4 lines/sec per download. yt-dlp's default
            // (0) emits one per read chunk, which floods the MainActor: every
            // event mutates an @Observable Track and re-renders the whole track
            // table, so a long playlist's UI ran minutes behind the actual
            // downloads. Still far finer than a progress bar can show.
            "--progress-delta", "0.25",
            "--progress-template",
            "DLPROG|%(info.id)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s",
            "--print", "before_dl:DLSTART|%(id)s|%(playlist_index|1)s|%(title)s",
            "--print", "after_move:DLEND|%(id)s|%(filepath)s",
        ]
        if let archiveURL {
            arguments += ["--download-archive", archiveURL.path]
        }
        if singleVideo {
            // A watch URL copied out of a playlist carries `&list=…`; without
            // this, adding one song would re-download the whole playlist.
            arguments.append("--no-playlist")
        }
        arguments += Self.cookieArguments(cookiesFromBrowser)
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

        // Drain both pipes concurrently. `drain` is event-driven and never
        // blocks, so neither stream can starve the other — see its comment for
        // the deadlock this replaced.
        async let stderrLines: [String] = Self.drain(errPipe.fileHandleForReading) { line in
            // Surface dead entries as they appear so the UI can mark the track
            // instead of waiting for the run to end.
            if let dead = ProgressParser.unavailableVideo(from: line) {
                continuation.yield(
                    .trackUnavailable(
                        videoID: dead.videoID,
                        reason: dead.reason,
                        kind: dead.kind
                    )
                )
            }
        }
        async let stdoutLines: [String] = Self.drain(outPipe.fileHandleForReading) { line in
            if let event = ProgressParser.parse(line: line) {
                continuation.yield(event)
            } else {
                continuation.yield(.logLine(line))
            }
        }

        let errLines = await stderrLines
        _ = await stdoutLines
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

/// Slices a byte stream into lines, remembering the partial tail between reads.
///
/// `FileHandle.readabilityHandler` fires serially on a single queue, so the
/// unsynchronised storage is safe; `finish` additionally guards against a
/// second EOF callback resuming the continuation twice.
private final class LineAccumulator: @unchecked Sendable {
    private var buffer = Data()
    private var collected: [String] = []
    private var finished = false

    func consume(_ chunk: Data, emit: (String) -> Void) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let text = String(data: line, encoding: .utf8) else { continue }
            collected.append(text)
            emit(text)
        }
    }

    /// Emits any unterminated trailing line and returns the transcript, or nil
    /// if EOF was already handled.
    func finish(emit: (String) -> Void) -> [String]? {
        guard !finished else { return nil }
        finished = true
        if !buffer.isEmpty, let text = String(data: buffer, encoding: .utf8) {
            collected.append(text)
            emit(text)
        }
        buffer.removeAll()
        return collected
    }
}
