// Tenor.swift — om-cmdk lane: Tenor GIF search client (v2 API).
// BYO API key (Settings → GIFs); no key = picker shows the off-state and
// no request is ever made. Pure URL builders + decoders; the fetcher is
// injectable so tests never touch the network.
import Foundation

/// One GIF hit: thumbnail for the grid, full-size URL sent to the chat.
public struct TenorGIF: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let previewURL: String
    public let fullURL: String

    public init(id: String, title: String, previewURL: String, fullURL: String) {
        self.id = id
        self.title = title
        self.previewURL = previewURL
        self.fullURL = fullURL
    }
}

public enum TenorError: Error, Sendable, Equatable {
    case missingKey
    case badResponse(String)
    case network(String)
}

public enum TenorClient {
    /// UserDefaults key for the BYO Tenor API key (Settings → GIFs).
    public static let settingsKey = "tenorAPIKey"

    /// Stored key, trimmed; empty when the user never set one.
    public static func storedKey(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: settingsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Async bytes fetch; default is a plain URLSession data task.
    public typealias Fetcher = @Sendable (URL) async throws -> (Data, URLResponse)

    public static func liveFetcher(url: URL) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(from: url)
    }

    /// v2 search URL. Returns nil for an empty key or unencodable query.
    public static func searchURL(query: String, apiKey: String, limit: Int = 24) -> URL? {
        url(path: "search", apiKey: apiKey, limit: limit, extra: [("q", query)])
    }

    /// v2 trending URL (picker landing page). Nil for an empty key.
    public static func featuredURL(apiKey: String, limit: Int = 24) -> URL? {
        url(path: "featured", apiKey: apiKey, limit: limit, extra: [])
    }

    private static func url(path: String, apiKey: String, limit: Int, extra: [(String, String)]) -> URL? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        var comps = URLComponents(string: "https://tenor.googleapis.com/v2/\(path)")
        var items = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 50)))),
            URLQueryItem(name: "media_filter", value: "gif,tinygif"),
            URLQueryItem(name: "contentfilter", value: "medium"),
        ]
        for (k, v) in extra { items.append(URLQueryItem(name: k, value: v)) }
        comps?.queryItems = items
        return comps?.url
    }

    /// Search GIFs. Throws `.missingKey` without a key (no request made).
    public static func search(
        query: String, apiKey: String, limit: Int = 24,
        fetcher: Fetcher = liveFetcher(url:)
    ) async throws -> [TenorGIF] {
        guard let url = searchURL(query: query, apiKey: apiKey, limit: limit) else {
            throw TenorError.missingKey
        }
        return try await fetch(url: url, fetcher: fetcher)
    }

    /// Trending GIFs for the picker landing page.
    public static func featured(
        apiKey: String, limit: Int = 24,
        fetcher: Fetcher = liveFetcher(url:)
    ) async throws -> [TenorGIF] {
        guard let url = featuredURL(apiKey: apiKey, limit: limit) else {
            throw TenorError.missingKey
        }
        return try await fetch(url: url, fetcher: fetcher)
    }

    private static func fetch(url: URL, fetcher: Fetcher) async throws -> [TenorGIF] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await fetcher(url)
        } catch {
            throw TenorError.network(String(describing: error))
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw TenorError.badResponse("HTTP \(http.statusCode)")
        }
        do {
            return try decode(data)
        } catch {
            throw TenorError.badResponse(String(describing: error))
        }
    }

    /// Decode a v2 search/featured payload. Results missing both playable
    /// formats are skipped.
    public static func decode(_ data: Data) throws -> [TenorGIF] {
        let payload = try JSONDecoder().decode(TenorPayload.self, from: data)
        return payload.results.compactMap { r in
            let formats = r.media_formats
            guard let full = formats["gif"]?.url ?? formats["mediumgif"]?.url else { return nil }
            let preview = formats["tinygif"]?.url ?? full
            return TenorGIF(id: r.id, title: r.title, previewURL: preview, fullURL: full)
        }
    }
}

// MARK: - Wire format (Tenor API v2)

private struct TenorPayload: Decodable {
    let results: [TenorResult]
}

private struct TenorResult: Decodable {
    let id: String
    let title: String
    let media_formats: [String: TenorFormat]
}

private struct TenorFormat: Decodable {
    let url: String
}
