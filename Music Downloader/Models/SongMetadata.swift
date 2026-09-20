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

/// A user-defined metadata field, e.g. `name: "Movie", value: "Top Gun"`.
///
/// Genius supplies what Genius knows; this is for everything else a set needs —
/// the film a soundtrack came from, its year, its director. Mirrored in
/// BingoBite as `Shared/Models/CustomField.swift`, and carried between the two
/// apps as a JSON array in the file's `CUSTOM_FIELDS` tag, so the property
/// names here are a cross-app contract.
///
/// Ordered array rather than a dictionary: the order is the column order in the
/// metadata table and the line order on a printed card.
nonisolated struct CustomField: Codable, Sendable, Hashable, Identifiable {
    var name: String
    var value: String

    var id: String { name }
}

extension Array where Element == CustomField {
    /// Case-insensitive — a field typed "movie" in one app and "Movie" in the
    /// other is the same field to a person.
    func value(named name: String) -> String? {
        let wanted = name.lowercased()
        guard let match = first(where: { $0.name.lowercased() == wanted }) else { return nil }
        return match.value.isEmpty ? nil : match.value
    }

    /// Sets the value for `name`, appending when new and removing when empty.
    /// Existing order is preserved.
    mutating func setValue(_ value: String, named name: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = name.lowercased()
        if let index = firstIndex(where: { $0.name.lowercased() == wanted }) {
            if trimmed.isEmpty { remove(at: index) } else { self[index].value = trimmed }
        } else if !trimmed.isEmpty {
            append(CustomField(name: name, value: trimmed))
        }
    }
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
    /// User-defined fields. Declared last, and defaulted, so every existing
    /// memberwise-init call site keeps compiling unchanged.
    var customFields: [CustomField]? = nil

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
