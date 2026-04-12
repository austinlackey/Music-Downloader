import Foundation

/// Writes ID3v2.3 tags (and optionally embedded cover art) to an mp3 file
/// by shelling out to the bundled ffmpeg binary. Writes to a sibling temp
/// file and atomically replaces the original.
actor MetadataWriter {
    /// - Parameters:
    ///   - metadata: resolved song metadata to inject as ID3 tags
    ///   - coverArtData: optional JPEG/PNG bytes to embed as album art
    ///   - fileURL: path to the existing mp3 (will be replaced in-place)
    func write(
        metadata: SongMetadata,
        coverArtData: Data?,
        to fileURL: URL
    ) async throws {
        let dir = fileURL.deletingLastPathComponent()
        let tempOut = dir.appendingPathComponent(".enrich-\(UUID().uuidString).mp3")

        var tempCover: URL?
        if let coverArtData {
            let url = dir.appendingPathComponent(".cover-\(UUID().uuidString).jpg")
            try coverArtData.write(to: url)
            tempCover = url
        }
        defer {
            try? FileManager.default.removeItem(at: tempOut)
            if let c = tempCover {
                try? FileManager.default.removeItem(at: c)
            }
        }

        var args: [String] = ["-y", "-loglevel", "error", "-i", fileURL.path]
        if let c = tempCover {
            args += ["-i", c.path]
            args += ["-map", "0:a", "-map", "1:v"]
        } else {
            args += ["-map", "0:a"]
        }
        args += ["-c", "copy", "-id3v2_version", "3", "-write_id3v2", "1"]
        args += ["-metadata", "title=\(metadata.title)"]
        args += ["-metadata", "artist=\(metadata.artist)"]
        if let album = metadata.album, !album.isEmpty {
            args += ["-metadata", "album=\(album)"]
        }
        if let year = metadata.year, !year.isEmpty {
            args += ["-metadata", "date=\(year)"]
        }
        if let genre = metadata.genre, !genre.isEmpty {
            args += ["-metadata", "genre=\(genre)"]
        }
        if let comments = metadata.comments, !comments.isEmpty {
            args += ["-metadata", "comment=\(comments)"]
        }
        if tempCover != nil {
            args += [
                "-metadata:s:v", "title=Album cover",
                "-metadata:s:v", "comment=Cover (front)",
            ]
        }
        args += [tempOut.path]

        let proc = Process()
        proc.executableURL = BinaryLocator.ffmpeg
        proc.arguments = args
        let errPipe = Pipe()
        let outPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = outPipe

        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let stderr = String(
                data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            throw MetadataWriterError.ffmpegFailed(stderr.isEmpty ? "exit \(proc.terminationStatus)" : stderr)
        }

        // Atomic swap: replaceItemAt preserves resource forks + moves to Trash on failure.
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempOut)
    }
}

nonisolated enum MetadataWriterError: LocalizedError {
    case ffmpegFailed(String)

    var errorDescription: String? {
        switch self {
        case .ffmpegFailed(let m): "ffmpeg failed: \(m)"
        }
    }
}
