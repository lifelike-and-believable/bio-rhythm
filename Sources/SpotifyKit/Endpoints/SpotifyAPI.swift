import Foundation
import HRDJCore

/// Request machinery for `api.spotify.com`: rate limiting, bearer tokens, and
/// the status-code mapping that SPEC.md §11.4 branches on.
///
/// Retries exactly one thing — a 401, once, after forcing a token refresh.
/// Everything else is surfaced to the caller, because the commit retry
/// schedule (§6.7) lives in the control layer and a second retry policy
/// hiding down here would fight it.
public struct SpotifyAPI: Sendable {
    public static let baseURL = "https://api.spotify.com"

    private let transport: any HTTPTransport
    private let refresher: TokenRefresher
    private let limiter: RateLimiter

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        refresher: TokenRefresher,
        limiter: RateLimiter = RateLimiter()
    ) {
        self.transport = transport
        self.refresher = refresher
        self.limiter = limiter
    }

    @discardableResult
    public func send(
        method: String,
        path: String,
        query: [String: String] = [:],
        body: Data? = nil
    ) async throws -> HTTPResponse {
        let response = try await attempt(method: method, path: path, query: query, body: body)

        if response.status == 401 {
            // The proactive refresh (§9.3) should make this rare. When it does
            // happen, one forced refresh and one retry; a second 401 is a real
            // authorization problem, not a stale token.
            _ = try await refresher.forceRefresh()
            let retried = try await attempt(method: method, path: path, query: query, body: body)
            return try validate(retried)
        }

        return try validate(response)
    }

    private func attempt(
        method: String,
        path: String,
        query: [String: String],
        body: Data?
    ) async throws -> HTTPResponse {
        let wait = await limiter.reserve()
        if wait > .zero {
            try await Task.sleep(for: wait)
        }

        let token = try await refresher.accessToken()

        guard let url = Self.url(path: path, query: query) else {
            throw SpotifyError.decoding("malformed URL for \(path)")
        }

        var headers = ["Authorization": "Bearer \(token)"]
        if body != nil {
            headers["Content-Type"] = "application/json"
        }

        let response = try await transport.send(
            HTTPRequest(method: method, url: url, headers: headers, body: body)
        )

        if response.status == 401 {
            await refresher.invalidate(token)
        }
        if response.status == 429 {
            // §9.4: honour Retry-After absolutely. Recording it on the limiter
            // makes every subsequent caller wait too, not just this one.
            await limiter.penalise(retryAfter: response.retryAfter)
        }
        return response
    }

    private func validate(_ response: HTTPResponse) throws -> HTTPResponse {
        switch response.status {
        case 200..<300:
            return response
        case 401:
            throw SpotifyError.unauthorized
        case 403:
            throw SpotifyError.forbidden(body: response.bodyText)
        case 404:
            throw SpotifyError.notFound(body: response.bodyText)
        case 429:
            throw SpotifyError.rateLimited(retryAfter: response.retryAfter)
        default:
            throw SpotifyError.server(status: response.status, body: response.bodyText)
        }
    }

    static func url(path: String, query: [String: String]) -> String? {
        var components = URLComponents(string: baseURL + path)
        if !query.isEmpty {
            components?.queryItems = query.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components?.url?.absoluteString
    }

    func decode<T: Decodable>(_ type: T.Type, from response: HTTPResponse) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: response.body)
        } catch {
            throw SpotifyError.decoding("\(type): \(error)")
        }
    }
}
