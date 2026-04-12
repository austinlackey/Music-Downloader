# Track Metadata Editor — Design Spec

## Overview

Enhance the existing `TrackInspectorSheet` with an interactive waveform, editable metadata fields, and a drag-and-drop artwork zone. The inspector keeps its current Genius-match UI as the default view and adds an edit mode for manual metadata overrides.

## Data Model Changes

### SongMetadata

Add two optional fields:

- `genre: String?`
- `comments: String?`

These are written as ID3 tags via ffmpeg (`-metadata genre=`, `-metadata comment=`). The rest of the model is unchanged. `GeniusService` can populate genre from the API when available.

No changes to `Track`, `DownloadJob`, or other models.

## New Views

### WaveformView

**File**: `Music Downloader/Views/Detail/WaveformView.swift`

A SwiftUI view that renders an audio waveform with interactive playback.

**Behavior**:
- On appear, reads audio samples from `track.fileURL` using `AVAudioFile` + `AVAudioPCMBuffer`
- Downsamples to ~300 amplitude buckets (max amplitude per bucket)
- Renders a mirrored `Path` (positive above center, negative below)
- Caches waveform data in `@State [Float]` — computed once per file

**Playback integration**:
- Play/pause button overlaid at the left
- Vertical playhead line at current position, updated via `PlaybackController`'s 10Hz timer
- `DragGesture` on waveform seeks to tapped/dragged x-position (converted to time offset)

**Time labels**: current time (left), duration (center), remaining (right)

**Inputs**: `Track` (for `fileURL`), `PlaybackController` from environment.

### ArtworkDropZone

**File**: `Music Downloader/Views/Detail/ArtworkDropZone.swift`

A SwiftUI view for displaying and replacing cover art.

**Behavior**:
- Shows current cover art if available, otherwise a placeholder with "Drag Artwork Here"
- `.onDrop(of: [.image])` accepts dragged image files, reads data, calls closure
- Tap opens `.fileImporter(allowedContentTypes: [.image])` for browsing
- Visual feedback: border highlight while dragging over

**Inputs**: `Data?` for current artwork, `(Data) -> Void` closure for new art.

The view does not write metadata — it hands image data to the parent.

## TrackInspectorSheet Refactoring

**File**: `Music Downloader/Views/Detail/TrackInspectorSheet.swift`

### Layout (top to bottom)

1. **WaveformView** — always visible, interactive playback
2. **File info row** — filename, file size, format, duration. "Reveal in Finder" button.
3. **Tags section** (`DisclosureGroup`, expanded by default):
   - **View mode** (default): static text labels for metadata fields. Below, the existing Genius alternative matches list with radio buttons, "Apply Match", and "Search Again".
   - **Edit mode** (toggled by "Edit" button): `TextField`s for Title, Artist, Album, Year, Genre, Comments. "Save" writes changes, "Cancel" reverts without saving.
4. **ArtworkDropZone** — to the right of the tags fields. Visible in both modes, interactive only in edit mode.

### State Management

- Edit mode holds a local `@State` copy of metadata field values
- On "Save": builds `SongMetadata`, calls `DownloadStore.saveManualMetadata()`, exits edit mode
- On "Cancel": discards local state, returns to view mode
- Existing "Revert Filename" button remains unchanged

## DownloadStore Integration

### New Method

```swift
func saveManualMetadata(track: Track, metadata: SongMetadata, coverArtData: Data?, settings: AppSettings) async
```

**Flow**:
1. Write ID3 tags via `MetadataWriter.write(metadata:coverArtData:to:)` on the track's file
2. Update `track.metadata` with the new `SongMetadata`
3. Set `track.enrichmentStatus` to `.enriched`
4. If title or artist changed and a rename template is configured, re-render filename via `FilenameTemplate.render()` and rename the file on disk
5. Persist job snapshot to disk

Reuses same infrastructure as `applyMatch` — skips Genius fetch, takes user-provided values directly.

## MetadataWriter Changes

Add `genre` and `comment` to the ffmpeg argument list:

- `-metadata genre=<value>` (if genre is non-nil and non-empty)
- `-metadata comment=<value>` (if comments is non-nil and non-empty)

No other changes needed — the existing atomic write flow handles everything.

## Files Summary

| File | Action |
|------|--------|
| `Models/SongMetadata.swift` | Add `genre`, `comments` fields |
| `Views/Detail/WaveformView.swift` | New file |
| `Views/Detail/ArtworkDropZone.swift` | New file |
| `Views/Detail/TrackInspectorSheet.swift` | Refactor: add waveform, edit mode, artwork zone |
| `Stores/DownloadStore.swift` | Add `saveManualMetadata()` method |
| `Services/MetadataWriter.swift` | Add genre/comment to ffmpeg args |
