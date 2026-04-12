import Foundation

/// A single Genius annotation mapped to a lyrics fragment.
nonisolated struct AnnotationFact: Codable, Sendable, Hashable {
    let fragment: String    // lyrics text being annotated
    let body: String        // annotation text
    let authors: String     // comma-separated author names
    let verified: Bool      // artist-verified annotation?
    let votes: Int          // total votes
}

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

/// Resolved metadata for a single track, typically pulled from Genius and
/// injected into the mp3 via ffmpeg. Persisted with the Track snapshot.
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
    var songDescription: String?
    var annotations: [AnnotationFact]?
    var featuredArtists: [String]?
    var producerArtists: [String]?
    var writerArtists: [String]?
    var credits: [CreditEntry]?
    var recordingLocation: String?
    var language: String?
    var releaseDate: String?           // Full "YYYY-MM-DD"
    var mediaLinks: [MediaLink]?
    var songRelationships: [SongRelationshipEntry]?

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
}
