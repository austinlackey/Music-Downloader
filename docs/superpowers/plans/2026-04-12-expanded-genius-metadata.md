# Expanded Genius Metadata Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture all available metadata from Genius `/songs/:id` and embed it into MP3 files via TXXX custom ID3 frames for consumption by BingoBite.

**Architecture:** Expand the decode layer (GeniusModels) -> model layer (SongMetadata) -> service layer (GeniusService mapping) -> writer layer (MetadataWriter TXXX output) -> view layer (TrackInspectorSheet read-only display). Each layer only depends on the one before it.

**Tech Stack:** Swift, SwiftUI, Decodable, ffmpeg (ID3v2.3 via Process), macOS

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `Music Downloader/Models/GeniusModels.swift` | Modify | Add Decodable types for new Genius API fields |
| `Music Downloader/Models/SongMetadata.swift` | Modify | Add new metadata fields + supporting Codable structs |
| `Music Downloader/Services/GeniusService.swift` | Modify | Map expanded GeniusSongDetail into SongMetadata |
| `Music Downloader/Services/MetadataWriter.swift` | Modify | Rewrite to use standard ID3 + TXXX frames, remove buildComment |
| `Music Downloader/Views/Detail/TrackInspectorSheet.swift` | Modify | Add read-only rows, credits/relationships/media UI sections |

---

### Task 1: Expand GeniusSongDetail with new Decodable types

**Files:**
- Modify: `Music Downloader/Models/GeniusModels.swift:51-84`

- [ ] **Step 1: Add nested Decodable types inside GeniusSongDetail**

Add these types inside the `GeniusSongDetail` struct, after the existing `Description` type (after line 75):

```swift
nonisolated struct CustomPerformance: Decodable, Sendable {
    let label: String
    let artists: [GeniusHitResult.Artist]
}

nonisolated struct Media: Decodable, Sendable {
    let provider: String
    let url: String   // String, not URL — some Genius entries are malformed

    enum CodingKeys: String, CodingKey {
        case provider, url
    }
}

nonisolated struct SongRelationship: Decodable, Sendable {
    let relationshipType: String
    let songs: [RelatedSong]

    enum CodingKeys: String, CodingKey {
        case relationshipType = "relationship_type"
        case songs
    }
}

nonisolated struct RelatedSong: Decodable, Sendable {
    let id: Int
    let title: String
    let primaryArtist: GeniusHitResult.Artist

    enum CodingKeys: String, CodingKey {
        case id, title
        case primaryArtist = "primary_artist"
    }
}
```

- [ ] **Step 2: Add new stored properties to GeniusSongDetail**

Add these properties after the existing `description` property (after line 60):

```swift
let featuredArtists: [GeniusHitResult.Artist]?
let producerArtists: [GeniusHitResult.Artist]?
let writerArtists: [GeniusHitResult.Artist]?
let customPerformances: [CustomPerformance]?
let recordingLocation: String?
let language: String?
let media: [Media]?
let songRelationships: [SongRelationship]?
let titleWithFeatured: String?
```

- [ ] **Step 3: Update CodingKeys**

Replace the existing CodingKeys enum (lines 77-83) with:

```swift
enum CodingKeys: String, CodingKey {
    case id, title, album, url, description, language, media
    case primaryArtist = "primary_artist"
    case releaseDate = "release_date"
    case releaseDateForDisplay = "release_date_for_display"
    case songArtImageURL = "song_art_image_url"
    case featuredArtists = "featured_artists"
    case producerArtists = "producer_artists"
    case writerArtists = "writer_artists"
    case customPerformances = "custom_performances"
    case recordingLocation = "recording_location"
    case songRelationships = "song_relationships"
    case titleWithFeatured = "title_with_featured"
}
```

- [ ] **Step 4: Build to verify compilation**

Run: `cd "/Users/austinlackey/Documents/Digitally-Simple-Local/Music Downloader" && xcodebuild -scheme "Music Downloader" -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add "Music Downloader/Models/GeniusModels.swift"
git commit -m "feat: expand GeniusSongDetail with featured artists, producers, writers, credits, media, and relationships"
```

---

### Task 2: Expand SongMetadata model with new fields and supporting structs

**Files:**
- Modify: `Music Downloader/Models/SongMetadata.swift`

- [ ] **Step 1: Add supporting Codable structs**

Add these structs before the `SongMetadata` struct (before line 14), after the `AnnotationFact` struct:

```swift
/// A single performance credit (e.g., "Guitar" played by ["Person A"]).
nonisolated struct CreditEntry: Codable, Sendable, Hashable {
    let role: String
    let artists: [String]
}

/// A link to an external music service (Spotify, Apple Music, etc.).
nonisolated struct MediaLink: Codable, Sendable, Hashable {
    let provider: String
    let url: URL
}

/// A song relationship entry (samples, sampled_in, cover_of, etc.).
nonisolated struct SongRelationshipEntry: Codable, Sendable, Hashable {
    let type: String
    let title: String
    let artist: String
}
```

- [ ] **Step 2: Add new fields to SongMetadata**

Add these properties at the end of `SongMetadata`, after the `annotations` property (after line 25):

```swift
var featuredArtists: [String]?
var producerArtists: [String]?
var writerArtists: [String]?
var credits: [CreditEntry]?
var recordingLocation: String?
var language: String?
var releaseDate: String?           // Full "YYYY-MM-DD"
var mediaLinks: [MediaLink]?
var songRelationships: [SongRelationshipEntry]?
```

- [ ] **Step 3: Update the sample static property**

Replace the `sample` property (lines 28-48) with:

```swift
static let sample = SongMetadata(
    title: "Me at the zoo",
    artist: "jawed",
    album: "YouTube",
    year: "2005",
    coverArtURL: nil,
    geniusID: nil,
    geniusURL: nil,
    genre: "Entertainment",
    comments: "First YouTube video ever",
    songDescription: "The first video ever uploaded to YouTube.",
    annotations: [
        AnnotationFact(
            fragment: "All right, so here we are in front of the elephants",
            body: "Jawed Karim, one of YouTube's co-founders, narrates his visit to the San Diego Zoo.",
            authors: "Genius Editorial",
            verified: false,
            votes: 42
        )
    ],
    featuredArtists: nil,
    producerArtists: nil,
    writerArtists: nil,
    credits: nil,
    recordingLocation: nil,
    language: "en",
    releaseDate: "2005-04-23",
    mediaLinks: nil,
    songRelationships: nil
)
```

- [ ] **Step 4: Build to verify compilation**

Run: `cd "/Users/austinlackey/Documents/Digitally-Simple-Local/Music Downloader" && xcodebuild -scheme "Music Downloader" -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add "Music Downloader/Models/SongMetadata.swift"
git commit -m "feat: add CreditEntry, MediaLink, SongRelationshipEntry structs and expand SongMetadata"
```

---

### Task 3: Update GeniusService to map expanded fields into SongMetadata

**Files:**
- Modify: `Music Downloader/Services/GeniusService.swift:111-128`

- [ ] **Step 1: Replace the metadataFor method body**

Replace the `SongMetadata(...)` construction in `metadataFor(hit:token:)` (lines 117-128) with:

```swift
        // Map custom performances to CreditEntry
        let creditEntries: [CreditEntry]? = detail.customPerformances?.isEmpty == false
            ? detail.customPerformances!.map { perf in
                CreditEntry(role: perf.label, artists: perf.artists.map(\.name))
            }
            : nil

        // Map media to MediaLink (skip malformed URLs)
        let mediaLinkEntries: [MediaLink]? = detail.media?.compactMap { m in
            guard let url = URL(string: m.url) else { return nil }
            return MediaLink(provider: m.provider, url: url)
        }.nilIfEmpty

        // Map song relationships to flat entries
        let relationshipEntries: [SongRelationshipEntry]? = detail.songRelationships?
            .flatMap { rel in
                rel.songs.map { song in
                    SongRelationshipEntry(
                        type: rel.relationshipType,
                        title: song.title,
                        artist: song.primaryArtist.name
                    )
                }
            }.nilIfEmpty

        return SongMetadata(
            title: detail.title,
            artist: detail.primaryArtist.name,
            album: detail.album?.name,
            year: Self.extractYear(from: detail.releaseDate),
            coverArtURL: detail.album?.coverArtURL ?? detail.songArtImageURL ?? hit.songArtImageURL,
            geniusID: detail.id,
            geniusURL: detail.url ?? hit.url,
            songDescription: facts.description,
            annotations: facts.annotations.isEmpty ? nil : facts.annotations,
            featuredArtists: detail.featuredArtists?.map(\.name).nilIfEmpty,
            producerArtists: detail.producerArtists?.map(\.name).nilIfEmpty,
            writerArtists: detail.writerArtists?.map(\.name).nilIfEmpty,
            credits: creditEntries,
            recordingLocation: detail.recordingLocation,
            language: detail.language,
            releaseDate: detail.releaseDate,
            mediaLinks: mediaLinkEntries,
            songRelationships: relationshipEntries
        )
```

- [ ] **Step 2: Add Array helper extension**

Add this at the bottom of `GeniusService.swift` (after the closing brace of `GeniusError`):

```swift
extension Array {
    /// Returns nil if the array is empty, otherwise returns self.
    var nilIfEmpty: [Element]? {
        isEmpty ? nil : self
    }
}
```

- [ ] **Step 3: Build to verify compilation**

Run: `cd "/Users/austinlackey/Documents/Digitally-Simple-Local/Music Downloader" && xcodebuild -scheme "Music Downloader" -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add "Music Downloader/Services/GeniusService.swift"
git commit -m "feat: map expanded Genius song detail into SongMetadata with credits, media, relationships"
```

---

### Task 4: Rewrite MetadataWriter to use standard ID3 tags + TXXX frames

**Files:**
- Modify: `Music Downloader/Services/MetadataWriter.swift`

- [ ] **Step 1: Replace the metadata args construction**

Replace lines 40-54 (the `-metadata` args block and `buildComment` call) with:

```swift
        // --- Standard ID3 tags ---
        args += ["-metadata", "title=\(metadata.title)"]
        args += ["-metadata", "artist=\(metadata.artist)"]
        if let album = metadata.album, !album.isEmpty {
            args += ["-metadata", "album=\(album)"]
        }
        // Full release date, fall back to year
        let dateValue = metadata.releaseDate ?? metadata.year
        if let dateValue, !dateValue.isEmpty {
            args += ["-metadata", "date=\(dateValue)"]
        }
        if let genre = metadata.genre, !genre.isEmpty {
            args += ["-metadata", "genre=\(genre)"]
        }
        // album_artist = primary artist
        args += ["-metadata", "album_artist=\(metadata.artist)"]
        // composer = writers
        if let writers = metadata.writerArtists, !writers.isEmpty {
            args += ["-metadata", "composer=\(writers.joined(separator: "; "))"]
        }
        // language
        if let language = metadata.language, !language.isEmpty {
            args += ["-metadata", "language=\(language)"]
        }

        // --- TXXX custom frames ---
        Self.addTXXX(&args, key: "FEATURED_ARTISTS", jsonArray: metadata.featuredArtists)
        Self.addTXXX(&args, key: "PRODUCERS", jsonArray: metadata.producerArtists)
        Self.addTXXX(&args, key: "WRITERS", jsonArray: metadata.writerArtists)
        Self.addTXXXEncodable(&args, key: "CREDITS", value: metadata.credits)
        Self.addTXXX(&args, key: "RECORDING_LOCATION", string: metadata.recordingLocation)
        Self.addTXXXEncodable(&args, key: "MEDIA_LINKS", value: metadata.mediaLinks)
        Self.addTXXXEncodable(&args, key: "RELATIONSHIPS", value: metadata.songRelationships)
        if let geniusURL = metadata.geniusURL {
            Self.addTXXX(&args, key: "GENIUS_URL", string: geniusURL.absoluteString)
        }
        Self.addTXXX(&args, key: "DESCRIPTION", string: metadata.songDescription)
        Self.addTXXXEncodable(&args, key: "ANNOTATIONS", value: metadata.annotations)
        Self.addTXXX(&args, key: "USER_NOTES", string: metadata.comments)
```

- [ ] **Step 2: Add TXXX helper methods and remove buildComment**

Replace the `buildComment` method (lines 87-127) with these helper methods:

```swift
    /// Append a TXXX metadata arg with a plain string value.
    private static func addTXXX(_ args: inout [String], key: String, string: String?) {
        guard let string, !string.isEmpty else { return }
        args += ["-metadata", "\(key)=\(string)"]
    }

    /// Append a TXXX metadata arg with a JSON-encoded array of strings.
    private static func addTXXX(_ args: inout [String], key: String, jsonArray: [String]?) {
        guard let array = jsonArray, !array.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(array),
              let json = String(data: data, encoding: .utf8) else { return }
        args += ["-metadata", "\(key)=\(json)"]
    }

    /// Append a TXXX metadata arg with a JSON-encoded Encodable value.
    /// Skips nil values. For arrays, also skips empty.
    private static func addTXXXEncodable<T: Encodable>(_ args: inout [String], key: String, value: [T]?) {
        guard let value, !value.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else { return }
        args += ["-metadata", "\(key)=\(json)"]
    }
```

- [ ] **Step 3: Build to verify compilation**

Run: `cd "/Users/austinlackey/Documents/Digitally-Simple-Local/Music Downloader" && xcodebuild -scheme "Music Downloader" -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add "Music Downloader/Services/MetadataWriter.swift"
git commit -m "feat: rewrite MetadataWriter with standard ID3 + TXXX custom frames, remove buildComment"
```

---

### Task 5: Update TrackInspectorSheet with new read-only fields and sections

**Files:**
- Modify: `Music Downloader/Views/Detail/TrackInspectorSheet.swift`

- [ ] **Step 1: Add new read-only rows in the tags section**

In the `readOnlyFields` computed property (lines 191-222), add new rows after the genre row (after line 199). Insert before the `if let comments` block:

```swift
            if let featured = metadata?.featuredArtists, !featured.isEmpty {
                infoRow(label: "Featured", value: featured.joined(separator: ", "))
            }
            if let producers = metadata?.producerArtists, !producers.isEmpty {
                infoRow(label: "Producers", value: producers.joined(separator: ", "))
            }
            if let writers = metadata?.writerArtists, !writers.isEmpty {
                infoRow(label: "Writers", value: writers.joined(separator: ", "))
            }
            if let language = metadata?.language, !language.isEmpty {
                infoRow(label: "Language", value: language)
            }
            if let location = metadata?.recordingLocation, !location.isEmpty {
                infoRow(label: "Recorded", value: location)
            }
            if let releaseDate = metadata?.releaseDate, !releaseDate.isEmpty {
                infoRow(label: "Released", value: releaseDate)
            }
```

- [ ] **Step 2: Add credits disclosure group**

Add a new `creditsSection` computed property after the `songFactsSection`:

```swift
    // MARK: - Credits (view mode only)

    @ViewBuilder
    private var creditsSection: some View {
        if let credits = track.metadata?.credits, !credits.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Credits")

                DisclosureGroup("Performance Credits (\(credits.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(credits.enumerated()), id: \.offset) { _, credit in
                            HStack(alignment: .top, spacing: 6) {
                                Text(credit.role + ":")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 80, alignment: .trailing)
                                Text(credit.artists.joined(separator: ", "))
                                    .font(.caption)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption.weight(.medium))
            }
        }
    }
```

- [ ] **Step 3: Add song relationships disclosure group**

Add a new `relationshipsSection` computed property:

```swift
    // MARK: - Song Relationships (view mode only)

    @ViewBuilder
    private var relationshipsSection: some View {
        if let relationships = track.metadata?.songRelationships, !relationships.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Song Relationships")

                ForEach(Array(relationships.enumerated()), id: \.offset) { _, rel in
                    HStack(alignment: .top, spacing: 6) {
                        Text(Self.formatRelationshipType(rel.type) + ":")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 80, alignment: .trailing)
                        Text("\"\(rel.title)\" by \(rel.artist)")
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    /// Convert snake_case relationship types to readable labels.
    private static func formatRelationshipType(_ type: String) -> String {
        switch type {
        case "samples":         "Samples"
        case "sampled_in":      "Sampled in"
        case "interpolates":    "Interpolates"
        case "interpolated_by": "Interpolated by"
        case "cover_of":        "Cover of"
        case "covered_by":      "Covered by"
        case "remix_of":        "Remix of"
        case "remixed_by":      "Remixed by"
        case "live_version_of": "Live version of"
        case "performed_live_as": "Performed live as"
        default:                type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
```

- [ ] **Step 4: Add media links section**

Add a new `mediaLinksSection` computed property:

```swift
    // MARK: - Media Links (view mode only)

    @ViewBuilder
    private var mediaLinksSection: some View {
        if let links = track.metadata?.mediaLinks, !links.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Listen On")

                FlowLayout(spacing: 8) {
                    ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                        Link(destination: link.url) {
                            HStack(spacing: 4) {
                                Image(systemName: Self.iconForProvider(link.provider))
                                Text(Self.displayNameForProvider(link.provider))
                            }
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.secondary.opacity(0.1), in: Capsule())
                        }
                    }
                }
            }
        }
    }

    private static func iconForProvider(_ provider: String) -> String {
        switch provider.lowercased() {
        case "spotify":      "arrow.up.right.square"
        case "apple_music":  "arrow.up.right.square"
        case "youtube":      "play.rectangle"
        case "soundcloud":   "arrow.up.right.square"
        default:             "link"
        }
    }

    private static func displayNameForProvider(_ provider: String) -> String {
        switch provider.lowercased() {
        case "spotify":      "Spotify"
        case "apple_music":  "Apple Music"
        case "youtube":      "YouTube"
        case "soundcloud":   "SoundCloud"
        default:             provider.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
```

- [ ] **Step 5: Add FlowLayout helper**

Add a simple `FlowLayout` at the bottom of the file (after the `HitRow` struct), since SwiftUI doesn't have a built-in flow layout:

```swift
// MARK: - Flow layout for media link pills

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(in: proposal.width ?? 0, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(in: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(in width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxWidth = max(maxWidth, x - spacing)
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), origins)
    }
}
```

- [ ] **Step 6: Wire new sections into the ScrollView body**

In the `body` computed property, inside the `if !isEditing` block (lines 69-77), add the new sections after `songFactsSection`:

```swift
                if !isEditing {
                    VStack(alignment: .leading, spacing: 16) {
                        creditsSection
                        songFactsSection
                        relationshipsSection
                        mediaLinksSection
                        alternativesSection
                        researchSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
```

- [ ] **Step 7: Update saveEdits to preserve new fields**

In the `saveEdits` method (lines 462-490), update the `SongMetadata` construction to carry over the new fields from the existing track metadata:

```swift
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
                ? nil : editComments.trimmingCharacters(in: .whitespacesAndNewlines),
            songDescription: track.metadata?.songDescription,
            annotations: track.metadata?.annotations,
            featuredArtists: track.metadata?.featuredArtists,
            producerArtists: track.metadata?.producerArtists,
            writerArtists: track.metadata?.writerArtists,
            credits: track.metadata?.credits,
            recordingLocation: track.metadata?.recordingLocation,
            language: track.metadata?.language,
            releaseDate: track.metadata?.releaseDate,
            mediaLinks: track.metadata?.mediaLinks,
            songRelationships: track.metadata?.songRelationships
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
```

- [ ] **Step 8: Build to verify compilation**

Run: `cd "/Users/austinlackey/Documents/Digitally-Simple-Local/Music Downloader" && xcodebuild -scheme "Music Downloader" -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 9: Commit**

```bash
git add "Music Downloader/Views/Detail/TrackInspectorSheet.swift"
git commit -m "feat: add read-only credits, relationships, and media links sections to track inspector"
```

---

### Task 6: End-to-end verification

- [ ] **Step 1: Full clean build**

Run: `cd "/Users/austinlackey/Documents/Digitally-Simple-Local/Music Downloader" && xcodebuild -scheme "Music Downloader" -destination 'platform=macOS' clean build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 2: Manual smoke test**

1. Launch the app
2. Download a well-known song (something with featured artists, producers, and samples — e.g., a hip-hop track)
3. Run enrichment
4. Open the track inspector and verify:
   - New read-only rows appear (Featured, Producers, Writers, Language, Recorded, Released)
   - Credits disclosure group expands to show performance credits
   - Song Relationships disclosure group shows sample/interpolation info
   - Media Links section shows clickable Spotify/Apple Music/YouTube pills
5. Inspect the MP3 with `ffprobe` to verify TXXX frames:
   ```bash
   ffprobe -show_entries format_tags -of default=noprint_wrappers=1 "/path/to/enriched.mp3"
   ```
   Expected: TXXX frames visible with keys like FEATURED_ARTISTS, PRODUCERS, WRITERS, etc.

- [ ] **Step 3: Verify edit mode preserves new fields**

1. Open inspector for an enriched track
2. Click Edit, change the title, click Save
3. Re-open inspector — verify all new read-only fields are still present
4. Run ffprobe again — verify TXXX frames still written

- [ ] **Step 4: Final commit (if any fixups needed)**

```bash
git add -A
git commit -m "fix: address issues found during smoke testing"
```
