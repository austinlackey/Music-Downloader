import Foundation

/// HTTP client for https://api.genius.com — search, song detail, cover art.
/// Non-MainActor actor so it can be called from any context without blocking
/// the UI. All mutating state stays inside the actor.
actor GeniusService {
    private let session: URLSession
    private let base = URL(string: "https://api.genius.com")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Endpoints

    /// Up to ~10 search hits for a freeform query. The query is pre-cleaned
    /// to strip common yt-dlp title noise ("Official Video", "[HD]", etc.).
    func search(query: String, token: String, stripNoise: Bool = true) async throws -> [GeniusHitResult] {
        try requireToken(token)
        let cleaned = stripNoise ? Self.cleanQuery(query) : query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        var comps = URLComponents(
            url: base.appendingPathComponent("search"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [URLQueryItem(name: "q", value: cleaned)]

        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20

        let (data, resp) = try await session.data(for: req)
        try Self.validate(resp, data: data)

        let decoded = try JSONDecoder().decode(GeniusSearchResponse.self, from: data)
        return decoded.response.hits.map(\.result)
    }

    /// Fetch full song details (album, release date) for a known hit id.
    func songDetail(id: Int, token: String) async throws -> GeniusSongDetail {
        try requireToken(token)
        var comps = URLComponents(
            url: base.appendingPathComponent("songs/\(id)"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [URLQueryItem(name: "text_format", value: "plain")]

        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20

        let (data, resp) = try await session.data(for: req)
        try Self.validate(resp, data: data)

        let decoded = try JSONDecoder().decode(GeniusSongResponse.self, from: data)
        return decoded.response.song
    }

    /// Fetch referents (annotations) for a song.
    func fetchReferents(songID: Int, token: String) async throws -> [GeniusReferent] {
        try requireToken(token)
        var comps = URLComponents(
            url: base.appendingPathComponent("referents"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [
            URLQueryItem(name: "song_id", value: String(songID)),
            URLQueryItem(name: "text_format", value: "plain"),
            URLQueryItem(name: "per_page", value: "50"),
        ]

        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20

        let (data, resp) = try await session.data(for: req)
        try Self.validate(resp, data: data)

        let decoded = try JSONDecoder().decode(GeniusReferentsResponse.self, from: data)
        return decoded.response.referents
    }

    /// Download cover art image bytes. No auth required for the CDN.
    func fetchCoverArt(url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        let (data, resp) = try await session.data(for: req)
        try Self.validate(resp, data: data)
        return data
    }

    // MARK: - High-level convenience

    /// Search → pick first hit → fetch details → return a ready `SongMetadata`
    /// plus the full top-N hits so the UI can offer alternatives.
    ///
    /// Throws `GeniusError.noMatch` if there are zero hits.
    func resolve(
        query: String,
        token: String
    ) async throws -> (metadata: SongMetadata, alternatives: [GeniusHitResult]) {
        let hits = try await search(query: query, token: token)
        guard let top = hits.first else { throw GeniusError.noMatch }
        let metadata = try await metadataFor(hit: top, token: token)
        return (metadata, Array(hits.prefix(5)))
    }

    /// Build full `SongMetadata` for a specific hit by calling `/songs/:id`
    /// and fetching annotations in parallel.
    func metadataFor(hit: GeniusHitResult, token: String) async throws -> SongMetadata {
        let detail = try await songDetail(id: hit.id, token: token)

        // Fetch referents in parallel (non-fatal).
        let facts = await fetchFactsQuietly(songID: hit.id, detail: detail, token: token)

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
    }

    /// Fetch and process song facts. Never throws — returns empty on failure.
    private func fetchFactsQuietly(
        songID: Int,
        detail: GeniusSongDetail,
        token: String
    ) async -> (description: String?, annotations: [AnnotationFact]) {
        let desc = detail.description?.plain
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var annotationFacts: [AnnotationFact] = []
        do {
            let referents = try await fetchReferents(songID: songID, token: token)
            let filtered = referents.filter { $0.classification == "verified" || $0.classification == "accepted" }
            let mapped: [AnnotationFact] = filtered.flatMap { ref in
                ref.annotations.map { ann in
                    AnnotationFact(
                        fragment: ref.fragment,
                        body: ann.body.plain.trimmingCharacters(in: .whitespacesAndNewlines),
                        authors: ann.authors.map(\.user.name).joined(separator: ", "),
                        verified: ann.verified,
                        votes: ann.votesTotal
                    )
                }
            }
            // Verified first (by votes desc), then accepted (by votes desc). Cap at 20.
            annotationFacts = mapped.sorted { lhs, rhs in
                if lhs.verified != rhs.verified { return lhs.verified }
                return lhs.votes > rhs.votes
            }.prefix(20).map { $0 }
        } catch {
            // Non-fatal — metadata still gets basic fields.
        }

        let cleanDesc = (desc?.isEmpty ?? true) ? nil : desc
        return (cleanDesc, annotationFacts)
    }

    // MARK: - Helpers

    private func requireToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GeniusError.missingToken }
    }

    private static func validate(_ resp: URLResponse, data: Data) throws {
        guard let http = resp as? HTTPURLResponse else {
            throw GeniusError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300: return
        case 401:       throw GeniusError.unauthorized
        case 429:       throw GeniusError.rateLimited
        default:        throw GeniusError.httpStatus(http.statusCode)
        }
    }

    private static func extractYear(from date: String?) -> String? {
        guard let date, date.count >= 4 else { return nil }
        return String(date.prefix(4))
    }

    /// Strip parenthesised/bracketed text and common yt-dlp noise so Genius
    /// search matches better.  e.g. "Song (feat. X) [Official Video]" → "Song"
    nonisolated static func cleanQuery(_ raw: String) -> String {
        var s = raw
        // Remove everything inside parentheses and brackets (greedy per pair).
        s = s.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*\[[^\]]*\]"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated enum GeniusError: LocalizedError {
    case missingToken
    case unauthorized
    case rateLimited
    case invalidResponse
    case httpStatus(Int)
    case noMatch

    var errorDescription: String? {
        switch self {
        case .missingToken:       "Set your Genius API token in Settings first."
        case .unauthorized:       "Genius rejected the token. Check it in Settings."
        case .rateLimited:        "Rate-limited by Genius. Try again in a moment."
        case .invalidResponse:    "Unexpected response from Genius."
        case .httpStatus(let c):  "Genius returned HTTP \(c)."
        case .noMatch:            "No Genius match found."
        }
    }
}

extension Array {
    /// Returns nil if the array is empty, otherwise returns self.
    nonisolated var nilIfEmpty: [Element]? {
        isEmpty ? nil : self
    }
}
