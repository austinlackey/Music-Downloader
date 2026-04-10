import Foundation

/// Wraps the bundled yt-dlp binary as an actor-isolated Process bridge.
///
/// All blocking work runs off the MainActor. Progress events flow back to the
/// caller via `AsyncStream<YTDLPEvent>`.
actor YTDLPService {
    private var current: Process?

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
    func download(
        url: String,
        outputDir: URL,
        format: String
    ) -> AsyncStream<YTDLPEvent> {
        AsyncStream { continuation in
            Task {
                await self.runDownload(
                    url: url,
                    outputDir: outputDir,
                    format: format,
                    continuation: continuation
                )
            }
        }
    }

    func cancel() {
        current?.terminate()
        current = nil
    }

    // MARK: - Private

    private func runDownload(
        url: String,
        outputDir: URL,
        format: String,
        continuation: AsyncStream<YTDLPEvent>.Continuation
    ) async {
        let proc = Process()
        proc.executableURL = BinaryLocator.ytDlp
        let outputTemplate = outputDir
            .appendingPathComponent("%(title)s.%(ext)s")
            .path
        proc.arguments = [
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
            url,
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        self.current = proc

        do {
            try proc.run()
        } catch {
            continuation.yield(.failed("Failed to launch yt-dlp: \(error.localizedDescription)"))
            continuation.finish()
            self.current = nil
            return
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

        proc.waitUntilExit()
        let status = proc.terminationStatus
        self.current = nil

        if status == 0 {
            continuation.yield(.finished)
        } else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "yt-dlp exited \(status)"
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
