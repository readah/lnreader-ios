// WeebCentralSource.swift - Weeb Central (weebcentral.com), ported from keiyoushi's src/en/weebcentral.
//
// HTML, no API: browse and search are both `/search/data`, which returns a server-rendered fragment
// of result cards. Entry urls are `/series/<id>/<slug>`, chapters `/chapters/<id>` and pages come
// from `<chapter>/images`, the shape the Kotlin extension stores.
//
// Upstream asks for one request every two seconds; rate limiting is global here, so the port rides
// on `RateLimitInterceptor` instead. Its `Origin` removal is not ported either: the shared client
// never sends one.

import Foundation
import SwiftSoup

final class WeebCentralSource: MangaSource {

    static let mihonID = MihonSourceID.make(name: "Weeb Central", lang: "en")

    let key = SourceKey.makeBuiltin(id: "weebcentral")
    let kind = ContentKind.manga
    let name = "Weeb Central"
    let lang = "en"
    let iconAsset: String? = "WeebCentralIcon"
    let supportsLatest = true

    private let site = SiteClient(
        sourceKey: SourceKey.makeBuiltin(id: "weebcentral"),
        baseURL: "https://weebcentral.com"
    )

    var homepage: URL? { URL(string: site.baseURL) }

    /// The site ignores `limit` and answers 32 cards per request regardless.
    private static let fetchLimit = 32

    // MARK: - Browsing

    func popular(page: Int, filters: FilterState) async throws -> EntriesPage {
        try await listing(query: "", page: page, sort: "Popularity")
    }

    func latest(page: Int, filters: FilterState) async throws -> EntriesPage {
        try await listing(query: "", page: page, sort: "Latest Updates")
    }

    func search(query: String, page: Int, filters: FilterState) async throws -> EntriesPage {
        try await listing(query: query, page: page, sort: nil, filters: filters)
    }

    func filters() async throws -> [SourceFilter] { Self.filterDefinitions }

    /// One `/search/data` request. `sort` overrides the filter list for the two browse listings.
    private func listing(
        query: String, page: Int, sort: String?, filters: FilterState = FilterState()
    ) async throws -> EntriesPage {
        // Brackets and commas in a title make the site's search return nothing.
        let text = query.replacingOccurrences(of: "[!#:(),-]", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var params: [(String, String)] = [("text", text)]
        if let sort {
            params += [("sort", sort), ("order", "Descending")]
        } else {
            params += Self.filterParams(filters)
        }
        params += [
            ("limit", String(Self.fetchLimit)),
            ("offset", String((page - 1) * Self.fetchLimit)),
            ("display_mode", "Full Display"),
        ]

        let url = "/search/data?" + params.map { "\($0.0)=\($0.1.queryEscaped)" }.joined(separator: "&")
        let document = try await site.html(url)

        var entries: [SourceEntry] = []
        for anchor in try document.select("article > section > a") {
            guard let href = Self.attr(anchor, "abs:href"), let title = Self.title(of: anchor) else { continue }
            entries.append(
                SourceEntry(
                    sourceKey: key, kind: kind, url: href.sourceRelative, title: title,
                    thumbnailURL: Self.sourceImage(anchor)
                )
            )
        }
        // A "load more" button is present while another page exists.
        let hasNextPage = Self.first(document, "button") != nil
        return EntriesPage(entries: entries, hasNextPage: hasNextPage)
    }

    // MARK: - Details

    func webURL(_ entryURL: String) -> URL? { URL(string: site.absolute(entryURL)) }

    func details(_ entry: SourceEntry) async throws -> SourceEntry {
        let document = try await site.html(entry.url)
        let sections = try document.select("section[x-data] > section")
        guard sections.count >= 2 else { throw SourceError.parseFailed("series page for \(entry.url)") }
        let info = sections[0]
        let body = sections[1]

        return SourceEntry(
            sourceKey: key, kind: kind, url: entry.url,
            title: Self.text(body, "h1") ?? entry.title,
            thumbnailURL: Self.sourceImage(info) ?? entry.thumbnailURL,
            author: Self.joinedText(info, "ul > li:has(strong:contains(Author)) > span > a"),
            description: Self.description(document),
            genres: Self.genres(info),
            status: Self.status(Self.text(info, "ul > li:has(strong:contains(Status)) > a"))
        )
    }

    func chapters(_ entry: SourceEntry) async throws -> [SourceChapter] {
        let seriesID = Self.seriesID(entry.url)
        guard !seriesID.isEmpty else { throw SourceError.entryNotFound(entry.url) }
        let document = try await site.html("/series/\(seriesID)/full-chapter-list")
        // Newest first.
        let rows = try document.select("div[x-data] > a").array()

        // A title that numbers its chapters by season ("Season 2 Chapter 3") cannot be numbered from
        // the title alone, so every chapter is counted down from the top instead.
        var indexFromTitle = false
        var chapters: [SourceChapter] = []
        for (index, row) in rows.enumerated() {
            guard let href = Self.attr(row, "abs:href") else { continue }
            let name = Self.text(row, "span.flex > span") ?? ""
            let range = NSRange(name.startIndex..., in: name)
            if Self.seasonPattern.firstMatch(in: name, range: range) != nil { indexFromTitle = true }

            let isOfficial = Self.all(row, "img").contains { image in
                (Self.attr(image, "src") ?? "").lowercased().contains("official")
            }
            chapters.append(
                SourceChapter(
                    url: href.sourceRelative,
                    name: name.isEmpty ? "Chapter" : name,
                    chapterNumber: indexFromTitle ? Double(rows.count - index) : -1,
                    scanlator: isOfficial ? "Official" : "Unknown",
                    dateUpload: Self.attr(row, "time[datetime]", "datetime").flatMap(Self.date)
                )
            )
        }
        return chapters
    }

    // MARK: - Pages

    func pages(_ chapter: SourceChapter) async throws -> [SourcePage] {
        var path = chapter.url.hasSuffix("/") ? String(chapter.url.dropLast()) : chapter.url
        path += "/images?is_prev=False&reading_style=long_strip"
        let document = try await site.html(path)

        return Self.all(document, "section#chapter-images > img").enumerated().compactMap { index, image in
            Self.attr(image, "abs:src").map { SourcePage(index: index, url: $0) }
        }
    }

    func imageRequest(_ page: SourcePage) async throws -> URLRequest {
        guard let url = URL(string: page.url) else { throw HTTPError.invalidURL(page.url) }
        var request = URLRequest(url: url)
        request.setValue("image/avif,image/webp,*/*", forHTTPHeaderField: "Accept")
        request.setValue(site.baseURL + "/", forHTTPHeaderField: "Referer")
        return request
    }

    // MARK: - Parsing

    /// `source[srcset]` first (the larger cover), then the `img` fallback.
    private static func sourceImage(_ element: Element) -> String? {
        if let srcset = attr(element, "source", "srcset") {
            return srcset.replacingOccurrences(of: "small", with: "normal")
        }
        return attr(element, "img", "abs:src")
    }

    private static func title(of anchor: Element) -> String? {
        if let text = text(anchor, "div:not([class]):last-child") { return text }
        if let text = text(anchor, "div.truncate") { return text }
        guard let alt = attr(anchor, "img", "alt") else { return nil }
        let stripped = alt.replacingOccurrences(of: " cover", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }

    /// `Type` and `Tags` share one row list; the format comes first, as on the site.
    private static func genres(_ info: Element) -> [String] {
        var names: [String] = []
        if let type = text(info, "ul > li:has(strong:contains(Type)) > a") { names.append(type) }
        names += all(info, "ul > li:has(strong:contains(Tag)) a").compactMap { try? $0.text() }
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func description(_ document: Document) -> String {
        var blocks: [String] = []
        if let synopsis = text(document, "li:has(strong:contains(Description)) > p") {
            blocks.append(synopsis.replacingOccurrences(of: "NOTE: ", with: "\n\nNOTE: "))
        }

        let related = all(document, "li:has(strong:contains(Related Series)) li").compactMap { row -> String? in
            guard let name = text(row, "a"), let href = attr(row, "a", "abs:href") else { return nil }
            let relation = text(row, "span") ?? ""
            return "- \(name) (\(href)) \(relation)".trimmingCharacters(in: .whitespaces)
        }
        if !related.isEmpty { blocks.append("Related series:\n" + related.joined(separator: "\n")) }

        let alternates = all(document, "li:has(strong:contains(Associated Name)) li")
            .compactMap { try? $0.text() }
            .filter { !$0.isEmpty }
        if !alternates.isEmpty {
            blocks.append("Associated names:\n" + alternates.map { "- \($0)" }.joined(separator: "\n"))
        }

        let trackers = all(document, "li:has(strong:contains(Track)) span[data-tip] > a").compactMap { link -> String? in
            guard let parent = link.parent(), let href = attr(link, "abs:href") else { return nil }
            return "- \((try? parent.attr("data-tip")) ?? "") (\(href))"
        }
        if !trackers.isEmpty { blocks.append("Trackers:\n" + trackers.joined(separator: "\n")) }

        return blocks.joined(separator: "\n\n")
    }

    private static func status(_ raw: String?) -> EntryStatus {
        switch raw?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "ongoing": .ongoing
        case "complete", "completed": .completed
        case "hiatus": .onHiatus
        case "canceled", "cancelled": .cancelled
        default: .unknown
        }
    }

    /// `/series/<id>/<slug>` → `<id>`.
    static func seriesID(_ url: String) -> String {
        let parts = url.split(separator: "/").map(String.init)
        return parts.count > 1 ? parts[1] : ""
    }

    private static let seasonPattern = try! NSRegularExpression(
        pattern: #"(Season|S)\s*\d+"#, options: .caseInsensitive
    )

    /// `2024-09-07T17:04:15.717Z`
    private static func date(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    // MARK: - SwiftSoup helpers
    //
    // `select`, `selectFirst`, `text` and `attr` all throw, and `try?` on a call that already returns
    // an optional yields a double optional. These keep the call sites flat.

    private static func all(_ element: Element, _ selector: String) -> [Element] {
        guard let found = try? element.select(selector) else { return [] }
        return found.array()
    }

    private static func first(_ element: Element, _ selector: String) -> Element? {
        all(element, selector).first
    }

    private static func text(_ element: Element, _ selector: String) -> String? {
        guard let found = first(element, selector) else { return nil }
        let value = (try? found.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private static func attr(_ element: Element, _ selector: String, _ attribute: String) -> String? {
        guard let found = first(element, selector) else { return nil }
        return attr(found, attribute)
    }

    private static func attr(_ element: Element, _ attribute: String) -> String? {
        let value = (try? element.attr(attribute)) ?? ""
        return value.isEmpty ? nil : value
    }

    private static func joinedText(_ element: Element, _ selector: String) -> String? {
        let parts = all(element, selector).compactMap { try? $0.text() }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    // MARK: - Filters

    private enum Filters {
        static let sort = "sort", order = "order", official = "official", anime = "anime"
        static let adult = "adult", author = "author", status = "status", type = "type", tags = "tags"
    }

    /// Query parameters for the picks in `filters`. Unset filters keep the site's own defaults.
    private static func filterParams(_ filters: FilterState) -> [(String, String)] {
        var params: [(String, String)] = []

        func option(_ id: String, _ param: String) {
            if case .option(let value)? = filters[id] { params.append((param, value)) }
        }
        option(Filters.sort, "sort")
        option(Filters.order, "order")
        option(Filters.official, "official")
        option(Filters.anime, "anime")
        option(Filters.adult, "adult")

        if case .text(let author)? = filters[Filters.author] {
            let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { params.append(("author", trimmed)) }
        }
        if case .options(let statuses)? = filters[Filters.status] {
            params += statuses.sorted().map { ("included_status", $0) }
        }
        if case .options(let types)? = filters[Filters.type] {
            params += types.sorted().map { ("included_type", $0) }
        }
        if case .exclude(let included, let excluded)? = filters[Filters.tags] {
            params += included.sorted().map { ("included_tag", $0) }
            params += excluded.sorted().map { ("excluded_tag", $0) }
        }
        return params
    }

    private static func options(_ values: [String]) -> [FilterOption] {
        values.map { FilterOption(id: $0, name: $0) }
    }

    private static let filterDefinitions: [SourceFilter] = [
        .select(
            id: Filters.sort, name: "Sort",
            options: options([
                "Best Match", "Alphabet", "Popularity", "Subscribers", "Recently Added",
                "Latest Updates",
            ]),
            defaultOption: "Best Match"
        ),
        .select(
            id: Filters.order, name: "Sort order",
            options: options(["Descending", "Ascending"]), defaultOption: "Descending"
        ),
        .select(
            id: Filters.official, name: "Official translation",
            options: options(["Any", "True", "False"]), defaultOption: "Any"
        ),
        .select(
            id: Filters.anime, name: "Anime adaptation",
            options: options(["Any", "True", "False"]), defaultOption: "Any"
        ),
        .select(
            id: Filters.adult, name: "Adult content",
            options: options(["Any", "True", "False"]), defaultOption: "Any"
        ),
        .text(id: Filters.author, name: "Author", hint: "Case-sensitive", defaultValue: ""),
        .separator(id: "sep1"),
        .multiSelect(
            id: Filters.status, name: "Series status",
            options: options(["Ongoing", "Complete", "Hiatus", "Canceled"]), defaultSelection: []
        ),
        .multiSelect(
            id: Filters.type, name: "Series type",
            options: options(["Manga", "Manhwa", "Manhua", "OEL"]), defaultSelection: []
        ),
        .separator(id: "sep2"),
        .excludable(
            id: Filters.tags, name: "Tags",
            options: options([
                "Action", "Adult", "Adventure", "Comedy", "Doujinshi", "Drama", "Ecchi", "Fantasy",
                "Gender Bender", "Harem", "Hentai", "Historical", "Horror", "Isekai", "Josei",
                "Lolicon", "Martial Arts", "Mature", "Mecha", "Mystery", "Psychological", "Romance",
                "School Life", "Sci-fi", "Seinen", "Shotacon", "Shoujo", "Shoujo Ai", "Shounen",
                "Shounen Ai", "Slice of Life", "Smut", "Sports", "Supernatural", "Tragedy", "Yaoi",
                "Yuri", "Other",
            ]),
            defaultIncluded: [], defaultExcluded: []
        ),
    ]
}
