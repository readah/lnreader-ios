// MasonrySource.swift - the `masonry` multisrc family (MetArt Hunter and its siblings).
//
// Port of keiyoushi's `lib-multisrc/masonry`. Every site in the family shares one layout: a
// gallery grid on the home, archive and updates pages; one "Gallery" chapter per entry; and the
// full-size images as `.list-gallery` links pointing at the site's CDN.
//
// One configured class rather than a base class plus subclasses, so a sibling site is a single
// entry in `NativeSources.all()`.

import Foundation
import SwiftSoup

final class MasonrySource: MangaSource {

    let key: String
    let kind = ContentKind.manga
    let name: String
    let lang = "all"
    let iconAsset: String?
    let isAdult = true
    let supportsLatest = true
    let filtersAreRemote = true

    func filtersAreComplete(_ filters: [SourceFilter]) -> Bool {
        filters.contains { $0.id == "tag" }
    }

    private let site: SiteClient

    var homepage: URL? { URL(string: site.baseURL) }

    init(id: String, name: String, baseURL: String, iconAsset: String? = nil) {
        let builtinKey = SourceKey.makeBuiltin(id: id)
        self.key = builtinKey
        self.name = name
        self.iconAsset = iconAsset
        self.site = SiteClient(sourceKey: builtinKey, baseURL: baseURL)
    }

    // MARK: Filters

    private static let sortOptions = [
        FilterOption(id: "sort/trending", name: "Trending"),
        FilterOption(id: "sort/newest", name: "Newest"),
        FilterOption(id: "sort/popular", name: "Popular"),
    ]

    func filters() async throws -> [SourceFilter] {
        var result: [SourceFilter] = [
            .select(
                id: "sort", name: "Sort by",
                options: Self.sortOptions, defaultOption: "sort/trending"
            ),
        ]
        // The tag list is site data. A failed fetch leaves the sort filter usable.
        if let document = try? await site.html("/updates/sort/newest/"),
           let tags = Self.tagOptions(in: document) {
            result.append(.select(
                id: "tag", name: "Tags",
                options: [FilterOption(id: "", name: "All")] + tags, defaultOption: ""
            ))
        }
        return result
    }

    private static func tagOptions(in document: Document) -> [FilterOption]? {
        guard let elements = try? document.select("#filter-a span:has(> input)") else { return nil }
        let options = elements.compactMap { element -> FilterOption? in
            guard let value = try? element.select("input").attr("value"), !value.isEmpty else {
                return nil
            }
            let name = ((try? element.select("label").text()) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return FilterOption(id: value, name: name.isEmpty ? value : name)
        }
        return options.isEmpty ? nil : options
    }

    // MARK: Browsing

    func popular(page: Int, filters: FilterState) async throws -> EntriesPage {
        let path: String
        switch page {
        case 1: path = "/"
        case 2: path = "/archive/"
        default: path = "/archive/page/\(page - 1)/"
        }
        return try await listing(path)
    }

    func latest(page: Int, filters: FilterState) async throws -> EntriesPage {
        try await listing("/updates/sort/newest/mpage/\(page)/")
    }

    func search(query: String, page: Int, filters: FilterState) async throws -> EntriesPage {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return try await listing("/search/post/\(Self.pathSegment(trimmed))/mpage/\(page)/")
        }

        // Upstream omits the sort segment for the default of each page kind.
        let sort = Self.sortID(filters)
        let tag = Self.tagID(filters)
        if tag.isEmpty {
            guard sort != "sort/popular" else { return try await listing("/updates/page/\(page)/") }
            return try await listing("/updates/\(sort)/mpage/\(page)/")
        }
        let base = "/tag/\(Self.pathSegment(tag))/"
        guard sort != "sort/trending" else { return try await listing(base + "page/\(page)/") }
        return try await listing(base + "\(sort)/mpage/\(page)/")
    }

    private static func sortID(_ filters: FilterState) -> String {
        if case .option(let value)? = filters["sort"] { return value }
        return "sort/trending"
    }

    private static func tagID(_ filters: FilterState) -> String {
        if case .option(let value)? = filters["tag"] { return value }
        return ""
    }

    /// One path segment, so a tag or query containing `/` cannot add a level.
    private static func pathSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func listing(_ path: String) async throws -> EntriesPage {
        let document = try await site.html(path)
        let hasNext = ((try? document.select(".pagination-a li.next"))?.isEmpty == false)
        return EntriesPage(
            entries: Self.entries(in: document, sourceKey: key, kind: kind, site: site),
            hasNextPage: hasNext
        )
    }

    private static func entries(
        in document: Document, sourceKey: String, kind: ContentKind, site: SiteClient
    ) -> [SourceEntry] {
        let selector = ".list-gallery:not(.static) figure:not(:has(a[href*=/video/]))"
        guard let figures = try? document.select(selector) else { return [] }
        return figures.compactMap { figure -> SourceEntry? in
            guard let anchors = try? figure.select("a"), let anchor = anchors.first(),
                  let href = try? anchor.absUrl("href"), !href.isEmpty else { return nil }
            let title = ((try? anchor.attr("title")) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let relative = href.sourceRelative
            var image: Element?
            if let images = try? figure.select("img") { image = images.first() }
            return SourceEntry(
                sourceKey: sourceKey,
                kind: kind,
                url: relative,
                title: title.isEmpty ? relative : title,
                thumbnailURL: imageURL(image).map(site.absolute)
            )
        }
    }

    /// The first usable image url on an element, in upstream's preference order.
    private static func imageURL(_ image: Element?) -> String? {
        guard let image else { return nil }
        if image.hasAttr("srcset"), let raw = try? image.attr("abs:srcset"), !raw.isEmpty {
            let first = raw.split(separator: " ").first.map(String.init) ?? raw
            if !first.isEmpty { return first }
        }
        for attribute in ["data-cfsrc", "data-src", "data-lazy-src", "src"] {
            guard image.hasAttr(attribute) else { continue }
            if let value = try? image.attr("abs:" + attribute), !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: Details

    func webURL(_ entryURL: String) -> URL? { URL(string: site.absolute(entryURL)) }

    func details(_ entry: SourceEntry) async throws -> SourceEntry {
        let document = try await site.html(entry.url)
        var info: Element?
        if let elements = try? document.select("p.link-btn") { info = elements.first() }

        let models = Self.texts(info, "a[href*=/model/]")
        let genres = Self.texts(info, "a[href*=/tag/]")
        let author = Self.texts(info, "a").first

        return SourceEntry(
            sourceKey: key,
            kind: kind,
            url: entry.url,
            title: entry.title,
            thumbnailURL: entry.thumbnailURL,
            author: author ?? (models.isEmpty ? nil : models.joined(separator: ", ")),
            artist: models.isEmpty ? nil : models.joined(separator: ", "),
            description: document.firstText("#content > p"),
            genres: genres,
            status: .completed
        )
    }

    func chapters(_ entry: SourceEntry) async throws -> [SourceChapter] {
        [SourceChapter(url: entry.url, name: "Gallery", chapterNumber: 1)]
    }

    // MARK: Pages

    func pages(_ chapter: SourceChapter) async throws -> [SourcePage] {
        let document = try await site.html(chapter.url)
        guard let anchors = try? document.select(".list-gallery a[href^=https://cdn.]") else {
            return []
        }
        var pages: [SourcePage] = []
        for anchor in anchors {
            guard let href = try? anchor.absUrl("href"), !href.isEmpty else { continue }
            pages.append(
                SourcePage(
                    index: pages.count, url: href, headers: ["Referer": site.baseURL + "/"]
                )
            )
        }
        return pages
    }

    private static func texts(_ root: Element?, _ selector: String) -> [String] {
        guard let root, let elements = try? root.select(selector) else { return [] }
        return elements.compactMap { try? $0.text() }.filter { !$0.isEmpty }
    }
}
