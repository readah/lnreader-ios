// AtsumaruSource.swift - Atsumaru (atsu.moe), ported from keiyoushi's src/en/atsumaru.
//
// A JSON API site: browse, search and the chapter list are all `/api/...` endpoints, and the
// search endpoint is Typesense-shaped (`filter_by`, `query_by`, `hits`). Entry urls are the bare
// manga id and chapter urls are `<mangaId>/<chapterId>`, exactly what the Kotlin extension stores,
// so a Mihon backup resolves.
//
// Upstream has four preferences — 18+ browse, excluded browse genres, de-duplicating chapters and
// a scanlator blacklist. The app has no per-source preference screen, so the port runs with
// upstream's defaults (no 18+ content, nothing excluded, every upload listed) and exposes the
// adult choice as a filter instead. Its 2 req/s limit is not ported either: rate limiting is
// global, per source and host, in `RateLimitInterceptor`.
//
// Descriptions are built as plain text, not the markdown upstream emits: the detail screen renders
// the summary verbatim, so `**Rating**` would show its asterisks.

import Foundation

final class AtsumaruSource: MangaSource {

    /// `MihonSourceID.make(name: "Atsumaru", lang: "en", versionId: 2)`.
    static let mihonID = MihonSourceID.make(name: "Atsumaru", lang: "en", versionId: 2)

    let key = SourceKey.makeBuiltin(id: "atsumaru")
    let kind = ContentKind.manga
    let name = "Atsumaru"
    let lang = "en"
    let iconAsset: String? = "AtsumaruIcon"
    let supportsLatest = true
    let filtersAreRemote = true

    private let site = SiteClient(
        sourceKey: SourceKey.makeBuiltin(id: "atsumaru"),
        baseURL: "https://atsu.moe",
        headers: ["Accept": "*/*", "Content-Type": "application/json"]
    )

    var homepage: URL? { URL(string: site.baseURL) }

    /// Pages are served from `cdn.atsu.moe`; `atsu.moe/static/...` answers 410.
    private let cdnURL = "https://cdn.atsu.moe"

    private static let pageSize = 40
    private static let browseQuery = "types=Manga,Manwha,Manhua,OEL&mediums=Comic"

    func filtersAreComplete(_ filters: [SourceFilter]) -> Bool {
        let ids = Set(filters.map(\.id))
        return ids.contains(Filters.genres) && ids.contains(Filters.tags)
    }

    // MARK: - Browsing

    func popular(page: Int, filters: FilterState) async throws -> EntriesPage {
        let offset = (page - 1) * Self.pageSize
        let dto = try await site.json(
            BrowseDTO.self,
            "/api/home2/popular?offset=\(offset)&limit=\(Self.pageSize)&\(Self.browseQuery)&timeframe=daily"
        )
        return EntriesPage(entries: dto.items.map { entry($0) }, hasNextPage: true)
    }

    func latest(page: Int, filters: FilterState) async throws -> EntriesPage {
        let offset = (page - 1) * Self.pageSize
        let dto = try await site.json(
            BrowseDTO.self,
            "/api/home2/recentlyUpdated?offset=\(offset)&limit=\(Self.pageSize)&\(Self.browseQuery)"
        )
        return EntriesPage(entries: dto.items.map { entry($0) }, hasNextPage: true)
    }

    func search(query: String, page: Int, filters: FilterState) async throws -> EntriesPage {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        var params: [(String, String)] = [
            ("q", trimmed.isEmpty ? "*" : trimmed),
            ("filter_by", Self.filterBy(filters)),
        ]
        if let sort = Self.sortValue(filters) { params.append(("sort_by", sort)) }
        if !trimmed.isEmpty {
            params.append(("query_by", "title,englishTitle,otherNames,authors"))
            params.append(("query_by_weights", "4,3,2,1"))
            params.append(("num_typos", "4,3,2,1"))
        }
        params.append(("page", String(page)))
        params.append(("per_page", String(Self.pageSize)))

        let queryString = params.map { "\($0.0)=\($0.1.queryEscaped)" }.joined(separator: "&")
        let response = try await site.send("/collections/manga/documents/search?" + queryString)
        let text = response.text

        // The endpoint answers in two shapes: Typesense hits when it can, a plain browse page
        // otherwise.
        if text.contains("\"hits\"") {
            let dto = try response.decoded(SearchDTO.self)
            let perPage = dto.requestParams?.perPage ?? Self.pageSize
            return EntriesPage(
                entries: dto.hits.map { entry($0.document) },
                hasNextPage: page * perPage < dto.found
            )
        }
        let dto = try response.decoded(BrowseDTO.self)
        return EntriesPage(entries: dto.items.map { entry($0) }, hasNextPage: true)
    }

    func filters() async throws -> [SourceFilter] {
        let data = try await site.json(FilterDataDTO.self, "/api/explore/availableFilters")

        var filters: [SourceFilter] = [
            .excludable(
                id: Filters.genres, name: "Genres",
                options: (data.genres ?? []).map { FilterOption(id: $0.id, name: $0.name) },
                defaultIncluded: [], defaultExcluded: []
            ),
            // 6000+ tags: one searchable list rather than upstream's per-letter groups.
            .excludable(
                id: Filters.tags, name: "Tags",
                options: (data.tags ?? []).map { FilterOption(id: $0.id, name: $0.name) },
                defaultIncluded: [], defaultExcluded: []
            ),
            .separator(id: "sep1"),
            .multiSelect(
                id: Filters.types, name: "Type",
                options: (data.types ?? []).map { FilterOption(id: $0.id, name: $0.name) },
                defaultSelection: []
            ),
            .multiSelect(
                id: Filters.statuses, name: "Publishing status",
                options: (data.statuses ?? []).map { FilterOption(id: $0.id, name: $0.name) },
                defaultSelection: []
            ),
            .separator(id: "sep2"),
        ]
        filters += Self.trailingFilters
        return filters
    }

    // MARK: - Details

    func webURL(_ entryURL: String) -> URL? { URL(string: site.absolute("/manga/\(entryURL)")) }

    func details(_ entry: SourceEntry) async throws -> SourceEntry {
        let dto = try await site.json(
            MangaObjectDTO.self, "/api/manga/page?id=\(entry.url.queryEscaped)"
        )
        return self.entry(dto.mangaPage, fallbackURL: entry.url)
    }

    func chapters(_ entry: SourceEntry) async throws -> [SourceChapter] {
        // Scanlator names only appear in the details payload, keyed by the id a chapter carries.
        let details = try? await site.json(MangaObjectDTO.self, "/api/manga/page?id=\(entry.url.queryEscaped)")
        var scanlators: [String: String] = [:]
        for scanlator in details?.mangaPage.scanlators ?? [] {
            scanlators[scanlator.id] = scanlator.name
        }

        let dto = try await site.json(
            AllChaptersDTO.self, "/api/manga/allChapters?mangaId=\(entry.url.queryEscaped)"
        )
        return dto.chapters.map { chapter in
            SourceChapter(
                url: "\(entry.url)/\(chapter.id)",
                name: chapter.title.isEmpty ? "Chapter \(Self.numberText(chapter.number))" : chapter.title,
                chapterNumber: chapter.number,
                scanlator: chapter.scanlationMangaId.flatMap { scanlators[$0] },
                dateUpload: chapter.createdAt.map { Date(timeIntervalSince1970: $0 / 1000) }
            )
        }
    }

    // MARK: - Pages

    func pages(_ chapter: SourceChapter) async throws -> [SourcePage] {
        let parts = chapter.url.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw SourceError.entryNotFound(chapter.url) }
        let dto = try await site.json(
            PageObjectDTO.self,
            "/api/read/chapter?mangaId=\(parts[0].queryEscaped)&chapterId=\(parts[1].queryEscaped)"
        )
        return dto.readChapter.pages.enumerated().map { index, page in
            SourcePage(index: index, url: Self.imageURL(page.image, cdn: cdnURL))
        }
    }

    func imageRequest(_ page: SourcePage) async throws -> URLRequest {
        guard let url = URL(string: page.url) else { throw HTTPError.invalidURL(page.url) }
        var request = URLRequest(url: url)
        request.setValue("image/avif,image/webp,*/*", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: - Mapping

    private func entry(_ manga: MangaDTO, fallbackURL: String? = nil) -> SourceEntry {
        SourceEntry(
            sourceKey: key,
            kind: kind,
            url: fallbackURL ?? manga.id,
            title: manga.title,
            thumbnailURL: Self.thumbnail(manga, cdn: cdnURL),
            author: Self.joined(manga.authors, types: ["Author", nil]),
            artist: Self.joined(manga.authors, types: ["Artist"]),
            description: manga.plainDescription,
            genres: manga.genreNames,
            status: Self.status(manga.status)
        )
    }

    private static func status(_ raw: String?) -> EntryStatus {
        switch raw?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "ongoing": .ongoing
        case "completed": .completed
        case "hiatus": .onHiatus
        case "canceled", "cancelled": .cancelled
        default: .unknown
        }
    }

    private static func joined(_ authors: [NamedField]?, types: [String?]) -> String? {
        let names = (authors ?? [])
            .filter { author in types.contains { expected in expected == author.type } }
            .compactMap(\.name)
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    /// `largeImage`, else `poster`/`image`. `atsu.moe/static/...` only 301s to the CDN, so the
    /// cover points there directly.
    private static func thumbnail(_ manga: MangaDTO, cdn: String) -> String? {
        guard let path = manga.imagePath else { return nil }
        return imageURL(path, cdn: cdn)
    }

    /// An image path or url on `cdn`. `atsu.moe/static/pages/...` answers 410.
    private static func imageURL(_ raw: String, cdn: String) -> String {
        if raw.hasPrefix("http") {
            return raw.replacingOccurrences(
                of: #"^https?://atsu\.moe/"#, with: cdn + "/", options: .regularExpression
            )
        }
        if raw.hasPrefix("//") { return "https:" + raw }
        var relative = raw
        for prefix in ["/", "static/"] where relative.hasPrefix(prefix) {
            relative.removeFirst(prefix.count)
        }
        return cdn + "/static/" + relative
    }

    static func numberText(_ number: Double) -> String {
        number == number.rounded() && abs(number) < 1e9 ? String(Int(number)) : String(number)
    }

    // MARK: - Query building

    private enum Filters {
        static let genres = "genres", tags = "tags", types = "types", statuses = "statuses"
        static let year = "year", minChapters = "minChapters", sort = "sort"
        static let adult = "adult", official = "official"
    }

    private static let sortValues = ["views", "trending", "dateAdded", "released", "mbRating", "title"]

    /// The filters that do not depend on the site's metadata, in the order the sheet shows them.
    private static let trailingFilters: [SourceFilter] = [
        .text(id: Filters.year, name: "Year", hint: "e.g. 2024", defaultValue: ""),
        .text(id: Filters.minChapters, name: "Minimum chapters", hint: nil, defaultValue: ""),
        .sort(
            id: Filters.sort, name: "Sort by",
            options: [
                FilterOption(id: "views", name: "Popularity"),
                FilterOption(id: "trending", name: "Trending"),
                FilterOption(id: "dateAdded", name: "Date added"),
                FilterOption(id: "released", name: "Release date"),
                FilterOption(id: "mbRating", name: "Top rated"),
                FilterOption(id: "title", name: "Title"),
            ],
            defaultIndex: 0, defaultAscending: false
        ),
        .checkbox(id: Filters.adult, name: "Show adult content", defaultValue: false),
        .checkbox(id: Filters.official, name: "Only official translations", defaultValue: false),
    ]

    private static func sortValue(_ filters: FilterState) -> String? {
        guard let definition = trailingFilters.first(where: { $0.id == Filters.sort }),
              case .sort(let index, let ascending)? = filters.value(for: definition),
              sortValues.indices.contains(index) else { return nil }
        return sortValues[index] + ":" + (ascending ? "asc" : "desc")
    }

    /// Typesense `filter_by`, clause for clause as upstream builds it.
    private static func filterBy(_ filters: FilterState) -> String {
        var clauses = ["hidden:!=true"]

        if case .exclude(let included, let excluded)? = filters[Filters.genres] {
            if !included.isEmpty {
                clauses.append(included.sorted().map { "genreIds:=`\($0)`" }.joined(separator: " && "))
            }
            if !excluded.isEmpty {
                clauses.append("genreIds:!=[\(excluded.sorted().map { "`\($0)`" }.joined(separator: ","))]")
            }
        }
        if case .exclude(let included, let excluded)? = filters[Filters.tags] {
            if !included.isEmpty {
                clauses.append(included.sorted().map { "tagIds:=`\($0)`" }.joined(separator: " && "))
            }
            if !excluded.isEmpty {
                clauses.append("tagIds:!=[\(excluded.sorted().map { "`\($0)`" }.joined(separator: ","))]")
            }
        }
        if case .options(let types)? = filters[Filters.types], !types.isEmpty {
            clauses.append("type:=[\(types.sorted().map { "`\($0)`" }.joined(separator: ","))]")
        }
        if case .options(let statuses)? = filters[Filters.statuses], !statuses.isEmpty {
            clauses.append("status:=[\(statuses.sorted().map { "`\($0)`" }.joined(separator: ","))]")
        }
        if case .text(let year)? = filters[Filters.year],
           let value = Int(year.trimmingCharacters(in: .whitespaces)), value > 0 {
            clauses.append("releaseYear:=[\(value)]")
        }
        if case .text(let chapters)? = filters[Filters.minChapters],
           let value = Int(chapters.trimmingCharacters(in: .whitespaces)), value > 0 {
            clauses.append("chapterCount:>=\(value)")
        }
        // An untouched checkbox reads as `nil`, and its default is "off": adult content stays out
        // unless the user ticks the filter.
        let showAdult: Bool
        if case .checkbox(let value)? = filters[Filters.adult] { showAdult = value } else { showAdult = false }
        if !showAdult { clauses.append("isAdult:=false") }
        if case .checkbox(true)? = filters[Filters.official] {
            clauses.append("officialTranslation:=true")
        }

        clauses.append("(mbContentRating:=[`Safe`,`Suggestive`,`Erotica`] || mbContentRating:!=*)")
        clauses.append("medium:!=[`Novel`]")
        clauses.append("views:>0")
        return clauses.joined(separator: " && ")
    }
}

// MARK: - API shapes

private struct BrowseDTO: Decodable {
    let items: [MangaDTO]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? container.decodeIfPresent([MangaDTO].self, forKey: .items)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case items }
}

private struct MangaObjectDTO: Decodable {
    let mangaPage: MangaDTO
}

private struct SearchDTO: Decodable {
    let found: Int
    let hits: [Hit]
    let requestParams: RequestParams?

    struct Hit: Decodable { let document: MangaDTO }

    struct RequestParams: Decodable {
        let perPage: Int?
        enum CodingKeys: String, CodingKey { case perPage = "per_page" }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        found = (try? container.decodeIfPresent(Int.self, forKey: .found)) ?? 0
        hits = (try? container.decodeIfPresent([Hit].self, forKey: .hits)) ?? []
        requestParams = try? container.decodeIfPresent(RequestParams.self, forKey: .requestParams)
    }

    private enum CodingKeys: String, CodingKey {
        case found, hits
        case requestParams = "request_params"
    }
}

private struct AllChaptersDTO: Decodable {
    let chapters: [ChapterDTO]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chapters = (try? container.decodeIfPresent([ChapterDTO].self, forKey: .chapters)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case chapters }
}

private struct PageObjectDTO: Decodable {
    let readChapter: Reader

    struct Reader: Decodable { let pages: [PageDTO] }
    struct PageDTO: Decodable { let image: String }
}

private struct ChapterDTO: Decodable {
    let id: String
    let number: Double
    let title: String
    let scanlationMangaId: String?
    let createdAt: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        number = (try? container.decode(Double.self, forKey: .number)) ?? -1
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        scanlationMangaId = try? container.decodeIfPresent(String.self, forKey: .scanlationMangaId)
        createdAt = (try? container.decodeIfPresent(Double.self, forKey: .createdAt))
            ?? (try? container.decodeIfPresent(String.self, forKey: .createdAt)).flatMap(Double.init)
    }

    private enum CodingKeys: String, CodingKey {
        case id, number, title, createdAt
        case scanlationMangaId
    }
}

private struct ScanlatorDTO: Decodable {
    let id: String
    let name: String
}

private struct FilterDataDTO: Decodable {
    let genres: [FilterEntryDTO]?
    let tags: [FilterEntryDTO]?
    let types: [FilterEntryDTO]?
    let statuses: [FilterEntryDTO]?
}

private struct FilterEntryDTO: Decodable {
    let id: String
    let name: String
}

/// A manga as the browse, search and details endpoints describe it.
///
/// The same field arrives in several shapes: `released` is millis as a number or a string, `views`
/// is `116.3K`, `genres` and `authors` are either strings or objects, and `poster` is either a path
/// or an object of paths. Every field is decoded defensively so one odd entry cannot fail a page.
private struct MangaDTO: Decodable {
    let id: String
    let title: String
    let imagePath: String?
    let authors: [NamedField]?
    let synopsis: String?
    let genres: [NamedField]?
    let released: Double?
    let status: String?
    let type: String?
    let views: String?
    let otherNames: [String]?
    let avgRating: Double?
    let scanlators: [ScanlatorDTO]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        imagePath = Self.poster(container)
        authors = try? container.decodeIfPresent([NamedField].self, forKey: .authors)
        synopsis = try? container.decodeIfPresent(String.self, forKey: .synopsis)
        // `genres` and `tags` name the same list on different endpoints.
        genres = (try? container.decodeIfPresent([NamedField].self, forKey: .genres))
            ?? (try? container.decodeIfPresent([NamedField].self, forKey: .tags))
        released = (try? container.decodeIfPresent(Double.self, forKey: .released))
            ?? (try? container.decodeIfPresent(String.self, forKey: .released)).flatMap(Double.init)
        status = try? container.decodeIfPresent(String.self, forKey: .status)
        type = try? container.decodeIfPresent(String.self, forKey: .type)
        views = (try? container.decodeIfPresent(String.self, forKey: .views))
            ?? (try? container.decodeIfPresent(Int.self, forKey: .views)).map(String.init)
        otherNames = try? container.decodeIfPresent([String].self, forKey: .otherNames)
        avgRating = (try? container.decodeIfPresent(Double.self, forKey: .avgRating))
            ?? (try? container.decodeIfPresent(String.self, forKey: .avgRating)).flatMap(Double.init)
        scanlators = try? container.decodeIfPresent([ScanlatorDTO].self, forKey: .scanlators)
    }

    /// `largeImage` first, then `poster` / `image` (a path or an object of paths).
    private static func poster(_ container: KeyedDecodingContainer<CodingKeys>) -> String? {
        if let large = try? container.decodeIfPresent(String.self, forKey: .largeImage), !large.isEmpty {
            return large
        }
        for key in [CodingKeys.poster, .image] {
            if let path = try? container.decodeIfPresent(String.self, forKey: key), !path.isEmpty {
                return path
            }
            if let object = try? container.decodeIfPresent([String: String].self, forKey: key) {
                if let large = object["largeImage"], !large.isEmpty { return large }
                if let image = object["image"], !image.isEmpty { return image }
            }
        }
        return nil
    }

    var genreNames: [String] {
        var names: [String] = []
        if let type, !type.isEmpty { names.append(type) }
        names += (genres ?? []).compactMap(\.name)
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Synopsis first, then the numbers, in the app's plain-text house style.
    var plainDescription: String {
        var blocks: [String] = []
        if let synopsis, !synopsis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(synopsis.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var info: [String] = []
        if let avgRating, avgRating > 0 {
            info.append("Rating: " + String(format: "%.2f", avgRating) + "/10")
        }
        if let released, released > 0 {
            let date = Date(timeIntervalSince1970: released / 1000)
            let year = Calendar.current.component(.year, from: date)
            info.append("Year: \(year)")
        }
        if let views, !views.isEmpty { info.append("Views: \(views)") }
        if !info.isEmpty { blocks.append(info.joined(separator: "\n")) }

        let alternates = (otherNames ?? []).filter { $0 != title && !$0.isEmpty }
        if !alternates.isEmpty {
            blocks.append("Alternative names:\n" + alternates.map { "- \($0)" }.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, image, poster, largeImage, authors, synopsis, genres, tags
        case released, status, type, views, otherNames, avgRating, scanlators
    }
}

/// One author or genre: a plain string, or an object with `name` (authors also carry a `type`).
private enum NamedField: Decodable {
    case plain(String)
    case object(name: String, type: String?)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .plain(value)
            return
        }
        struct Payload: Decodable {
            let name: String?
            let type: String?
        }
        let payload = (try? container.decode(Payload.self)) ?? Payload(name: nil, type: nil)
        self = .object(name: payload.name ?? "", type: payload.type)
    }

    var name: String? {
        switch self {
        case .plain(let value): value.isEmpty ? nil : value
        case .object(let name, _): name.isEmpty ? nil : name
        }
    }

    var type: String? {
        switch self {
        case .plain: nil
        case .object(_, let type): type
        }
    }
}
