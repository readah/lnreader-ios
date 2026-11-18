// Manhwa18Source.swift - Manhwa18 (manhwa18.com), ported from keiyoushi's src/en/manhwa18.
//
// An HTML site: listings and search share /tim-kiem, entry and chapter urls are stored the way Mihon
// stores them (path only, e.g. "/manga/<slug>"), so imported backups resolve.

import Foundation
import SwiftSoup

final class Manhwa18Source: MangaSource {

    /// Mihon source id: `MihonSourceID.make(name: "Manhwa18", lang: "en", versionId: 1)`.
    static let mihonID: Int64 = MihonSourceID.make(name: "Manhwa18", lang: "en", versionId: 1)

    let key = SourceKey.makeBuiltin(id: "manhwa18")
    let kind = ContentKind.manga
    let name = "Manhwa18"
    let lang = "en"
    let iconAsset: String? = "Manhwa18Icon"
    let isAdult = true
    let supportsLatest = true

    private let site = SiteClient(
        sourceKey: SourceKey.makeBuiltin(id: "manhwa18"),
        baseURL: "https://manhwa18.com",
        headers: ["Referer": "https://manhwa18.com/"]
    )

    var homepage: URL? { URL(string: site.baseURL) }

    // MARK: Filters

    private static let sortOptions = [
        FilterOption(id: "update", name: "Latest update"),
        FilterOption(id: "new", name: "New manhwa"),
        FilterOption(id: "top", name: "Most view"),
        FilterOption(id: "like", name: "Most like"),
        FilterOption(id: "az", name: "A - Z"),
        FilterOption(id: "za", name: "Z - A"),
    ]

    private static let statusOptions = [
        FilterOption(id: "0", name: "All"),
        FilterOption(id: "1", name: "Ongoing"),
        FilterOption(id: "2", name: "On hold"),
        FilterOption(id: "3", name: "Completed"),
    ]

    private static let genres: [(String, String)] = [
        ("Adult", "4"), ("Doujinshi", "9"), ("Harem", "17"), ("Manga", "24"), ("Manhwa", "26"),
        ("Mature", "28"), ("NTR", "33"), ("Romance", "36"), ("Webtoon", "57"), ("Action", "59"),
        ("Comedy", "60"), ("BL", "61"), ("Horror", "62"), ("Raw", "63"), ("Uncensore", "64"),
        ("Art", "65"), ("M18Scan", "66"), ("Drama", "68"), ("Supernatural", "128"), ("Seinen", "160"),
        ("Borderline H", "161"), ("Full Color", "162"), ("Slice of Life", "163"), ("Smut", "164"),
        ("Uncensored", "165"), ("Webtoons", "166"), ("Explicit Sex", "167"), ("Cohabitation", "168"),
        ("Delinquents", "169"), ("Fetish", "170"), ("Nudity", "171"), ("Sexual Abuse", "172"),
        ("Sexual Content", "173"), ("Fantasy", "174"), ("Ghosts", "175"), ("Historical", "176"),
        ("School Life", "177"), ("Psychological", "178"), ("Incest", "179"), ("Japanese Webtoons", "180"),
        ("Coworkers", "181"), ("Salaryman", "182"), ("Siblings", "183"), ("Work Life", "184"),
        ("Gyaru", "185"), ("Based on Another Work", "186"), ("Demons", "187"), ("Crime", "188"),
        ("Mystery", "189"), ("Reverse Harem", "190"), ("Adventure", "191"), ("Isekai", "192"),
        ("Magic", "193"), ("Thriller", "194"), ("Time Travel", "195"), ("Reincarnation", "196"),
        ("Sports", "197"), ("Medical", "198"), ("Sci Fi", "199"), ("AI Art", "200"),
        ("Animal Characteristics", "201"), ("Monster Girls", "202"), ("Violence", "203"),
        ("Collection of Stories", "204"), ("Ecchi", "205"), ("Monsters", "206"), ("Survival", "207"),
    ]

    func filters() async throws -> [SourceFilter] {
        [
            .select(id: "sort", name: "Order", options: Self.sortOptions, defaultOption: "update"),
            .select(id: "status", name: "Status", options: Self.statusOptions, defaultOption: "0"),
            .multiSelect(
                id: "genres", name: "Genres",
                options: Self.genres.map { FilterOption(id: $0.1, name: $0.0) }, defaultSelection: []
            ),
        ]
    }

    // MARK: Browsing

    func popular(page: Int, filters: FilterState) async throws -> EntriesPage {
        try await list("/tim-kiem?sort=top&page=\(page)")
    }

    func latest(page: Int, filters: FilterState) async throws -> EntriesPage {
        try await list("/tim-kiem?sort=update&page=\(page)")
    }

    func search(query: String, page: Int, filters: FilterState) async throws -> EntriesPage {
        var parts: [String] = []
        if !query.isEmpty { parts.append("q=\(query.queryEscaped)") }

        var sort = "update"
        if case .option(let value)? = filters["sort"] { sort = value }
        parts.append("sort=\(sort)")

        if case .option(let status)? = filters["status"], status != "0" {
            parts.append("status=\(status)")
        }
        if case .options(let ids)? = filters["genres"], !ids.isEmpty {
            // Upstream joins in the filter's declared order.
            let ordered = Self.genres.map(\.1).filter(ids.contains)
            parts.append("accept_genres=\(ordered.joined(separator: ",").queryEscaped)")
        }
        parts.append("page=\(page)")
        return try await list("/tim-kiem?" + parts.joined(separator: "&"))
    }

    private func list(_ path: String) async throws -> EntriesPage {
        let document = try await site.html(path)
        var entries: [SourceEntry] = []
        for element in try document.select(".thumb-item-flow") {
            guard let href = try element.select("a").first()?.absUrl("href"), !href.isEmpty,
                  let title = element.firstText(".series-title a") else { continue }
            let thumb = element.firstAttr(".lazy-bg", "data-bg")
                ?? Self.styleURL(element.firstAttr(".img-in-ratio", "style"))
            entries.append(SourceEntry(
                sourceKey: key, kind: kind, url: Self.withoutDomain(href), title: title,
                thumbnailURL: thumb.map(site.absolute)
            ))
        }
        let hasNext = !(try document.select(".pagination_wrap a.next")).isEmpty()
        return EntriesPage(entries: entries, hasNextPage: hasNext)
    }

    // MARK: Details

    func webURL(_ entryURL: String) -> URL? { URL(string: site.absolute(entryURL)) }

    func details(_ entry: SourceEntry) async throws -> SourceEntry {
        let document = try await site.html(entry.url)
        let title = document.firstText(".series-name a, .au-bento h1, .au-crumb a:last-child") ?? entry.title

        var author: String?
        var genres: [String] = []
        var status = EntryStatus.unknown
        for item in try document.select(".series-information .info-item") {
            guard let label = item.firstText(".info-name"), let value = item.firstText(".info-value") else { continue }
            let lower = label.lowercased()
            if lower.contains("author") {
                author = value
            } else if lower.contains("genre") {
                genres = try item.select(".info-value a").map { try $0.text() }
            } else if lower.contains("status") {
                switch value.lowercased().replacingOccurrences(of: " ", with: "") {
                case "ongoing": status = .ongoing
                case "completed": status = .completed
                case "onhold": status = .onHiatus
                default: status = .unknown
                }
            }
        }
        if author?.isEmpty ?? true { author = document.firstText(".fantrans-value a") }

        let cover = Self.styleURL(document.firstAttr(".series-cover .img-in-ratio", "style")) ?? entry.thumbnailURL
        return SourceEntry(
            sourceKey: key, kind: kind, url: entry.url, title: title,
            thumbnailURL: cover.map(site.absolute), author: author, artist: nil,
            description: document.firstText(".summary-content"), genres: genres, status: status
        )
    }

    func chapters(_ entry: SourceEntry) async throws -> [SourceChapter] {
        let document = try await site.html(entry.url)
        var result: [SourceChapter] = []
        for anchor in try document.select("div.au-chgrid a.au-chtile, ul.list-chapters > a") {
            let href = try anchor.absUrl("href")
            guard !href.isEmpty else { continue }
            var name = try anchor.attr("data-name")
            if name.isEmpty { name = try anchor.attr("title") }

            var stamp = anchor.firstText(".au-chtile-date").flatMap { $0.components(separatedBy: "·").last }
            if stamp == nil { stamp = anchor.firstText(".chapter-time").flatMap { $0.components(separatedBy: "-").last } }
            result.append(SourceChapter(
                url: Self.withoutDomain(href), name: name,
                dateUpload: Self.dateFormatter.date(from: stamp?.trimmingCharacters(in: .whitespaces) ?? "")
            ))
        }
        return result
    }

    // MARK: Pages

    func pages(_ chapter: SourceChapter) async throws -> [SourcePage] {
        let document = try await site.html(chapter.url)
        var pages: [SourcePage] = []
        for image in try document.select("#chapter-content img.lazy") {
            let url = try image.absUrl("data-src")
            if url.isEmpty { continue }
            pages.append(SourcePage(index: pages.count, url: url, headers: ["Referer": site.baseURL + "/"]))
        }
        return pages
    }

    // MARK: Helpers

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d/M/yyyy"
        return formatter
    }()

    /// Mihon's `setUrlWithoutDomain`: path, query and fragment of an absolute url.
    private static func withoutDomain(_ url: String) -> String {
        guard let parts = URLComponents(string: url) else { return url }
        var result = parts.percentEncodedPath
        if let query = parts.percentEncodedQuery { result += "?" + query }
        if let fragment = parts.percentEncodedFragment { result += "#" + fragment }
        return result
    }

    /// `background-image: url('…')` to the url.
    private static func styleURL(_ style: String?) -> String? {
        guard let style, let start = style.range(of: "url('") else { return nil }
        let rest = style[start.upperBound...]
        guard let end = rest.range(of: "')") else { return nil }
        let value = String(rest[..<end.lowerBound])
        return value.isEmpty ? nil : value
    }
}
