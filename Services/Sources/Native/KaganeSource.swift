// KaganeSource.swift - Kagane (kagane.moe), ported from keiyoushi's src/all/kagane.
//
// A JSON API site behind a two-step reader gate: `/api/integrity` hands out a token that the
// challenge call (`POST /api/v2/books/<chapterId>`) exchanges for an access token plus a manifest of
// page ids. Image urls carry that token, which is why they are built in `pages()` and not stored.
//
// Upstream ships one instance per language (18 of them) over a mirror list. The app has no mirror
// support and one source per language would mean 18 entries in Browse, so this is the English
// instance on `kagane.moe`, upstream's single default host (it used to list `kagane.cx`, `.moe`,
// `.net` as mirrors). Entry urls are the bare series id and chapters `/series/<id>/reader/<bookId>`,
// the shape the Kotlin extension stores.
//
// Preferences are not ported (no per-source settings screen); the port runs with upstream's
// defaults: every content rating, no excluded genres or formats, both official and scanlation
// sources, no data saver, and chapter titles as the site writes them. Content rating, format,
// status, genres, tags and sources are filters instead.
//
// Descriptions are plain text rather than upstream's markdown: the detail screen renders the
// summary verbatim.

import Foundation
import SwiftSoup

final class KaganeSource: MangaSource {

    static let mihonID = MihonSourceID.make(name: "Kagane", lang: "en")

    let key = SourceKey.makeBuiltin(id: "kagane")
    let kind = ContentKind.manga
    let name = "Kagane"
    let lang = "en"
    let iconAsset: String? = "KaganeIcon"
    let supportsLatest = true
    let filtersAreRemote = true

    private let site = SiteClient(
        sourceKey: SourceKey.makeBuiltin(id: "kagane"),
        baseURL: "https://kagane.moe"
    )
    private let apiURL = "https://kagane.moe/api/v2"
    private let state = KaganeState()

    func filtersAreComplete(_ filters: [SourceFilter]) -> Bool {
        let ids = Set(filters.map(\.id))
        return ids.contains(Filters.genres) && ids.contains(Filters.sources) && ids.contains(Filters.tags)
    }

    // MARK: - Browsing

    func popular(page: Int, filters: FilterState) async throws -> EntriesPage {
        // Upstream browses by average views and ignores the user's filters; Browse sends a changed
        // filter list through `search` instead.
        try await search(page: page, body: ["source_type": Self.sourceTypes], sort: "avg_views,desc")
    }

    func latest(page: Int, filters: FilterState) async throws -> EntriesPage {
        try await search(page: page, body: ["source_type": Self.sourceTypes], sort: "updated_at,desc")
    }

    func search(query: String, page: Int, filters: FilterState) async throws -> EntriesPage {
        var body = Self.baseBody(filters: filters)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { body["title"] = trimmed }
        if let tags = await tagsBody(filters) { body["tags"] = tags }
        return try await search(page: page, body: body, sort: Self.sortValue(filters))
    }

    func filters() async throws -> [SourceFilter] {
        // A failed metadata fetch must not blank the sheet: the fixed filters still work.
        guard let metadata = try? await loadMetadata() else { return Self.baseFilters }
        return Self.baseFilters + [
            .separator(id: "sep2"),
            .checkbox(id: Filters.genresMatchAll, name: "Match all selected genres", defaultValue: true),
            .excludable(
                id: Filters.genres, name: "Genres", options: metadata.genres,
                defaultIncluded: [], defaultExcluded: []
            ),
            .checkbox(id: Filters.tagsMatchAll, name: "Match all typed tags", defaultValue: true),
            .text(id: Filters.tags, name: "Tags", hint: "e.g. Medieval, -Politics", defaultValue: ""),
            .multiSelect(
                id: Filters.sources, name: "Sources", options: metadata.sources, defaultSelection: []
            ),
        ]
    }

    // MARK: - Details

    func webURL(_ entryURL: String) -> URL? { URL(string: site.absolute("/series/\(Self.seriesID(entryURL))")) }

    func details(_ entry: SourceEntry) async throws -> SourceEntry {
        let seriesID = Self.seriesID(entry.url)
        let dto = try await detailsDTO(seriesID)
        return SourceEntry(
            sourceKey: key, kind: kind, url: seriesID,
            title: Self.title(dto),
            thumbnailURL: dto.covers.first.flatMap { $0.imageID }.map { "\(apiURL)/image/\($0)" },
            author: Self.staff(dto, roles: ["Author", "Story"]),
            artist: Self.staff(dto, roles: ["Artist", "Art"]),
            description: Self.description(dto),
            genres: (dto.format.map { [$0] } ?? []) + dto.genres.compactMap(\.name),
            status: Self.status(dto.publicationStatus)
        )
    }

    func chapters(_ entry: SourceEntry) async throws -> [SourceChapter] {
        let seriesID = Self.seriesID(entry.url)
        let index = try await site.json(
            BookIndexDTO.self, "/api/v2/series/\(seriesID)/books/index?fields=List"
        )
        // A handful of formats publish chapter numbers the site does not sort by; for those the
        // site's own number is used instead of letting the title decide.
        let format = (try? await detailsDTO(seriesID))?.format
        let useSourceNumber = format.map(Self.sourceNumberFormats.contains) ?? false

        return try index.rows().map { book in
            SourceChapter(
                url: "/series/\(seriesID)/reader/\(book.id)",
                name: book.chapterName,
                chapterNumber: useSourceNumber ? book.number : -1,
                scanlator: book.scanlator,
                dateUpload: book.releasedAt
            )
        }
    }

    // MARK: - Pages

    func pages(_ chapter: SourceChapter) async throws -> [SourcePage] {
        let parts = chapter.url.split(separator: "/").map(String.init)
        guard let chapterID = parts.last, parts.count >= 2 else {
            throw SourceError.entryNotFound(chapter.url)
        }

        let challenge = try await challenge(for: chapterID)
        guard let cacheURL = URL(string: challenge.cacheURL) else {
            throw SourceError.parseFailed("cache url \(challenge.cacheURL)")
        }
        let base = cacheURL.absoluteString.hasSuffix("/")
            ? String(cacheURL.absoluteString.dropLast()) : cacheURL.absoluteString

        return (challenge.manifest?.pages ?? []).enumerated().map { index, page in
            let ext = page.ext ?? "jxl"
            let url = "\(base)/api/v2/books/page/\(chapterID)/\(page.pageID).\(ext)"
                + "?token=\(challenge.accessToken)"
            return SourcePage(index: index, url: url, headers: Self.imageHeaders)
        }
    }

    /// The image host answers `404 {"error": -7}` unless the request carries the site's
    /// `Origin` (upstream: `imageFetch = Fetch.XHR`). It has to live on the page rather than in
    /// `imageRequest`: the reader loads through `PageLoader`, which only sends `page.headers`,
    /// and only downloads go through `imageRequest`.
    private static let imageHeaders = [
        "Origin": "https://kagane.moe",
        "Referer": "https://kagane.moe/",
    ]

    // MARK: - Reader gate

    /// `POST /api/v2/books/<id>` with an integrity token, cached per chapter for as long as its
    /// access token is likely to live. Caching keeps the image urls stable, so the page cache
    /// actually hits when a chapter is reopened.
    private func challenge(for chapterID: String) async throws -> ChallengeDTO {
        if let cached = await state.challenge(for: chapterID) { return cached }

        let integrity = try await integrityToken()
        let response = try await site.postJSON(
            "/api/v2/books/\(chapterID)?is_datasaver=false",
            [String: Any](),
            headers: ["x-integrity-token": integrity]
        )
        let challenge = try response.decoded(ChallengeDTO.self)
        await state.store(challenge: challenge, for: chapterID)
        return challenge
    }

    private func integrityToken() async throws -> String {
        if let cached = await state.integrityToken() { return cached }

        let dto = try await site.postJSON("/api/integrity", [String: Any]()).decoded(IntegrityDTO.self)
        let expiry = Date(timeIntervalSince1970: dto.exp)
        await state.store(integrity: dto.token, expires: expiry)
        return dto.token
    }

    // MARK: - Metadata

    private func loadMetadata() async throws -> KaganeMetadata {
        if let cached = await state.metadata() { return cached }

        async let genres = site.json([GenreDTO].self, "/api/v2/genres/list")
        async let tags = site.json([TagDTO].self, "/api/v2/tags/list")
        async let sources = sourceList()

        let metadata = KaganeMetadata(
            genres: try await genres
                .map { FilterOption(id: $0.id, name: $0.name) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            sources: try await sources
                .map { FilterOption(id: $0.sourceID, name: $0.title) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            tagIndex: Dictionary(
                try await tags.map { ($0.name.lowercased(), $0.id) },
                uniquingKeysWith: { first, _ in first }
            )
        )
        await state.store(metadata: metadata)
        return metadata
    }

    private func sourceList() async throws -> [SourceDTO] {
        try await site.postJSON("/api/v2/sources/list", ["source_types": NSNull()])
            .decoded(SourcesDTO.self)
            .sources
    }

    /// `Tags (e.g. Medieval, -Politics)`: a tag id is looked up by name, `-` excludes it.
    private func tagsBody(_ filters: FilterState) async -> [String: Any]? {
        guard case .text(let raw)? = filters.value(for: Self.tagsFilter) else { return nil }
        let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, let metadata = try? await loadMetadata() else { return nil }

        var included: [String] = []
        var excluded: [String] = []
        for entry in typed.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            guard !entry.isEmpty else { continue }
            let isExcluded = entry.hasPrefix("-")
            let name = (isExcluded ? String(entry.dropFirst()) : entry)
                .trimmingCharacters(in: .whitespaces)
            guard let id = metadata.tagIndex[name.lowercased()] else { continue }
            if isExcluded { excluded.append(id) } else { included.append(id) }
        }
        guard !included.isEmpty || !excluded.isEmpty else { return nil }

        var object: [String: Any] = ["values": included]
        if Self.matchAllTags(filters) { object["match_all"] = true }
        if !excluded.isEmpty { object["exclude"] = excluded }
        return object
    }

    private func detailsDTO(_ seriesID: String) async throws -> DetailsDTO {
        if let cached = await state.details(for: seriesID) { return cached }
        let dto = try await site.json(DetailsDTO.self, "/api/v2/series/\(seriesID)")
        await state.store(details: dto, for: seriesID)
        return dto
    }

    // MARK: - Requests

    private static let sourceTypes = ["Official", "Unofficial", "Mixed"]

    private func search(page: Int, body: [String: Any], sort: String?) async throws -> EntriesPage {
        var path = "/api/v2/search/series?page=\(page - 1)&size=\(Self.pageSize)"
        if let sort, !sort.isEmpty { path += "&sort=\(sort.queryEscaped)" }

        let dto = try await site.postJSON(path, body).decoded(SearchDTO.self)
        let entries = dto.content.map { series in
            SourceEntry(
                sourceKey: key, kind: kind, url: series.id,
                title: series.title.trimmingCharacters(in: .whitespacesAndNewlines),
                thumbnailURL: series.coverImage.map { "\(apiURL)/image/\($0)" }
            )
        }
        return EntriesPage(entries: entries, hasNextPage: !dto.last)
    }

    private static let pageSize = 35

    /// The body every search sends. Filters add to it; the tags text needs the site's tag ids, so
    /// it only applies when the metadata fetch succeeds.
    private static func baseBody(filters: FilterState) -> [String: Any] {
        var body: [String: Any] = [
            "source_type": sourceTypes,
            "content_lang": ["en"],
        ]

        let ratings = ratings(from: filters)
        if !ratings.isEmpty {
            body["age_rating"] = Array(Set(ratings.map { ageRatings[$0] ?? "EighteenPlus" })).sorted()
            if !ratings.contains("pornographic") { body["is_pornographic"] = false }
        }

        if let genres = group(filters, id: Filters.genres, matchAll: matchAllGenres(filters)) {
            body["genres"] = genres
        }
        for (id, key) in [(Filters.sources, "source_id"), (Filters.formats, "format"),
                          (Filters.statuses, "upload_status")] {
            if case .options(let values)? = filters[id], !values.isEmpty {
                body[key] = values.sorted()
            }
        }
        return body
    }

    private static func group(
        _ filters: FilterState, id: String, matchAll: Bool
    ) -> [String: Any]? {
        guard case .exclude(let included, let excluded)? = filters[id],
              !included.isEmpty || !excluded.isEmpty else { return nil }
        var object: [String: Any] = ["values": included.sorted()]
        if matchAll { object["match_all"] = true }
        if !excluded.isEmpty { object["exclude"] = excluded.sorted() }
        return object
    }

    private static func ratings(from filters: FilterState) -> Set<String> {
        guard case .options(let values)? = filters.value(for: ratingFilter) else { return [] }
        return values
    }

    private static func matchAllGenres(_ filters: FilterState) -> Bool {
        guard case .checkbox(let value)? = filters.value(for: genresMatchAllFilter) else { return true }
        return value
    }

    private static func matchAllTags(_ filters: FilterState) -> Bool {
        guard case .checkbox(let value)? = filters.value(for: tagsMatchAllFilter) else { return true }
        return value
    }

    private static func sortValue(_ filters: FilterState) -> String? {
        guard case .sort(let index, let ascending)? = filters.value(for: sortFilter),
              sortValues.indices.contains(index), !sortValues[index].isEmpty else { return nil }
        return sortValues[index] + (ascending ? ",asc" : ",desc")
    }

    // MARK: - Mapping

    private static let ageRatings = [
        "safe": "Safe", "suggestive": "FifteenPlus",
        "erotica": "EighteenPlus", "pornographic": "EighteenPlus",
    ]

    /// Formats whose chapter numbers the site already publishes correctly.
    private static let sourceNumberFormats: Set<String> = [
        "Dark Horse Comics", "Flame Comics", "MangaDex", "Square Enix Manga",
    ]

    private static func seriesID(_ url: String) -> String {
        let parts = url.split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "series" { return parts[1] }
        return url.hasPrefix("/") ? String(url.dropFirst()) : url
    }

    /// Upstream can append the edition ("Show edition name in title", off by default); the port
    /// leaves it off.
    private static func title(_ dto: DetailsDTO) -> String {
        dto.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func staff(_ dto: DetailsDTO, roles: [String]) -> String? {
        let names = dto.staff
            .filter { member in roles.contains { member.role.localizedCaseInsensitiveContains($0) } }
            .map(\.name)
        var seen = Set<String>()
        let unique = names.filter { !$0.isEmpty && seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique.joined(separator: ", ")
    }

    private static func status(_ raw: String?) -> EntryStatus {
        switch raw?.uppercased() {
        case "ONGOING": .ongoing
        case "COMPLETED": .completed
        case "HIATUS": .onHiatus
        case "ABANDONED": .cancelled
        default: .unknown
        }
    }

    private static func description(_ dto: DetailsDTO) -> String {
        var blocks: [String] = []

        if let raw = dto.description?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let text = plainText(raw)
            if !text.isEmpty { blocks.append(text) }
        }

        if let rating = dto.averageRating {
            var line = "Rating: " + String(format: "%.1f", rating / 10) + "/10"
            if let count = dto.totalRatings { line += " (\(count) ratings)" }
            blocks.append(line)
        }

        if !dto.links.isEmpty {
            let lines = dto.links.map { link in
                let label = link.label.flatMap { $0.isEmpty ? nil : $0 } ?? link.url
                return "- \(label) (\(link.url))"
            }
            blocks.append("Links:\n" + lines.joined(separator: "\n"))
        }

        let alternates = dto.alternateTitles.map(\.title).filter { !$0.isEmpty }
        if !alternates.isEmpty {
            blocks.append("Alternative names:\n" + alternates.map { "- \($0)" }.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Descriptions arrive as HTML with markdown left inside it.
    private static func plainText(_ html: String) -> String {
        var text = html
        for (pattern, replacement) in [("<br\\s*/?>", "\n"), ("</(p|div|li)>", "\n"), ("<[^>]+>", "")] {
            text = text.replacingOccurrences(
                of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive]
            )
        }
        text = (try? Entities.unescape(text)) ?? text
        return text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Filters

    private enum Filters {
        static let sort = "sort", rating = "rating", formats = "formats", statuses = "statuses"
        static let genresMatchAll = "genresMatchAll", genres = "genres"
        static let tagsMatchAll = "tagsMatchAll", tags = "tags", sources = "sources"
    }

    private static let sortValues = [
        "", "total_views", "avg_views", "avg_views_today", "avg_views_week", "avg_views_month",
        "updated_at", "current_books", "created_at",
    ]

    private static let ratingOptions = ["safe", "suggestive", "erotica", "pornographic"]
        .map { FilterOption(id: $0, name: $0.prefix(1).uppercased() + $0.dropFirst()) }

    private static let ratingFilter: SourceFilter = .multiSelect(
        id: Filters.rating, name: "Content rating", options: ratingOptions,
        defaultSelection: ratingOptions.map(\.id)
    )

    private static let genresMatchAllFilter: SourceFilter = .checkbox(
        id: Filters.genresMatchAll, name: "Match all selected genres", defaultValue: true
    )

    private static let tagsMatchAllFilter: SourceFilter = .checkbox(
        id: Filters.tagsMatchAll, name: "Match all typed tags", defaultValue: true
    )

    private static let tagsFilter: SourceFilter = .text(
        id: Filters.tags, name: "Tags", hint: nil, defaultValue: ""
    )

    private static let sortFilter: SourceFilter = .sort(
        id: Filters.sort, name: "Sort by",
        options: [
            ("Relevance", ""), ("Popular (total views)", "total_views"),
            ("Popular (average views)", "avg_views"), ("Popular (today)", "avg_views_today"),
            ("Popular (this week)", "avg_views_week"), ("Popular (this month)", "avg_views_month"),
            ("Latest", "updated_at"), ("Books count", "current_books"), ("Created at", "created_at"),
        ].map { FilterOption(id: $0.1, name: $0.0) },
        defaultIndex: 0, defaultAscending: false
    )

    private static let formatOptions = ["Manga", "Manhwa", "Manhua", "Comic", "Other"]
        .map { FilterOption(id: $0, name: $0) }

    /// The filters that need nothing from the site.
    private static let baseFilters: [SourceFilter] = [
        sortFilter,
        ratingFilter,
        .separator(id: "sep1"),
        .multiSelect(
            id: Filters.formats, name: "Format", options: formatOptions, defaultSelection: []
        ),
        .multiSelect(
            id: Filters.statuses, name: "Status",
            options: [
                ("Ongoing", "Ongoing"), ("Completed", "Completed"),
                ("Hiatus", "Hiatus"), ("Cancelled", "Abandoned"),
            ].map { FilterOption(id: $0.1, name: $0.0) },
            defaultSelection: []
        ),
    ]
}

// MARK: - Session state

/// Per-source state that must outlive one call: the filter metadata (1.8 MB of tags), the details
/// payload `chapters` reads the format from, and the reader tokens.
private actor KaganeState {

    private var cachedMetadata: KaganeMetadata?
    private var cachedDetails: [String: (stored: Date, value: DetailsDTO)] = [:]
    private var cachedChallenges: [String: (stored: Date, value: ChallengeDTO)] = [:]
    private var cachedIntegrity: (token: String, expires: Date)?

    private let detailsLifetime: TimeInterval = 300
    private let challengeLifetime: TimeInterval = 3600

    func metadata() -> KaganeMetadata? { cachedMetadata }
    func store(metadata: KaganeMetadata) { cachedMetadata = metadata }

    func details(for seriesID: String) -> DetailsDTO? {
        guard let entry = cachedDetails[seriesID],
              Date().timeIntervalSince(entry.stored) < detailsLifetime else { return nil }
        return entry.value
    }

    func store(details: DetailsDTO, for seriesID: String) {
        cachedDetails[seriesID] = (Date(), details)
        if cachedDetails.count > 24 { cachedDetails.removeAll() }
    }

    func challenge(for chapterID: String) -> ChallengeDTO? {
        guard let entry = cachedChallenges[chapterID],
              Date().timeIntervalSince(entry.stored) < challengeLifetime else { return nil }
        return entry.value
    }

    func store(challenge: ChallengeDTO, for chapterID: String) {
        cachedChallenges[chapterID] = (Date(), challenge)
        if cachedChallenges.count > 32 { cachedChallenges.removeAll() }
    }

    func integrityToken() -> String? {
        guard let cachedIntegrity, cachedIntegrity.expires > Date() else { return nil }
        return cachedIntegrity.token
    }

    func store(integrity: String, expires: Date) {
        cachedIntegrity = (integrity, expires)
    }
}

private struct KaganeMetadata: Sendable {
    let genres: [FilterOption]
    let sources: [FilterOption]
    let tagIndex: [String: String]
}

// MARK: - API shapes

private struct GenreDTO: Decodable {
    let id: String
    let name: String
    enum CodingKeys: String, CodingKey { case id, name = "genre_name" }
}

private struct TagDTO: Decodable {
    let id: String
    let name: String
    enum CodingKeys: String, CodingKey { case id, name = "tag_name" }
}

private struct SourcesDTO: Decodable {
    let sources: [SourceDTO]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sources = (try? container.decodeIfPresent([SourceDTO].self, forKey: .sources)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case sources }
}

private struct SourceDTO: Decodable {
    let sourceID: String
    let title: String
    enum CodingKeys: String, CodingKey { case sourceID = "source_id", title }
}

private struct SearchDTO: Decodable {
    let content: [SeriesDTO]
    let last: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = (try? container.decodeIfPresent([SeriesDTO].self, forKey: .content)) ?? []
        last = (try? container.decodeIfPresent(Bool.self, forKey: .last)) ?? true
    }

    private enum CodingKeys: String, CodingKey { case content, last }
}

private struct SeriesDTO: Decodable {
    let id: String
    let title: String
    let coverImage: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        coverImage = try? container.decodeIfPresent(String.self, forKey: .coverImage)
    }

    private enum CodingKeys: String, CodingKey {
        case id = "series_id", title, coverImage = "cover_image_id"
    }
}

private struct DetailsDTO: Decodable, Sendable {
    let title: String
    let description: String?
    let publicationStatus: String?
    let format: String?
    let editionInfo: String?
    let averageRating: Double?
    let totalRatings: Int?
    let staff: [Staff]
    let genres: [Named]
    let alternateTitles: [Alternate]
    let links: [Link]
    let covers: [Cover]

    struct Staff: Decodable, Sendable { let name: String; let role: String }
    struct Named: Decodable, Sendable {
        let name: String?
        enum CodingKeys: String, CodingKey { case name = "genre_name" }
    }
    struct Alternate: Decodable, Sendable { let title: String }
    struct Link: Decodable, Sendable { let url: String; let label: String? }
    struct Cover: Decodable, Sendable {
        let imageID: String?
        enum CodingKeys: String, CodingKey { case imageID = "image_id" }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        description = try? container.decodeIfPresent(String.self, forKey: .description)
        publicationStatus = try? container.decodeIfPresent(String.self, forKey: .publicationStatus)
        format = try? container.decodeIfPresent(String.self, forKey: .format)
        editionInfo = try? container.decodeIfPresent(String.self, forKey: .editionInfo)
        averageRating = try? container.decodeIfPresent(Double.self, forKey: .averageRating)
        totalRatings = try? container.decodeIfPresent(Int.self, forKey: .totalRatings)
        staff = (try? container.decodeIfPresent([Staff].self, forKey: .staff)) ?? []
        genres = (try? container.decodeIfPresent([Named].self, forKey: .genres)) ?? []
        alternateTitles = (try? container.decodeIfPresent([Alternate].self, forKey: .alternateTitles)) ?? []
        links = (try? container.decodeIfPresent([Link].self, forKey: .links)) ?? []
        covers = (try? container.decodeIfPresent([Cover].self, forKey: .covers)) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case title, description, format, genres
        case publicationStatus = "upload_status"
        case editionInfo = "edition_info"
        case averageRating = "average_rating"
        case totalRatings = "total_ratings"
        case staff = "series_staff"
        case alternateTitles = "series_alternate_titles"
        case links = "series_links"
        case covers = "series_covers"
    }
}

/// The compact chapter index: one `fields` order and one row per book.
private struct BookIndexDTO: Decodable {
    let count: Int
    let fields: [String]
    let groups: [Group]
    let books: [[Cell]]

    struct Group: Decodable { let title: String }

    struct Book {
        let id: String
        let title: String
        let number: Double
        let chapterNo: String?
        let volumeNo: String?
        let releasedAt: Date?
        let groups: [String]

        var chapterName: String {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, chapterNo == nil, volumeNo != nil { return numbered(mode: "vol_chapter") }
            if trimmed.isEmpty, let chapterNo { return "Ch.\(chapterNo)" }
            return trimmed.isEmpty ? "Chapter" : trimmed
        }

        /// `vol_local`: `Vol.1 Ch.5`, and the title dropped when there is one.
        private func numbered(mode: String) -> String {
            let volume = volumeNo.map { "Vol.\($0) " } ?? ""
            let chapter = chapterNo.map { "Ch.\($0)" } ?? ""
            let numbers = (volume + chapter).trimmingCharacters(in: .whitespaces)
            if numbers.isEmpty { return title }
            if mode == "vol_local" { return numbers }
            return title.isEmpty ? numbers : "\(numbers) \(title)"
        }

        /// Scanlator groups, plus the group a title names in brackets.
        var scanlator: String? {
            var name = groups.joined(separator: ", ")
            if let tag = BookIndexDTO.groupTag(in: title) {
                name += name.isEmpty ? tag : " (\(tag))"
            }
            return name.isEmpty ? nil : name
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        count = (try? container.decodeIfPresent(Int.self, forKey: .count)) ?? 0
        fields = (try? container.decodeIfPresent([String].self, forKey: .fields)) ?? []
        groups = (try? container.decodeIfPresent([Group].self, forKey: .groups)) ?? []
        books = (try? container.decodeIfPresent([[Cell]].self, forKey: .books)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case count, fields, groups, books }

    func rows() throws -> [Book] {
        guard books.count == count else {
            throw SourceError.parseFailed("chapter index: \(books.count) of \(count) rows")
        }
        return books.map { row in
            var values: [String: Cell] = [:]
            for (name, cell) in zip(fields, row) { values[name] = cell }

            return Book(
                id: values["book_id"]?.text ?? "",
                title: values["title"]?.text ?? "",
                number: values["sort_no"]?.number ?? -1,
                chapterNo: values["chapter_no"]?.text,
                volumeNo: values["volume_no"]?.text,
                releasedAt: values["released_at"]?.number.map { Date(timeIntervalSince1970: $0) },
                groups: (values["group_ix"]?.indices ?? []).compactMap { index in
                    groups.indices.contains(index) ? groups[index].title : nil
                }
            )
        }
    }

    /// `Chapter 12 - Volume 1 (Group Name)` → `Group Name`, after any trailing `{…}` metadata.
    static func groupTag(in title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let stripped = metadataPattern.stringByReplacingMatches(
            in: trimmed, range: range, withTemplate: ""
        ).trimmingCharacters(in: .whitespaces)

        let strippedRange = NSRange(stripped.startIndex..., in: stripped)
        guard let match = chapterGroupPattern.firstMatch(in: stripped, range: strippedRange) else {
            return nil
        }
        for group in 1...2 where match.range(at: group).location != NSNotFound {
            if let range = Range(match.range(at: group), in: stripped) { return String(stripped[range]) }
        }
        return nil
    }

    private static let metadataPattern = try! NSRegularExpression(pattern: #"(?:\s*\{[^{}]*\})+\s*$"#)

    private static let chapterGroupPattern = try! NSRegularExpression(
        pattern: #"^Chapter\s+.*(?:-\s*Volume\s+.*\(([^()]+)\)|\[([^\[\]]+)\])\s*$"#,
        options: .caseInsensitive
    )
}

/// One cell of a chapter index row: a string, a number, a list of indexes or null.
private enum Cell: Decodable {
    case text(String)
    case number(Double)
    case indices([Int])
    case empty

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .empty
        } else if let value = try? container.decode(String.self) {
            self = .text(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([Int].self) {
            self = .indices(value)
        } else {
            self = .empty
        }
    }

    var text: String? {
        switch self {
        case .text(let value): value.isEmpty ? nil : value
        case .number(let value): value == value.rounded() ? String(Int(value)) : String(value)
        case .indices, .empty: nil
        }
    }

    var number: Double? {
        switch self {
        case .number(let value): value
        case .text(let value): Double(value)
        case .indices, .empty: nil
        }
    }

    var indices: [Int]? {
        if case .indices(let value) = self { return value }
        return nil
    }
}

private struct ChallengeDTO: Decodable, Sendable {
    let accessToken: String
    let cacheURL: String
    let manifest: Manifest?

    struct Manifest: Decodable, Sendable { let pages: [Page] }
    struct Page: Decodable, Sendable {
        let pageID: String
        let ext: String?
        enum CodingKeys: String, CodingKey { case pageID = "page_id", ext }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = (try? container.decode(String.self, forKey: .accessToken)) ?? ""
        cacheURL = (try? container.decode(String.self, forKey: .cacheURL)) ?? ""
        manifest = try? container.decodeIfPresent(Manifest.self, forKey: .manifest)
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", cacheURL = "cache_url", manifest
    }
}

private struct IntegrityDTO: Decodable {
    let token: String
    let exp: Double
}
