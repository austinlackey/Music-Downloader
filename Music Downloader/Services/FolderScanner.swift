import AVFoundation
import Foundation

/// An audio file sitting in a playlist folder that no track in the job points
/// at — something the user dropped in by hand, or a leftover the app lost
/// track of.
///
/// Transient by design: rebuilt on every scan rather than persisted, so the
/// folder on disk is always the source of truth.
nonisolated struct DiscoveredFile: Identifiable, Sendable, Hashable {
    /// The file path. Stable for as long as the file is where we found it,
    /// which is exactly as long as this record is meant to live.
    var id: String { url.path }
    let url: URL
    /// Title from the file's own tags, falling back to the filename.
    let title: String
    /// Artist from the file's own tags, if it has any.
    let artist: String?
    let album: String?
    let durationSeconds: Double?
    let fileSize: Int64?
    /// `SONG_UID` read back out of the file, when it was written by this app
    /// or by BingoBite. Lets a file that wanders back into a folder rejoin the
    /// playlist under its original identity instead of a fresh local UID.
    let songUID: String?
    /// `SOURCE_VIDEO_ID`, same provenance as `songUID`.
    let sourceVideoID: String?

    var displayName: String { url.lastPathComponent }
}

/// Reconciles a playlist folder on disk against the tracks a job thinks it has.
///
/// Downloads are not the only way files get into a playlist folder — users drag
/// them in, delete them, and rename them behind the app's back. This reads the
/// folder rather than trusting `jobs.json`.
nonisolated enum FolderScanner {

    /// Extensions treated as audio. Broader than the app's own download
    /// formats: a hand-dropped file could be anything the user's other tools
    /// produced.
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "flac", "wav", "opus", "aac", "aiff", "aif", "alac", "ogg", "wma",
    ]

    /// Files in `folder` that none of `knownPaths` accounts for, with whatever
    /// metadata their tags carry.
    ///
    /// Non-recursive: a playlist folder is flat, and descending would sweep up
    /// unrelated subfolders the user parked there.
    static func scan(folder: URL, knownPaths: Set<String>) async -> [DiscoveredFile] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let normalizedKnown = Set(knownPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })

        var results: [DiscoveredFile] = []
        for url in contents {
            guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard !isDirectory else { continue }
            guard !normalizedKnown.contains(url.standardizedFileURL.path) else { continue }
            // A half-written download that yt-dlp or ffmpeg is still working on.
            guard !url.lastPathComponent.hasSuffix(".part") else { continue }
            results.append(await describe(url))
        }
        return results.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Reads one file's tags. Every field is optional — an untagged file still
    /// yields a usable record built from its filename.
    static func describe(_ url: URL) async -> DiscoveredFile {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        let filenameTitle = url.deletingPathExtension().lastPathComponent

        let asset = AVURLAsset(url: url)
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double?
        var songUID: String?
        var sourceVideoID: String?

        if let loaded = try? await asset.load(.commonMetadata) {
            title = await stringValue(from: loaded, key: .commonKeyTitle)
            artist = await stringValue(from: loaded, key: .commonKeyArtist)
            album = await stringValue(from: loaded, key: .commonKeyAlbumName)
        }
        if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds > 0 {
            duration = seconds
        }
        // The identity frames live in format-specific metadata, not the common
        // keys, so they need a separate sweep across every format the file has.
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                guard let items = try? await asset.loadMetadata(for: format) else { continue }
                for item in items {
                    guard let key = await identifierKey(for: item) else { continue }
                    guard let value = try? await item.load(.stringValue),
                          !value.isEmpty else { continue }
                    switch key {
                    case SongUID.uidKey:           songUID = songUID ?? value
                    case SongUID.sourceVideoIDKey: sourceVideoID = sourceVideoID ?? value
                    default:                       break
                    }
                }
            }
        }

        return DiscoveredFile(
            url: url,
            title: title?.isEmpty == false ? title! : filenameTitle,
            artist: artist?.isEmpty == false ? artist : nil,
            album: album?.isEmpty == false ? album : nil,
            durationSeconds: duration,
            fileSize: size,
            songUID: SongUID.isValid(songUID) ? songUID : nil,
            sourceVideoID: sourceVideoID
        )
    }

    private static func stringValue(
        from items: [AVMetadataItem],
        key: AVMetadataKey
    ) async -> String? {
        for item in items where item.commonKey == key {
            if let value = try? await item.load(.stringValue), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// The custom-frame name for a metadata item, across the three shapes the
    /// tag writer produces.
    ///
    /// Each container hides the name somewhere different: an ID3 TXXX frame
    /// reports `key` as the literal "TXXX" and puts the real name in the `info`
    /// extra attribute, mp4 freeform atoms bury it in the identifier
    /// (`----:com.apple.iTunes:NAME`), and Vorbis comments put it straight in
    /// `key`. All three are checked because the library format is user-chosen.
    private static func identifierKey(for item: AVMetadataItem) async -> String? {
        if let extras = try? await item.load(.extraAttributes),
           let info = extras[.info] as? String,
           SongUID.allKeys.contains(info.uppercased()) {
            return info.uppercased()
        }
        if let key = item.key as? String, SongUID.allKeys.contains(key.uppercased()) {
            return key.uppercased()
        }
        guard let identifier = item.identifier?.rawValue else { return nil }
        let tail = identifier.split(separator: "/").last.map(String.init) ?? identifier
        let name = tail.split(separator: ":").last.map(String.init) ?? tail
        let upper = name.uppercased()
        return SongUID.allKeys.contains(upper) ? upper : nil
    }
}
