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

    nonisolated struct Album: Decodable, Sendable {
        let id: Int
        let name: String
        let coverArtURL: URL?

        enum CodingKeys: String, CodingKey {
            case id, name
            case coverArtURL = "cover_art_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, title, album, url
        case primaryArtist = "primary_artist"
        case releaseDate = "release_date"
        case releaseDateForDisplay = "release_date_for_display"
        case songArtImageURL = "song_art_image_url"
    }
}
