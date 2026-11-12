// HTTPTypes.swift - Request/response values used by the v2 network stack.

import Foundation

// MARK: - Request

/// An HTTP request as it travels through the interceptor chain.
///
/// Value type on purpose: every interceptor gets a copy, so adapting a request
/// (adding a UA, a cookie, a referer) can never race with another source's
/// request on the same connection pool.
struct HTTPRequest: Sendable, Hashable {

    var url: URL
    var method: String
    var headers: [String: String]
    var body: Data?
    /// Per-request override of the client's default timeout.
    var timeout: TimeInterval?

    init(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    /// - Throws: `HTTPError.invalidURL` when the string does not parse.
    init(
        urlString: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval? = nil
    ) throws {
        guard let url = URL(string: urlString) else {
            throw HTTPError.invalidURL(urlString)
        }
        self.init(url: url, method: method, headers: headers, body: body, timeout: timeout)
    }

    /// Header lookup that ignores case, as HTTP requires.
    func header(_ name: String) -> String? {
        let target = name.lowercased()
        return headers.first { $0.key.lowercased() == target }?.value
    }

    /// Set a header, replacing any existing casing variant.
    mutating func setHeader(_ name: String, _ value: String) {
        let target = name.lowercased()
        headers = headers.filter { $0.key.lowercased() != target }
        headers[name] = value
    }

    mutating func removeHeader(_ name: String) {
        let target = name.lowercased()
        headers = headers.filter { $0.key.lowercased() != target }
    }

    /// Host used for per-host rate limiting and cookie scoping.
    ///
    /// Lowercased: `URL.host()` preserves the case the caller typed, and
    /// `Example.com` and `example.com` must share one rate-limit bucket.
    var host: String { (url.host() ?? url.absoluteString).lowercased() }

    /// Origin (`scheme://host[:port]`) used to build absolute image URLs.
    var origin: String {
        guard let scheme = url.scheme, let host = url.host() else { return "" }
        let lowercasedHost = host.lowercased()
        if let port = url.port {
            return "\(scheme)://\(lowercasedHost):\(port)"
        }
        return "\(scheme)://\(lowercasedHost)"
    }
}

// MARK: - Response

/// A completed HTTP exchange.
struct HTTPResponse: Sendable {

    let request: HTTPRequest
    let url: URL
    let statusCode: Int
    let headers: [String: String]
    let data: Data

    var isSuccess: Bool { (200..<300).contains(statusCode) }

    func header(_ name: String) -> String? {
        let target = name.lowercased()
        return headers.first { $0.key.lowercased() == target }?.value
    }

    /// Body as text. Falls back to Latin-1 so a mis-declared charset still
    /// yields something readable instead of failing the whole chapter.
    var text: String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HTTPError.decoding(String(describing: error))
        }
    }

    /// True when the body looks like a Cloudflare interstitial rather than the
    /// page the source asked for.
    var looksLikeCloudflareChallenge: Bool {
        guard statusCode == 403 || statusCode == 503 || statusCode == 429 else {
            return false
        }
        if header("cf-mitigated") != nil { return true }
        let body = text.prefix(4096).lowercased()
        return body.contains("just a moment")
            || body.contains("cf-chl")
            || body.contains("checking your browser")
            || body.contains("attention required")
    }
}

// MARK: - Errors

/// Errors surfaced by `HTTPClient`.
enum HTTPError: LocalizedError, Equatable {
    case invalidURL(String)
    case transport(String)
    case badStatus(code: Int, url: String)
    /// `detail` says what the last solve for the host did, when there was one.
    case cloudflareChallenge(url: String, detail: String? = nil)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            "Invalid URL: \(url)"
        case .transport(let detail):
            "Network error: \(detail)"
        case .badStatus(let code, let url):
            "HTTP \(code) for \(url)"
        case .cloudflareChallenge(let url, let detail):
            ["Cloudflare challenge blocked \(url)", detail].compactMap { $0 }.joined(separator: "\n")
        case .decoding(let detail):
            "Failed to decode response: \(detail)"
        }
    }

    /// Whether retrying the same request could plausibly succeed.
    var isRetryable: Bool {
        switch self {
        case .transport: true
        case .badStatus(let code, _): code == 408 || code == 429 || (500..<600).contains(code)
        case .invalidURL, .cloudflareChallenge, .decoding: false
        }
    }
}
