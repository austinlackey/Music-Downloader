# Expanded Genius Metadata — Design Spec

## Overview

Expand the Genius metadata pipeline to capture all available fields from the `/songs/:id` endpoint and embed them into downloaded tracks using TXXX custom ID3 frames. The structured metadata will be consumed by the BingoBite app, so each data category gets its own independently-readable TXXX frame.

## Decisions

- New fields are **read-only** in the inspector UI (edit mode unchanged)
- Song relationships: shown in UI **and** embedded in TXXX frame
- Media links: shown as clickable links in UI **and** embedded in TXXX frame
- All structured data uses **TXXX custom frames** (one per category, JSON-encoded where arrays/objects)
- The `comment` ID3 tag is **no longer written**; `buildComment` is removed
- User notes move to `TXXX:USER_NOTES` (separate from structured data)

## Section 1: Genius API Data Capture

Expand `GeniusSongDetail` to decode additional fields from `/songs/:id`:

| Field | Genius JSON key | Swift type |
|-------|----------------|------------|
| Featured artists | `featured_artists` | `[Artist]` |
| Producer artists | `producer_artists` | `[Artist]` |
| Writer artists | `writer_artists` | `[Artist]` |
| Custom performances | `custom_performances` | `[CustomPerformance]` — `label` (role) + `artists` array |
| Recording location | `recording_location` | `String?` |
| Language | `language` | `String?` |
| Media | `media` | `[Media]` — `provider` + `url` |
| Song relationships | `song_relationships` | `[SongRelationship]` — `relationship_type` + `songs` array |
| Full release date | `release_date` | Already captured, stop truncating to year-only |
| Title with featured | `title_with_featured` | `String?` |

New nested Decodable types inside `GeniusSongDetail`:
- `CustomPerformance` — `{ label: String, artists: [Artist] }`
- `Media` — `{ provider: String, url: URL }`
- `SongRelationship` — `{ relationshipType: String, songs: [RelatedSong] }` where `RelatedSong` has `title`, `primaryArtist`

## Section 2: SongMetadata Model Expansion

New fields on `SongMetadata`:

```swift
var featuredArtists: [String]?
var producerArtists: [String]?
var writerArtists: [String]?
var credits: [CreditEntry]?
var recordingLocation: String?
var language: String?
var releaseDate: String?              // Full "YYYY-MM-DD"
var mediaLinks: [MediaLink]?
var songRelationships: [SongRelationshipEntry]?
```

New supporting Codable structs:
- `CreditEntry` — `{ role: String, artists: [String] }`
- `MediaLink` — `{ provider: String, url: URL }`
- `SongRelationshipEntry` — `{ type: String, title: String, artist: String }`

The existing `year` field stays, derived from `releaseDate` (first 4 chars) for backward compat with filename templates. `releaseDate` holds the full date.

`GeniusService.metadataFor` maps from the expanded `GeniusSongDetail` into these fields, flattening artist objects into `[String]` name arrays.

## Section 3: ID3 Tag Writing (TXXX Frames)

Three tiers of metadata written by `MetadataWriter`:

### Standard ID3 tags

| Tag | Source |
|-----|--------|
| `title` | title |
| `artist` | artist |
| `album` | album |
| `date` | full releaseDate (YYYY-MM-DD), falls back to year |
| `genre` | genre |
| `album_artist` | artist (primary) — new |
| `composer` | writerArtists joined by "; " — new |
| `language` | language — new |

### TXXX custom frames (JSON-encoded where arrays/objects)

| Frame | Content |
|-------|---------|
| `TXXX:FEATURED_ARTISTS` | JSON array of strings |
| `TXXX:PRODUCERS` | JSON array of strings |
| `TXXX:WRITERS` | JSON array of strings |
| `TXXX:CREDITS` | JSON array of `{role, artists}` |
| `TXXX:RECORDING_LOCATION` | Plain string |
| `TXXX:MEDIA_LINKS` | JSON array of `{provider, url}` |
| `TXXX:RELATIONSHIPS` | JSON array of `{type, title, artist}` |
| `TXXX:GENIUS_URL` | Plain string URL |
| `TXXX:DESCRIPTION` | Plain string (song description) |
| `TXXX:ANNOTATIONS` | JSON array of annotation objects |
| `TXXX:USER_NOTES` | Plain string (user's manual comments) |

ffmpeg syntax for TXXX: `-metadata "TXXX=KEY=value"`

The `comment` tag is no longer written. `buildComment` method is removed.

## Section 4: Inspector UI Changes

### Tags section (read-only mode)

New rows below existing ones, only shown when non-nil/non-empty:

```
Featured:    Artist B, Artist C
Producers:   Metro Boomin, Wheezy
Writers:     Writer X, Writer Y
Language:    en
Recorded:    Conway Studios, LA
Released:    2023-05-15
```

Not editable — edit mode stays as-is (title, artist, album, year, genre, comments).

### Credits section

New collapsible `DisclosureGroup("Credits")` below tags, shown when `credits` is non-empty:
```
Guitar: Person A
Background Vocals: Person B, Person C
Mixing: Engineer X
```

### Song Relationships section

New collapsible `DisclosureGroup("Song Relationships")` alongside Song Facts:
```
Samples: "Original Song" by Original Artist
Sampled in: "Other Track" by Other Artist
```

### Media Links section

Row of small clickable links below the Genius URL, shown when `mediaLinks` is non-empty. Each opens via `Link(destination:)`.

### Edit mode

No changes. The `comments` field in edit mode maps to `TXXX:USER_NOTES`.

## Files Modified

1. `Models/GeniusModels.swift` — Expand `GeniusSongDetail` with new Decodable types
2. `Models/SongMetadata.swift` — Add new fields + supporting structs (`CreditEntry`, `MediaLink`, `SongRelationshipEntry`)
3. `Services/GeniusService.swift` — Map expanded detail fields into `SongMetadata`
4. `Services/MetadataWriter.swift` — Write standard tags + TXXX frames, remove `buildComment`
5. `Views/Detail/TrackInspectorSheet.swift` — Add read-only rows, credits/relationships/media sections
