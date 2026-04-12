import Foundation

// MARK: - /search response

nonisolated struct GeniusSearchResponse: Decodable, Sendable {
    struct Meta: Decodable, Sendable { let status: Int }
    struct Hit: Decodable, Sendable { let result: GeniusHitResult }
    struct Payload: Decodable, Sendable { let hits: [Hit] }
    let meta: Meta
    let response: Payload
}

/// Minimal projection of a Genius search hit. Kept Codable so we can persist
/// the top-5 alternatives alongside the Track snapshot.
nonisolated struct GeniusHitResult: Codable, Sendable, Hashable, Identifiable {
    let id: Int
    let title: String
    let fullTitle: String
    let primaryArtist: Artist
    let songArtImageURL: URL?
    let songArtImageThumbnailURL: URL?
    let url: URL?

    nonisolated struct Artist: Codable, Sendable, Hashable {
        let id: Int
        let name: String
        let imageURL: URL?

        enum CodingKeys: String, CodingKey {
            case id, name
            case imageURL = "image_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, title, url
        case fullTitle = "full_title"
        case primaryArtist = "primary_artist"
        case songArtImageURL = "song_art_image_url"
        case songArtImageThumbnailURL = "song_art_image_thumbnail_url"
    }
}

// MARK: - /songs/:id response

nonisolated struct GeniusSongResponse: Decodable, Sendable {
    struct Payload: Decodable, Sendable { let song: GeniusSongDetail }
    let response: Payload
}

nonisolated struct GeniusSongDetail: Decodable, Sendable {
    let id: Int
    let title: String
    let primaryArtist: GeniusHitResult.Artist
    let album: Album?
    let releaseDate: String?               // "YYYY-MM-DD"
    let releaseDateForDisplay: String?
    let songArtImageURL: URL?
    let url: URL?
    let description: Description?
    let featuredArtists: [GeniusHitResult.Artist]?
    let producerArtists: [GeniusHitResult.Artist]?
    let writerArtists: [GeniusHitResult.Artist]?
    let customPerformances: [CustomPerformance]?
    let recordingLocation: String?
    let language: String?
    let media: [Media]?
    let songRelationships: [SongRelationship]?
    let titleWithFeatured: String?

    nonisolated struct Album: Decodable, Sendable {
        let id: Int
        let name: String
        let coverArtURL: URL?

        enum CodingKeys: String, CodingKey {
            case id, name
            case coverArtURL = "cover_art_url"
        }
    }

    nonisolated struct Description: Decodable, Sendable {
        let plain: String
    }

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
}

// MARK: - /referents response

nonisolated struct GeniusReferentsResponse: Decodable, Sendable {
    struct Payload: Decodable, Sendable { let referents: [GeniusReferent] }
    let response: Payload
}

nonisolated struct GeniusReferent: Decodable, Sendable {
    let fragment: String
    let classification: String
    let annotations: [GeniusAnnotation]
}

nonisolated struct GeniusAnnotation: Decodable, Sendable {
    let body: Body
    let verified: Bool
    let votesTotal: Int
    let authors: [Author]

    nonisolated struct Body: Decodable, Sendable { let plain: String }
    nonisolated struct Author: Decodable, Sendable {
        let user: User
        nonisolated struct User: Decodable, Sendable { let name: String }
    }

    enum CodingKeys: String, CodingKey {
        case body, verified, authors
        case votesTotal = "votes_total"
    }
}
