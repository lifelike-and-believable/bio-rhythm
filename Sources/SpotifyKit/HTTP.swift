import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A minimal HTTP surface, so that everything above it can be tested without a
/// network. `URLSession` appears in exactly one type in this package.
public struct HTTPRequest: Sendable {
    public var method: String
    public var url: String
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: String, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    /// Keys are lower-cased on construction; look them up with `header(_:)`.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    public var bodyText: String {
        String(data: body, encoding: .utf8) ?? ""
    }

    /// `Retry-After` in seconds. Spotify sends the integer-seconds form.
    public var retryAfter: Duration? {
        guard let raw = header("Retry-After"), let seconds = Int(raw.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return .seconds(seconds)
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let url = URL(string: request.url) else {
            throw SpotifyError.decoding("malformed URL: \(request.url)")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw SpotifyError.transport(message: String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw SpotifyError.decoding("non-HTTP response")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key] = value
            }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}
