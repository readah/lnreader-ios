// FourKHDSource.swift - 4KHD (4khd.com), an image-gallery site read through its WordPress REST API.
//
// Each post is one entry with one "Gallery" chapter; pages are the images in the post body.
// Port of keiyoushi's `all/fourkhd`. Entry and chapter urls are the post's path, e.g.
// `/content/some-title.html`, which is what the Kotlin extension stores, so backups resolve.

import Foundation
import SwiftSoup

final class FourKHDSource: MangaSource {

    static let mihonID = MihonSourceID.make(name: "4KHD", lang: "all")

    let key = SourceKey.makeBuiltin(id: "fourkhd")
    let kind = ContentKind.manga
    let name = "4KHD"
    let lang = "all"
    let iconAsset: String? = "FourKHDIcon"
    let isAdult = true
    let supportsLatest = true

    private let site = SiteClient(
        sourceKey: SourceKey.makeBuiltin(id: "fourkhd"),
        baseURL: "https://www.4khd.com"
    )

    var homepage: URL? { URL(string: site.baseURL) }
    private let pageSize = 20

    // MARK: Browsing

    func popular(page: Int, filters: FilterState) async throws -> EntriesPage {
        try await listing(page: page, orderBy: "modified", query: nil)
    }

    func latest(page: Int, filters: FilterState) async throws -> EntriesPage {
        try await listing(page: page, orderBy: "date", query: nil)
    }

    func search(query: String, page: Int, filters: FilterState) async throws -> EntriesPage {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await listing(page: page, orderBy: "date", query: trimmed.isEmpty ? nil : query)
    }

    private func listing(page: Int, orderBy: String, query: String?) async throws -> EntriesPage {
        var url = "/index.php?rest_route=/wp/v2/posts&page=\(page)&per_page=\(pageSize)&_embed=1&orderby=\(orderBy)"
        if let query { url += "&search=\(query.queryEscaped)" }
        let response = try await site.send(url, headers: apiHeaders)
        let totalPages = response.header("X-WP-TotalPages").flatMap(Int.init) ?? page
        let posts = try response.decoded([Post].self)
        return EntriesPage(entries: try posts.compactMap(entry), hasNextPage: page < totalPages)
    }

    // MARK: Details

    func webURL(_ entryURL: String) -> URL? { URL(string: site.absolute(entryURL)) }

    func details(_ entry: SourceEntry) async throws -> SourceEntry {
        guard let post = try await post(at: entry.url), let detailed = try self.entry(from: post) else {
            throw SourceError.entryNotFound(entry.url)
        }
        return detailed
    }

    func chapters(_ entry: SourceEntry) async throws -> [SourceChapter] {
        guard let post = try await post(at: entry.url) else { throw SourceError.entryNotFound(entry.url) }
        return [
            SourceChapter(
                url: post.path == "/" ? entry.url : post.path,
                name: "Gallery",
                chapterNumber: 1,
                dateUpload: Self.parseDate(post.date)
            )
        ]
    }

    // MARK: Pages

    func pages(_ chapter: SourceChapter) async throws -> [SourcePage] {
        guard let post = try await post(at: chapter.url) else { throw SourceError.entryNotFound(chapter.url) }
        let headers = ["Referer": site.baseURL + "/"]
        return Self.imageURLs(inHTML: post.content.rendered, base: site.baseURL)
            .enumerated()
            .map { SourcePage(index: $0.offset, url: $0.element, headers: headers) }
    }

    // MARK: Fetching

    private var apiHeaders: [String: String] { ["Accept": "application/json"] }

    /// Looks the post up by the slug in its path, as upstream does when it has no post id.
    private func post(at path: String) async throws -> Post? {
        let slug = Self.slug(fromPath: path)
        var url = "/index.php?rest_route=/wp/v2/posts&_embed=1"
        if !slug.isEmpty {
            url += "&slug=\(slug.queryEscaped)"
        } else {
            let fallback = path.split(separator: "/").last.map(String.init) ?? path
            if !fallback.isEmpty { url += "&search=\(fallback.queryEscaped)" }
        }
        return try await site.json([Post].self, url, headers: apiHeaders).first
    }

    private func entry(from post: Post) throws -> SourceEntry? {
        let path = post.path
        guard path != "/" else { return nil }
        let title = (try? SwiftSoup.parse(post.title.rendered).text().trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        let thumbnail = post.jetpackFeaturedMediaUrl
            ?? post.embedded?.featuredMedia?.first?.sourceUrl
            ?? Self.imageURLs(inHTML: post.content.rendered, base: site.baseURL).first
        var seen = Set<String>()
        let genres = (post.embedded?.terms ?? []).flatMap { $0 }.map(\.name)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return SourceEntry(
            sourceKey: key,
            kind: kind,
            url: path,
            title: title,
            thumbnailURL: thumbnail,
            genres: genres,
            status: .completed
        )
    }

    // MARK: Parsing

    private static let imagePattern = try! NSRegularExpression(
        pattern: #"\.(?:jpe?g|png|webp|gif|avif)(?:$|\?)"#, options: .caseInsensitive
    )
    private static let slugPattern = try! NSRegularExpression(pattern: #"/([^/]+)\.html(?:/\d+)?/?$"#)

    private static func isImageURL(_ url: String) -> Bool {
        imagePattern.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }

    static func slug(fromPath path: String) -> String {
        let range = NSRange(path.startIndex..., in: path)
        if let match = slugPattern.firstMatch(in: path, range: range),
           let slugRange = Range(match.range(at: 1), in: path), !path[slugRange].isEmpty {
            return String(path[slugRange]).removingPercentEncoding ?? String(path[slugRange])
        }
        var last = path
        while last.hasSuffix("/") { last.removeLast() }
        last = last.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? last
        let slug = last.components(separatedBy: ".html").first ?? last
        return slug.removingPercentEncoding ?? slug
    }

    /// Image urls in post order, de-duplicated ignoring the query string.
    static func imageURLs(inHTML html: String, base: String) -> [String] {
        guard !html.isEmpty, let document = try? SwiftSoup.parseBodyFragment(html, base) else { return [] }
        let root = (try? document.select(".entry-content.wp-block-post-content, .entry-content").first())
            ?? document.body() ?? document
        var urls: [String] = []
        if let images = try? root.select("img[data-src], img[data-lazy-src], img[src]") {
            for image in images {
                for attribute in ["abs:data-src", "abs:data-lazy-src", "abs:src"] {
                    let value = ((try? image.attr(attribute)) ?? "").trimmingCharacters(in: .whitespaces)
                    if isImageURL(value) { urls.append(value); break }
                }
            }
        }
        if urls.isEmpty, let anchors = try? root.select("a[href]") {
            urls = anchors.compactMap { try? $0.attr("abs:href").trimmingCharacters(in: .whitespaces) }
                .filter(isImageURL)
        }
        var seen = Set<String>()
        return urls.filter { seen.insert(canonicalKey($0)).inserted }
    }

    private static func canonicalKey(_ url: String) -> String {
        url.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? url
    }

    /// WordPress dates are local time without an offset.
    private static func parseDate(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: String(raw.prefix(19)))
    }
}

// MARK: - API shapes

private struct Post: Decodable, Sendable {
    let id: Int
    let date: String
    let link: String
    let title: Rendered
    let content: Rendered
    let jetpackFeaturedMediaUrl: String?
    let embedded: Embedded?

    enum CodingKeys: String, CodingKey {
        case id, date, link, title, content
        case jetpackFeaturedMediaUrl = "jetpack_featured_media_url"
        case embedded = "_embedded"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        date = (try? c.decode(String.self, forKey: .date)) ?? ""
        link = (try? c.decode(String.self, forKey: .link)) ?? ""
        title = (try? c.decode(Rendered.self, forKey: .title)) ?? Rendered(rendered: "")
        content = (try? c.decode(Rendered.self, forKey: .content)) ?? Rendered(rendered: "")
        jetpackFeaturedMediaUrl = try? c.decode(String.self, forKey: .jetpackFeaturedMediaUrl)
        embedded = try? c.decode(Embedded.self, forKey: .embedded)
    }

    /// The post's path (percent-encoded), `"/"` when the link has none.
    var path: String {
        guard let url = URL(string: link) else { return "/" }
        let path = url.path(percentEncoded: true)
        return path.isEmpty ? "/" : path
    }
}

private struct Rendered: Decodable, Sendable {
    let rendered: String
}

private struct Embedded: Decodable, Sendable {
    let featuredMedia: [Media]?
    let terms: [[Term]]?

    enum CodingKeys: String, CodingKey {
        case featuredMedia = "wp:featuredmedia"
        case terms = "wp:term"
    }

    struct Media: Decodable, Sendable {
        let sourceUrl: String?
        enum CodingKeys: String, CodingKey { case sourceUrl = "source_url" }
    }

    struct Term: Decodable, Sendable {
        let name: String
    }
}
