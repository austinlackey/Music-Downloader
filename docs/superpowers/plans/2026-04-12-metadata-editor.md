# Track Metadata Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an interactive waveform, editable metadata fields (with view/edit mode toggle), and drag-and-drop artwork to the track inspector sheet.

**Architecture:** Modular subviews (`WaveformView`, `ArtworkDropZone`) composed into a refactored `TrackInspectorSheet` with view/edit mode. A new `saveManualMetadata()` method on `DownloadStore` handles writing user-edited fields back to disk via the existing `MetadataWriter`.

**Tech Stack:** SwiftUI, AVFoundation (AVAudioFile, AVAudioPCMBuffer), Observation framework, ffmpeg (bundled)

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `Music Downloader/Models/SongMetadata.swift` | Modify | Add `genre`, `comments` optional fields |
| `Music Downloader/Services/MetadataWriter.swift` | Modify | Write `genre` and `comment` ID3 tags via ffmpeg |
| `Music Downloader/Views/Detail/WaveformView.swift` | Create | Audio waveform rendering + interactive playback |
| `Music Downloader/Views/Detail/ArtworkDropZone.swift` | Create | Cover art display, drag & drop, file picker |
| `Music Downloader/Views/Detail/TrackInspectorSheet.swift` | Modify | Compose new subviews, add view/edit mode toggle |
| `Music Downloader/Stores/DownloadStore.swift` | Modify | Add `saveManualMetadata()` method |

---

### Task 1: Add `genre` and `comments` to SongMetadata

**Files:**
- Modify: `Music Downloader/Models/SongMetadata.swift`

- [ ] **Step 1: Add the two new fields**

Open `Music Downloader/Models/SongMetadata.swift` and add `genre` and `comments` as optional strings after the `geniusURL` field:

```swift
nonisolated struct SongMetadata: Codable, Sendable, Hashable {
    var title: String
    var artist: String
    var album: String?
    var year: String?           // "2023" — extracted from Genius release_date
    var coverArtURL: URL?
    var geniusID: Int?
    var geniusURL: URL?
    var genre: String?
    var comments: String?

    /// Convenience factory for SwiftUI previews / settings placeholders.
    static let sample = SongMetadata(
        title: "Me at the zoo",
        artist: "jawed",
        album: "YouTube",
        year: "2005",
        coverArtURL: nil,
        geniusID: nil,
        geniusURL: nil,
        genre: "Entertainment",
        comments: "First YouTube video ever"
    )
}
```

Because `SongMetadata` is `Codable` with all stored properties and the new fields are optional, existing persisted JSON (in `jobs.json`) will decode fine — missing keys default to `nil`.

- [ ] **Step 2: Build to verify**

Run: `Cmd+B` in Xcode (or `xcodebuild build` from CLI)
Expected: Clean build, no errors. All existing call sites that construct `SongMetadata` still compile because the new fields have defaults (they're optional with no explicit init, so Swift's memberwise initializer gives them `nil` defaults).

**Wait** — Swift's memberwise initializer puts parameters in declaration order and requires all non-defaulted params. Since `genre` and `comments` are `Optional` they default to `nil`, but callers using labeled arguments for earlier optional fields (like `geniusURL: nil`) will still compile fine. Verify no call sites break.

- [ ] **Step 3: Commit**

```bash
git add "Music Downloader/Models/SongMetadata.swift"
git commit -m "feat: add genre and comments fields to SongMetadata"
```

---

### Task 2: Update MetadataWriter to write genre and comment tags

**Files:**
- Modify: `Music Downloader/Services/MetadataWriter.swift`

- [ ] **Step 1: Add genre and comment ffmpeg arguments**

In `MetadataWriter.swift`, after the existing `date` metadata argument block (line ~47), add:

```swift
if let genre = metadata.genre, !genre.isEmpty {
    args += ["-metadata", "genre=\(genre)"]
}
if let comments = metadata.comments, !comments.isEmpty {
    args += ["-metadata", "comment=\(comments)"]
}
```

This goes right after the `year`/`date` block and before the `if tempCover != nil` block. The full args-building section should look like:

```swift
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
```

- [ ] **Step 2: Build to verify**

Run: `Cmd+B`
Expected: Clean build

- [ ] **Step 3: Commit**

```bash
git add "Music Downloader/Services/MetadataWriter.swift"
git commit -m "feat: write genre and comment ID3 tags in MetadataWriter"
```

---

### Task 3: Create WaveformView

**Files:**
- Create: `Music Downloader/Views/Detail/WaveformView.swift`

- [ ] **Step 1: Create the WaveformView file**

Create `Music Downloader/Views/Detail/WaveformView.swift` with the full implementation:

```swift
import AVFoundation
import SwiftUI

/// Renders an audio waveform from a file and provides interactive playback
/// with a scrubbing playhead.
struct WaveformView: View {
    let track: Track
    @Environment(PlaybackController.self) private var playback

    /// Downsampled amplitude data, one value per visual bucket. Range [0, 1].
    @State private var samples: [Float] = []
    @State private var isLoading = true

    /// Local scrub state so dragging doesn't fight with the 10 Hz timer.
    @State private var isScrubbing = false
    @State private var scrubFraction: Double = 0

    /// Duration read from the file (used before playback starts).
    @State private var trackDuration: TimeInterval = 0

    /// Number of amplitude buckets to render.
    private let bucketCount = 300

    var body: some View {
        VStack(spacing: 4) {
            waveformArea
            timeLabels
        }
        .task(id: track.fileURL) {
            await loadSamples()
        }
    }

    // MARK: - Waveform area

    private var waveformArea: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    waveformPath(in: geo.size)
                    playheadLine(width: geo.size.width)
                }

                HStack {
                    playPauseButton
                    Spacer()
                }
                .padding(.leading, 8)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isScrubbing = true
                        scrubFraction = max(0, min(1, value.location.x / geo.size.width))
                    }
                    .onEnded { value in
                        let fraction = max(0, min(1, value.location.x / geo.size.width))
                        if !playback.isCurrent(track) {
                            playback.play(track)
                        }
                        playback.seek(to: fraction * playback.duration)
                        isScrubbing = false
                    }
            )
        }
        .frame(height: 100)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func waveformPath(in size: CGSize) -> some View {
        let w = size.width
        let h = size.height
        let mid = h / 2

        return Path { path in
            guard !samples.isEmpty else { return }
            let barWidth = w / CGFloat(samples.count)
            for (i, amplitude) in samples.enumerated() {
                let x = CGFloat(i) * barWidth + barWidth / 2
                let barHeight = CGFloat(amplitude) * mid * 0.9
                path.move(to: CGPoint(x: x, y: mid - barHeight))
                path.addLine(to: CGPoint(x: x, y: mid + barHeight))
            }
        }
        .stroke(Color.primary.opacity(0.6), lineWidth: max(1, w / CGFloat(max(samples.count, 1)) * 0.6))
    }

    private func playheadLine(width: CGFloat) -> some View {
        let fraction = isScrubbing
            ? scrubFraction
            : (playback.duration > 0 && playback.isCurrent(track)
                ? playback.currentTime / playback.duration
                : 0)

        return Rectangle()
            .fill(Color.accentColor)
            .frame(width: 2)
            .offset(x: fraction * width)
    }

    // MARK: - Play/pause button

    private var playPauseButton: some View {
        Button {
            playback.toggle(track)
        } label: {
            Image(systemName: playback.isPlaying(track) ? "pause.fill" : "play.fill")
                .font(.system(size: 28))
                .foregroundStyle(.primary)
                .shadow(color: .black.opacity(0.3), radius: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Time labels

    private var timeLabels: some View {
        HStack {
            Text(format(currentDisplayTime))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer()

            Text("Duration: \(format(playback.isCurrent(track) ? playback.duration : trackDuration))")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer()

            Text("-\(format(remaining))")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var currentDisplayTime: TimeInterval {
        guard playback.isCurrent(track) else { return 0 }
        return isScrubbing ? scrubFraction * playback.duration : playback.currentTime
    }

    private var remaining: TimeInterval {
        guard playback.isCurrent(track) else { return trackDuration }
        let dur = playback.duration
        let cur = isScrubbing ? scrubFraction * dur : playback.currentTime
        return max(0, dur - cur)
    }

    // MARK: - Sample loading

    private func loadSamples() async {
        guard let url = track.fileURL else {
            isLoading = false
            return
        }

        // Read duration for labels even before playback.
        if let player = try? AVAudioPlayer(contentsOf: url) {
            trackDuration = player.duration
        }

        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)

            guard frameCount > 0 else {
                isLoading = false
                return
            }

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                isLoading = false
                return
            }
            try file.read(into: buffer)

            guard let channelData = buffer.floatChannelData?[0] else {
                isLoading = false
                return
            }

            let total = Int(buffer.frameLength)
            let framesPerBucket = max(1, total / bucketCount)
            var result = [Float]()
            result.reserveCapacity(bucketCount)

            for bucket in 0..<bucketCount {
                let start = bucket * framesPerBucket
                let end = min(start + framesPerBucket, total)
                var maxAmp: Float = 0
                for i in start..<end {
                    let val = abs(channelData[i])
                    if val > maxAmp { maxAmp = val }
                }
                result.append(maxAmp)
            }

            // Normalize to [0, 1]
            let peak = result.max() ?? 1
            if peak > 0 {
                result = result.map { $0 / peak }
            }

            await MainActor.run {
                samples = result
                isLoading = false
            }
        } catch {
            await MainActor.run {
                isLoading = false
            }
        }
    }

    // MARK: - Formatting

    private func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
```

- [ ] **Step 2: Add file to Xcode project**

The file needs to be added to the Xcode project. If using Xcode's file navigator, drag it in. If using CLI, the `project.pbxproj` will need updating. The simplest approach: open Xcode, right-click the `Views/Detail` group, choose "Add Files to Music Downloader", and select `WaveformView.swift`.

- [ ] **Step 3: Build to verify**

Run: `Cmd+B`
Expected: Clean build. The view isn't used yet, but it should compile.

- [ ] **Step 4: Commit**

```bash
git add "Music Downloader/Views/Detail/WaveformView.swift"
git commit -m "feat: add WaveformView with interactive playback and scrubbing"
```

---

### Task 4: Create ArtworkDropZone

**Files:**
- Create: `Music Downloader/Views/Detail/ArtworkDropZone.swift`

- [ ] **Step 1: Create the ArtworkDropZone file**

Create `Music Downloader/Views/Detail/ArtworkDropZone.swift`:

```swift
import SwiftUI
import UniformTypeIdentifiers

/// Displays album artwork with drag-and-drop and click-to-browse support
/// for replacing the image.
struct ArtworkDropZone: View {
    /// Current cover art data (JPEG/PNG bytes), if any. Takes priority over URL.
    let artworkData: Data?

    /// Fallback: cover art URL (e.g. from Genius). Used when artworkData is nil.
    let artworkURL: URL?

    /// Whether the zone accepts interaction (true in edit mode).
    let isEditable: Bool

    /// Called when the user provides new artwork (via drop or file picker).
    let onArtworkChanged: (Data) -> Void

    @State private var isTargeted = false
    @State private var showFilePicker = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))

            if let artworkData, let nsImage = NSImage(data: artworkData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if let artworkURL {
                AsyncImage(url: artworkURL) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                placeholder
            }
        }
        .frame(width: 160, height: 160)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.2),
                    lineWidth: isTargeted ? 2 : 0.5
                )
        )
        .onDrop(of: [.image], isTargeted: $isTargeted) { providers in
            guard isEditable else { return false }
            return handleDrop(providers)
        }
        .onTapGesture {
            guard isEditable else { return }
            showFilePicker = true
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .opacity(isEditable ? 1 : 0.8)
        .help(isEditable ? "Click to browse or drag an image to set artwork" : "")
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Drag Artwork\nHere")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Drop handling

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        // Try to load as file URL first, then as raw image data.
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                if let data {
                    DispatchQueue.main.async {
                        onArtworkChanged(data)
                    }
                }
            }
            return true
        }
        return false
    }

    // MARK: - File picker handling

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result,
              let url = urls.first else { return }

        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        if let data = try? Data(contentsOf: url) {
            onArtworkChanged(data)
        }
    }
}
```

- [ ] **Step 2: Add file to Xcode project**

Add `ArtworkDropZone.swift` to the Xcode project under the `Views/Detail` group.

- [ ] **Step 3: Build to verify**

Run: `Cmd+B`
Expected: Clean build

- [ ] **Step 4: Commit**

```bash
git add "Music Downloader/Views/Detail/ArtworkDropZone.swift"
git commit -m "feat: add ArtworkDropZone with drag-and-drop and file picker"
```

---

### Task 5: Add `saveManualMetadata()` to DownloadStore

**Files:**
- Modify: `Music Downloader/Stores/DownloadStore.swift`

- [ ] **Step 1: Add the saveManualMetadata method**

In `DownloadStore.swift`, add this new method in the `Public actions: Enrichment` section (after the `applyMatch` method, around line 119):

```swift
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
```

- [ ] **Step 2: Build to verify**

Run: `Cmd+B`
Expected: Clean build. The method uses existing `writer`, `FilenameTemplate`, `uniqueDestination`, and `persist` — all already available.

- [ ] **Step 3: Commit**

```bash
git add "Music Downloader/Stores/DownloadStore.swift"
git commit -m "feat: add saveManualMetadata method to DownloadStore"
```

---

### Task 6: Refactor TrackInspectorSheet with view/edit mode, waveform, and artwork

**Files:**
- Modify: `Music Downloader/Views/Detail/TrackInspectorSheet.swift`

This is the largest task. The sheet is restructured to compose `WaveformView` and `ArtworkDropZone`, with a view/edit mode toggle.

- [ ] **Step 1: Replace the TrackInspectorSheet implementation**

Replace the entire contents of `Music Downloader/Views/Detail/TrackInspectorSheet.swift` with:

```swift
import SwiftUI
import UniformTypeIdentifiers

/// Per-track inspector with interactive waveform, metadata view/edit, and
/// artwork management. Default view shows Genius matches; edit mode enables
/// direct field editing.
struct TrackInspectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DownloadStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(PlaybackController.self) private var playback

    @Bindable var track: Track
    let job: DownloadJob

    // Genius match selection (view mode)
    @State private var selectedHitID: Int?
    @State private var customQuery: String = ""
    @State private var isResearching = false

    // Edit mode state
    @State private var isEditing = false
    @State private var editTitle = ""
    @State private var editArtist = ""
    @State private var editAlbum = ""
    @State private var editYear = ""
    @State private var editGenre = ""
    @State private var editComments = ""
    @State private var editArtworkData: Data?
    @State private var artworkChanged = false

    var body: some View {
        VStack(spacing: 0) {
            // Waveform at top
            WaveformView(track: track)
                .padding(20)

            Divider()

            // File info row
            fileInfoRow
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

            Divider()

            ScrollView {
                HStack(alignment: .top, spacing: 16) {
                    // Left: tags
                    VStack(alignment: .leading, spacing: 16) {
                        tagsSection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Right: artwork
                    ArtworkDropZone(
                        artworkData: isEditing ? editArtworkData : nil,
                        artworkURL: track.metadata?.coverArtURL
                            ?? track.alternativeMatches.first?.songArtImageURL,
                        isEditable: isEditing,
                        onArtworkChanged: { data in
                            editArtworkData = data
                            artworkChanged = true
                        }
                    )
                }
                .padding(20)

                if !isEditing {
                    VStack(alignment: .leading, spacing: 16) {
                        alternativesSection
                        researchSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }

            Divider()

            actionsSection
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(width: 660, height: 720)
        .onAppear {
            selectedHitID = track.metadata?.geniusID
                ?? track.alternativeMatches.first?.id
        }
    }

    // MARK: - File info row

    private var fileInfoRow: some View {
        HStack(spacing: 16) {
            if let url = track.fileURL {
                HStack(spacing: 4) {
                    Text("File:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? UInt64 {
                    HStack(spacing: 4) {
                        Text("Size:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            .font(.caption)
                    }
                }

                HStack(spacing: 4) {
                    Text("Format:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(url.pathExtension.uppercased())
                        .font(.caption)
                }
            }

            Spacer()

            Button {
                store.revealTrackInFinder(track)
            } label: {
                Label("Reveal", systemImage: "magnifyingglass")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Tags section

    @ViewBuilder
    private var tagsSection: some View {
        HStack {
            sectionLabel("Tags")
            Spacer()
            Button {
                if isEditing {
                    // Cancel edit
                    isEditing = false
                    artworkChanged = false
                } else {
                    enterEditMode()
                }
            } label: {
                Text(isEditing ? "Cancel" : "Edit")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }

        if isEditing {
            editableFields
        } else {
            readOnlyFields
        }
    }

    // MARK: - Read-only fields (view mode)

    @ViewBuilder
    private var readOnlyFields: some View {
        let metadata = track.metadata

        VStack(alignment: .leading, spacing: 6) {
            infoRow(label: "Title", value: metadata?.title ?? track.title)
            infoRow(label: "Artist", value: metadata?.artist ?? "—")
            infoRow(label: "Album", value: metadata?.album ?? "—")
            infoRow(label: "Year", value: metadata?.year ?? "—")
            infoRow(label: "Genre", value: metadata?.genre ?? "—")
            if let comments = metadata?.comments, !comments.isEmpty {
                infoRow(label: "Comments", value: comments)
            }
        }

        if let geniusURL = metadata?.geniusURL {
            Link(destination: geniusURL) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right.square")
                    Text("View on Genius")
                }
                .font(.caption)
            }
        }

        HStack(spacing: 6) {
            Image(systemName: track.enrichmentStatus.symbolName)
                .foregroundStyle(track.enrichmentStatus.tint)
            Text(track.enrichmentStatus.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Editable fields (edit mode)

    @ViewBuilder
    private var editableFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            editRow(label: "Title", text: $editTitle)
            editRow(label: "Artist", text: $editArtist)
            editRow(label: "Album", text: $editAlbum)
            editRow(label: "Year", text: $editYear)
            editRow(label: "Genre", text: $editGenre)

            HStack(alignment: .top, spacing: 10) {
                Text("Comments")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)
                    .padding(.top, 4)
                TextEditor(text: $editComments)
                    .font(.caption)
                    .frame(height: 60)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func editRow(label: String, text: Binding<String>) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
        }
    }

    private func enterEditMode() {
        let m = track.metadata
        editTitle = m?.title ?? track.title
        editArtist = m?.artist ?? ""
        editAlbum = m?.album ?? ""
        editYear = m?.year ?? ""
        editGenre = m?.genre ?? ""
        editComments = m?.comments ?? ""
        editArtworkData = currentArtworkData
        artworkChanged = false
        isEditing = true
    }

    // MARK: - Alternatives (view mode only)

    @ViewBuilder
    private var alternativesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Alternative Matches")

            if track.alternativeMatches.isEmpty {
                Text("No alternatives available. Search with a custom query below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 0) {
                    ForEach(track.alternativeMatches) { hit in
                        HitRow(
                            hit: hit,
                            isSelected: selectedHitID == hit.id,
                            onSelect: { selectedHitID = hit.id }
                        )
                        if hit.id != track.alternativeMatches.last?.id {
                            Divider().padding(.leading, 60)
                        }
                    }
                }
                .background(Color.secondary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - Re-search (view mode only)

    @ViewBuilder
    private var researchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Search Again")
            HStack(spacing: 8) {
                TextField("Custom query (e.g. \"Artist Title\")", text: $customQuery)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isResearching)
                Button {
                    Task { await researchWithCustomQuery() }
                } label: {
                    if isResearching {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Search")
                    }
                }
                .disabled(isResearching || customQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - Actions bar

    @ViewBuilder
    private var actionsSection: some View {
        HStack(spacing: 8) {
            if !isEditing {
                if track.originalFilename != nil,
                   track.fileURL?.deletingPathExtension().lastPathComponent != track.originalFilename {
                    Button {
                        store.revertFilename(track, in: job)
                    } label: {
                        Label("Revert Filename", systemImage: "arrow.uturn.backward")
                    }
                }
            }

            Spacer()

            Button("Close") { dismiss() }

            if isEditing {
                Button {
                    saveEdits()
                } label: {
                    Label("Save", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(editTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Button {
                    applySelected()
                } label: {
                    Label("Apply Match", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply)
            }
        }
    }

    // MARK: - Save edits

    private func saveEdits() {
        let metadata = SongMetadata(
            title: editTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            artist: editArtist.trimmingCharacters(in: .whitespacesAndNewlines),
            album: editAlbum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : editAlbum.trimmingCharacters(in: .whitespacesAndNewlines),
            year: editYear.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : editYear.trimmingCharacters(in: .whitespacesAndNewlines),
            coverArtURL: track.metadata?.coverArtURL,
            geniusID: track.metadata?.geniusID,
            geniusURL: track.metadata?.geniusURL,
            genre: editGenre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : editGenre.trimmingCharacters(in: .whitespacesAndNewlines),
            comments: editComments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : editComments.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        let artwork = artworkChanged ? editArtworkData : nil
        store.saveManualMetadata(
            track: track,
            in: job,
            metadata: metadata,
            coverArtData: artwork,
            settings: settings
        )
        isEditing = false
        artworkChanged = false
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var canApply: Bool {
        guard let selectedHitID else { return false }
        if track.enrichmentStatus == .enriched,
           track.metadata?.geniusID == selectedHitID {
            return false
        }
        return track.alternativeMatches.contains(where: { $0.id == selectedHitID })
    }

    private func applySelected() {
        guard let id = selectedHitID,
              let hit = track.alternativeMatches.first(where: { $0.id == id })
        else { return }
        store.applyMatch(hit, to: track, in: job, settings: settings)
    }

    private func researchWithCustomQuery() async {
        let query = customQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isResearching = true
        defer { isResearching = false }

        let token = settings.geniusToken
        guard !token.isEmpty else {
            track.enrichmentStatus = .failed(GeniusError.missingToken.localizedDescription)
            return
        }

        do {
            let service = GeniusService()
            let hits = try await service.search(query: query, token: token)
            track.alternativeMatches = Array(hits.prefix(5))
            selectedHitID = hits.first?.id
        } catch {
            track.enrichmentStatus = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Hit row

private struct HitRow: View {
    let hit: GeniusHitResult
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                AsyncImage(url: hit.songArtImageThumbnailURL ?? hit.songArtImageURL) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        Color.secondary.opacity(0.2)
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.title)
                        .font(.body)
                        .lineLimit(1)
                    Text(hit.primaryArtist.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .font(.title3)
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
    }
}
```

- [ ] **Step 2: Verify PlaybackController is in the environment**

Check `Music_DownloaderApp.swift` or `ContentView.swift` to confirm `PlaybackController` is passed via `.environment()`. The new `TrackInspectorSheet` now reads `@Environment(PlaybackController.self)` — this was not needed before. It should already be in the environment since `PlayerBar` uses it, but verify. If the sheet is presented as `.sheet(item:)` from `JobDetailView`, the environment propagates automatically in SwiftUI.

- [ ] **Step 3: Build to verify**

Run: `Cmd+B`
Expected: Clean build. If there's an issue with `PlaybackController` not being in the environment for the sheet, check how the sheet is presented and ensure the environment modifier is applied at or above the presentation site.

- [ ] **Step 4: Manual test**

1. Launch the app
2. Open a completed download job
3. Click a completed track to open the inspector
4. Verify the waveform renders at the top
5. Verify file info row shows filename, size, format
6. Verify the existing Genius match UI still works (view mode)
7. Click "Edit" — fields should become editable text fields populated with current values
8. Modify a field, click "Save" — tags should be written
9. Click "Cancel" — edits should be discarded
10. Test drag-and-drop of an image onto the artwork zone in edit mode
11. Test clicking the artwork zone to open file picker in edit mode

- [ ] **Step 5: Commit**

```bash
git add "Music Downloader/Views/Detail/TrackInspectorSheet.swift"
git commit -m "feat: refactor TrackInspectorSheet with waveform, edit mode, and artwork zone"
```

---

### Task 7: Final integration build and cleanup

**Files:**
- All modified files

- [ ] **Step 1: Full clean build**

Run: `Cmd+Shift+K` (Clean Build Folder) then `Cmd+B`
Expected: Clean build with no warnings related to our changes.

- [ ] **Step 2: Test the full flow end-to-end**

1. Start a fresh download of a YouTube video
2. Wait for download to complete
3. Run "Enrich Metadata" — verify genre/comments fields don't break existing enrichment
4. Open the track inspector — verify waveform, file info, Genius matches all display
5. Click Edit → modify Title and Artist → Save → verify ID3 tags updated (check in Finder Get Info or another audio player)
6. Click Edit → drag a custom image onto artwork zone → Save → verify artwork embedded
7. Click Edit → Cancel → verify no changes persisted
8. Test "Revert Filename" still works
9. Test "Apply Match" with an alternative Genius hit still works
10. Test "Search Again" with a custom query still works

- [ ] **Step 3: Commit any fixes**

```bash
git add -A
git commit -m "fix: address integration issues from metadata editor feature"
```

(Only if fixes were needed. Skip if clean.)
