// NativeSupport.swift - What every hand-written source builds on.
//
// Sources are plain Swift types behind `CatalogSource`. They talk to their site through `SiteClient`
// (one `HTTPClient` path, so rate limits, cookies and Cloudflare handling stay shared) and parse
// with SwiftSoup or `Codable`.

import Foundation
import SwiftSoup

// MARK: - Site access

/// A site's base URL plus the request helpers a source needs.
struct SiteClient: Sendable {

    let sourceKey: String
    /// No trailing slash.
    let baseURL: String
    /// Sent on every request, unless the call overrides a name.
    var headers: [String: String]

    init(sourceKey: String, baseURL: String, headers: [String: String] = [:]) {
        self.sourceKey = sourceKey
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.headers = headers
    }

    /// `baseURL + path` for a relative path, the input unchanged when it is already absolute.
    func absolute(_ pathOrURL: String) -> String {
        if pathOrURL.hasPrefix("http://") || pathOrURL.hasPrefix("https://") { return pathOrURL }
        if pathOrURL.hasPrefix("//") { return "https:" + pathOrURL }
        return baseURL + (pathOrURL.hasPrefix("/") ? "" : "/") + pathOrURL
    }

    func send(
        _ pathOrURL: String,
        method: String = "GET",
        headers extra: [String: String] = [:],
        body: Data? = nil
    ) async throws -> HTTPResponse {
        let merged = headers.merging(extra) { _, new in new }
        let request = try HTTPRequest(
            urlString: absolute(pathOrURL), method: method, headers: merged, body: body
        )
        return try await HTTPClient.shared.send(request, sourceKey: sourceKey)
    }

    func text(_ pathOrURL: String, headers: [String: String] = [:]) async throws -> String {
        try await send(pathOrURL, headers: headers).text
    }

    func html(_ pathOrURL: String, headers: [String: String] = [:]) async throws -> Document {
        let response = try await send(pathOrURL, headers: headers)
        return try SwiftSoup.parse(response.text, response.url.absoluteString)
    }

    func json<T: Decodable>(
        _ type: T.Type = T.self,
        _ pathOrURL: String,
        headers: [String: String] = [:]
    ) async throws -> T {
        try await send(pathOrURL, headers: headers).decoded(T.self)
    }

    /// POST a form (`application/x-www-form-urlencoded`).
    func postForm(
        _ pathOrURL: String,
        _ fields: [(String, String)],
        headers extra: [String: String] = [:]
    ) async throws -> HTTPResponse {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        let body = fields.map { name, value in
            "\(name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name)="
                + "\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        return try await send(
            pathOrURL, method: "POST",
            headers: extra.merging(["Content-Type": "application/x-www-form-urlencoded"]) { old, _ in old },
            body: Data(body.utf8)
        )
    }

    /// POST a JSON body.
    func postJSON(
        _ pathOrURL: String,
        _ object: Any,
        headers extra: [String: String] = [:]
    ) async throws -> HTTPResponse {
        let body = try JSONSerialization.data(withJSONObject: object)
        return try await send(
            pathOrURL, method: "POST",
            headers: extra.merging(["Content-Type": "application/json"]) { old, _ in old },
            body: body
        )
    }
}

// MARK: - Query building

extension String {
    /// Percent-encoding for one query value (`+` and `&` included).
    var queryEscaped: String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }

    /// Mihon's `setUrlWithoutDomain`: path, query and fragment of an absolute url.
    ///
    /// Sources persist this form, so a source keeps resolving the entries it always did. A value
    /// that is already relative comes back with a leading slash and otherwise unchanged.
    var sourceRelative: String {
        guard !isEmpty else { return self }
        guard let parts = URLComponents(string: self) else { return self }
        var result = parts.percentEncodedPath
        if let query = parts.percentEncodedQuery { result += "?" + query }
        if let fragment = parts.percentEncodedFragment { result += "#" + fragment }
        guard !result.isEmpty else { return self }
        return result.hasPrefix("/") ? result : "/" + result
    }
}

// MARK: - SwiftSoup conveniences

extension Element {
    /// Trimmed text of the first match, `nil` when nothing matches or it is empty.
    func firstText(_ selector: String) -> String? {
        guard let text = try? select(selector).first()?.text().trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    /// Attribute of the first match, `nil` when missing or empty.
    func firstAttr(_ selector: String, _ attribute: String) -> String? {
        guard let value = try? select(selector).first()?.attr(attribute), !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - Registry

/// Every source compiled into the app.
enum NativeSources {

    /// The sources, in the order Browse lists them within a kind.
    static func all() -> [any CatalogSource] {
        [
            NovelFireSource(), NovelPhoenixSource(), FreeWebNovelSource(),
            MangaFireSource(), AllMangaSource(), Manhwa18Source(), FourKHDSource(), OmegaScansSource(),
            AtsumaruSource(), WeebCentralSource(), KaganeSource(),
            // The `masonry` family. Upstream also ships FemJoy, XArt, FTV, JoyMii, Playboy Playmates
            // and Elite Babes on this engine; each is one more line here once the site is vetted.
            MasonrySource(
                id: "metarthunter", name: "MetArt Hunter",
                baseURL: "https://www.metarthunter.com", iconAsset: "MetArtIcon"
            ),
        ]
    }
}
