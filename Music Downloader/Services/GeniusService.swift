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
    func search(query: String, token: String) async throws -> [GeniusHitResult] {
        try requireToken(token)
        let cleaned = Self.cleanQuery(query)
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

    /// Build full `SongMetadata` for a specific hit by calling `/songs/:id`.
    func metadataFor(hit: GeniusHitResult, token: String) async throws -> SongMetadata {
        let detail = try await songDetail(id: hit.id, token: token)
        return SongMetadata(
            title: detail.title,
            artist: detail.primaryArtist.name,
            album: detail.album?.name,
            year: Self.extractYear(from: detail.releaseDate),
            coverArtURL: detail.album?.coverArtURL ?? detail.songArtImageURL ?? hit.songArtImageURL,
            geniusID: detail.id,
            geniusURL: detail.url ?? hit.url
        )
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

    /// Strip common yt-dlp/YouTube title suffixes so Genius search matches better.
    nonisolated static func cleanQuery(_ raw: String) -> String {
        var s = raw
        let patterns: [String] = [
            #"\s*\(.*?official.*?\)"#, #"\s*\[.*?official.*?\]"#,
            #"\s*\(.*?lyrics?.*?\)"#,  #"\s*\[.*?lyrics?.*?\]"#,
            #"\s*\(.*?audio.*?\)"#,    #"\s*\[.*?audio.*?\]"#,
            #"\s*\(.*?music video.*?\)"#, #"\s*\[.*?music video.*?\]"#,
            #"\s*\(.*?lyric video.*?\)"#, #"\s*\[.*?lyric video.*?\]"#,
            #"\s*\(.*?visualizer.*?\)"#, #"\s*\[.*?visualizer.*?\]"#,
            #"\s*\(.*?hd.*?\)"#,       #"\s*\[.*?hd.*?\]"#,
            #"\s*\(.*?4k.*?\)"#,       #"\s*\[.*?4k.*?\]"#,
            #"\s*\(.*?remaster(ed)?.*?\)"#, #"\s*\[.*?remaster(ed)?.*?\]"#,
        ]
        for p in patterns {
            s = s.replacingOccurrences(
                of: p,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
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
