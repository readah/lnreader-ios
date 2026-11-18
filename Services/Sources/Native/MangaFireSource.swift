// MangaFireSource.swift - MangaFire, ported from keiyoushi/extensions-source src/all/mangafire.
//
// The site has a JSON API under `/api/`. Every request carries a `vrf` query value computed by
// `MangaFireVrf` over the sorted query string, so nothing here can skip the signer.
//
// Urls are source-relative and keep the shape the earlier JS port stored:
// entries `/title/<hid>-<slug>` (or Mihon's `/manga/<slug>.<hid>`), chapters `/chapter/<id>`
// (or `/manga/<slug>/<id>-chapter-<n>-en` under an old-shape entry).

import Foundation
import SwiftSoup

final class MangaFireSource: MangaSource {

    static let mihonID = MihonSourceID.make(name: "MangaFire", lang: "en")

    let key = SourceKey.makeBuiltin(id: "mangafire")
    let kind = ContentKind.manga
    let name = "MangaFire"
    let lang = "en"
    let iconAsset: String? = "MangaFireIcon"
    let supportsLatest = true

    private let langCode = "en"
    private let site = SiteClient(
        sourceKey: SourceKey.makeBuiltin(id: "mangafire"),
        baseURL: "https://mangafire.to",
        headers: ["Accept": "application/json", "Referer": "https://mangafire.to/"]
    )

    var homepage: URL? { URL(string: site.baseURL) }

    // MARK: Browsing

    func popular(page: Int, filters: FilterState) async throws -> EntriesPage {
        try await list([
            ("order[views_30d]", "desc"), ("languages[]", langCode),
            ("page", String(page)), ("limit", "50"),
        ], page: page)
    }

    func latest(page: Int, filters: FilterState) async throws -> EntriesPage {
        try await list([
            ("order[chapter_updated_at]", "desc"), ("languages[]", langCode),
            ("page", String(page)), ("limit", "50"),
        ], page: page)
    }

    func search(query: String, page: Int, filters: FilterState) async throws -> EntriesPage {
        var params: [(String, String)] = []
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { params.append(("keyword", trimmed)) }
        params += [("languages[]", langCode), ("page", String(page)), ("limit", "50")]

        for filter in SourceFilter.flatten(Self.filterDefinitions) {
            guard let selection = filters.value(for: filter) else { continue }
            switch (filter.id, selection) {
            case (Filters.author, .text(let text)):
                let author = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if author.isEmpty { continue }
                guard let id = try await authorID(author) else { return EntriesPage(entries: []) }
                params.append(("authors[]", id))
            case (Filters.mode, .option(let mode)):
                params += [("genres_mode", mode), ("theme_mode", mode)]
            case (Filters.sort, .option(let sort)):
                let parts = sort.split(separator: ":").map(String.init)
                if parts.count == 2 { params.append(("order[\(parts[0])]", parts[1])) }
            case (Filters.minChapters, .text(let text)):
                if let value = Int(text.trimmingCharacters(in: .whitespaces)), value > 0 {
                    params.append(("min_chap", String(value)))
                }
            case (Filters.yearFrom, .text(let text)):
                if let value = Int(text.trimmingCharacters(in: .whitespaces)) { params.append(("year_from", String(value))) }
            case (Filters.yearTo, .text(let text)):
                if let value = Int(text.trimmingCharacters(in: .whitespaces)) { params.append(("year_to", String(value))) }
            case (Filters.genres, .exclude(let included, let excluded)):
                params += included.sorted().map { ("genres_in[]", $0) }
                params += excluded.sorted().map { ("genres_ex[]", $0) }
            case (let id, .options(let values)):
                if let param = Self.multiParams[id] { params += values.sorted().map { (param, $0) } }
            default:
                break
            }
        }
        return try await list(params, page: page)
    }

    func filters() async throws -> [SourceFilter] { Self.filterDefinitions }

    // MARK: Details

    func webURL(_ entryURL: String) -> URL? { URL(string: site.absolute(entryURL)) }

    func details(_ entry: SourceEntry) async throws -> SourceEntry {
        let response: DetailsResponse = try await api("/titles/\(Self.hid(of: entry.url))")
        let data = response.data
        var genres: [String] = []
        if let type = data.type, !type.isEmpty { genres.append(type.prefix(1).uppercased() + type.dropFirst()) }
        genres += (data.genres ?? []).map(\.title) + (data.themes ?? []).map(\.title)

        return SourceEntry(
            sourceKey: key, kind: kind, url: entry.url, title: data.title,
            thumbnailURL: data.poster?.best ?? entry.thumbnailURL,
            author: Self.names(data.authors), artist: Self.names(data.artists),
            description: data.synopsisHtml.map(Self.plainText),
            genres: genres, status: Self.status(data.status)
        )
    }

    func chapters(_ entry: SourceEntry) async throws -> [SourceChapter] {
        let hid = Self.hid(of: entry.url)
        let legacy = entry.url.hasPrefix("/manga/")
        let slugSegments = entry.url.split(separator: "/", omittingEmptySubsequences: false)
        let prefix = "/manga/" + (slugSegments.count > 2 ? String(slugSegments[2]) : "")

        var out: [SourceChapter] = []
        var page = 1
        var lastPage = 1
        repeat {
            let response: ListResponse<ChapterDTO> = try await api("/titles/\(hid)/chapters", [
                ("language", langCode), ("limit", "200"), ("order", "asc"),
                ("page", String(page)), ("sort", "number"),
            ])
            for item in response.items {
                let number = Self.numberString(item.number)
                // An entry saved under the old shape keeps old-shape chapter urls, so read state
                // restored from a backup still lines up.
                let url = legacy ? "\(prefix)/\(item.id)-chapter-\(number)-\(langCode)" : "/chapter/\(item.id)"
                let title = (item.name?.isEmpty == false) ? item.name! : "Chapter \(number)"
                out.append(SourceChapter(
                    url: url, name: title, chapterNumber: item.number, scanlator: item.type,
                    dateUpload: item.createdAt.map { Date(timeIntervalSince1970: $0) }
                ))
            }
            lastPage = response.meta?.lastPage ?? 1
            page += 1
        } while page <= lastPage && page <= 50
        return out
    }

    func pages(_ chapter: SourceChapter) async throws -> [SourcePage] {
        let segments = chapter.url.split(separator: "/").map(String.init)
        guard let last = segments.last else { throw SourceError.entryNotFound(chapter.url) }
        let path: String
        if segments.contains("volume") {
            path = "/volumes/\(last)"
        } else {
            let id = last.split(separator: "-").first.map(String.init) ?? last
            guard Int(id) != nil else { throw SourceError.entryNotFound(chapter.url) }
            path = "/chapters/\(id)"
        }
        let response: PagesResponse = try await api(path)
        return response.data.pages.enumerated().map { index, page in
            SourcePage(index: index, url: page.url, headers: ["Referer": site.baseURL + "/"])
        }
    }

    // MARK: API

    private func list(_ params: [(String, String)], page: Int) async throws -> EntriesPage {
        let response: ListResponse<TitleDTO> = try await api("/titles", params)
        let meta = response.meta
        let hasNext = meta?.hasNext == true || meta?.lastPage.map { page < $0 } == true
        return EntriesPage(entries: response.items.map(entry), hasNextPage: hasNext)
    }

    private func entry(_ item: TitleDTO) -> SourceEntry {
        let url = item.url ?? "/title/\(item.hid)" + (item.slug.map { "-\($0)" } ?? "")
        return SourceEntry(
            sourceKey: key, kind: kind, url: url, title: item.title,
            thumbnailURL: item.poster?.best, status: Self.status(item.status)
        )
    }

    private func authorID(_ name: String) async throws -> String? {
        let response: TagResponse = try await api("/tags", [("keyword", name)])
        return response.data.first { $0.type == "author" || $0.type == "artist" }.map { String($0.id) }
    }

    /// GET `/api/<path>` with the signed query. `params` are sorted for signing exactly as upstream's
    /// interceptor does and percent-encoded only on the wire.
    private func api<T: Decodable>(_ path: String, _ params: [(String, String)] = []) async throws -> T {
        let sorted = params.enumerated()
            .sorted { $0.element.0 == $1.element.0 ? $0.offset < $1.offset : $0.element.0 < $1.element.0 }
            .map(\.element)
        let url = "/api" + path + "?" + MangaFireVrf.query(path: path, sortedParams: sorted)
        return try await site.json(T.self, url)
    }

    // MARK: Mapping

    private static func status(_ value: String?) -> EntryStatus {
        switch value?.lowercased() {
        case "releasing": .ongoing
        case "finished": .completed
        case "discontinued": .cancelled
        case "on_hiatus": .onHiatus
        default: .unknown
        }
    }

    private static func names(_ entities: [EntityDTO]?) -> String? {
        guard let entities, !entities.isEmpty else { return nil }
        return entities.map(\.title).joined(separator: ", ")
    }

    /// `1` for 1.0, `1.5` for 1.5, matching how the site and the old port wrote chapter numbers.
    private static func numberString(_ number: Double) -> String {
        number == number.rounded() && abs(number) < 1e9 ? String(Int(number)) : String(number)
    }

    private static func plainText(_ html: String) -> String {
        var text = html
        for (pattern, replacement) in [("<br\\s*/?>", "\n"), ("</(p|div|li)>", "\n"), ("<[^>]+>", "")] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        text = (try? Entities.unescape(text)) ?? text
        return text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The title id inside either url shape: `/title/728q1-overgeared`, `/manga/overgeared.728q1`.
    static func hid(of url: String) -> String {
        var last = url.hasSuffix("/") ? String(url.dropLast()) : url
        last = last.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? last
        if let dot = last.lastIndex(of: ".") { return String(last[last.index(after: dot)...]) }
        if let dash = last.firstIndex(of: "-") { return String(last[..<dash]) }
        return last
    }

    // MARK: Filters

    private enum Filters {
        static let rating = "contentRating", types = "types", mode = "genreMode", genres = "genres"
        static let themes = "themes", status = "status", author = "author", yearFrom = "yearFrom"
        static let yearTo = "yearTo", minChapters = "minChapters", sort = "sort"
    }

    /// Multi-select filter id to the query parameter each picked value is sent under.
    private static let multiParams = [
        Filters.rating: "content_rating[]", Filters.types: "types[]",
        Filters.themes: "theme_ids[]", Filters.status: "statuses[]",
    ]

    private static func options(_ pairs: [(String, String)]) -> [FilterOption] {
        pairs.map { FilterOption(id: $0.1, name: $0.0) }
    }

    private static let filterDefinitions: [SourceFilter] = [
        .multiSelect(
            id: Filters.rating, name: "Content rating",
            options: options(["Safe", "Suggestive", "Erotica", "Pornographic"].map { ($0, $0.lowercased()) }),
            defaultSelection: []
        ),
        .separator(id: "sep1"),
        .multiSelect(
            id: Filters.types, name: "Type",
            options: options([("Manga", "manga"), ("Manhwa", "manhwa"), ("Manhua", "manhua"), ("Other", "other")]),
            defaultSelection: []
        ),
        .separator(id: "sep2"),
        .select(
            id: Filters.mode, name: "Genre and theme match mode",
            options: options([("AND", "and"), ("OR", "or")]), defaultOption: "and"
        ),
        .excludable(
            id: Filters.genres, name: "Genres", options: options(genreList),
            defaultIncluded: [], defaultExcluded: []
        ),
        .separator(id: "sep3"),
        .multiSelect(id: Filters.themes, name: "Themes", options: options(themeList), defaultSelection: []),
        .separator(id: "sep4"),
        .multiSelect(
            id: Filters.status, name: "Status",
            options: options([
                ("Releasing", "releasing"), ("Finished", "finished"), ("On Hiatus", "on_hiatus"),
                ("Discontinued", "discontinued"), ("Not Yet Released", "not_yet_released"),
            ]),
            defaultSelection: []
        ),
        .separator(id: "sep5"),
        .text(id: Filters.author, name: "Author / Artist", hint: nil, defaultValue: ""),
        .text(id: Filters.yearFrom, name: "Release year (From)", hint: nil, defaultValue: ""),
        .text(id: Filters.yearTo, name: "Release year (To)", hint: nil, defaultValue: ""),
        .text(id: Filters.minChapters, name: "Minimum chapters", hint: nil, defaultValue: ""),
        .separator(id: "sep6"),
        .select(
            id: Filters.sort, name: "Sort by",
            options: options([
                ("Latest update", "chapter_updated_at:desc"), ("Best match", "relevance:desc"),
                ("Recently added", "created_at:desc"), ("Title (A–Z)", "title:asc"),
                ("Title (Z–A)", "title:desc"), ("Year (newest)", "year:desc"),
                ("Year (oldest)", "year:asc"), ("Highest rated", "score:desc"),
                ("Most viewed · 7 days", "views_7d:desc"), ("Most viewed · 30 days", "views_30d:desc"),
                ("Most viewed · all time", "views_total:desc"), ("Most followed", "follows_total:desc"),
            ]),
            defaultOption: "relevance:desc"
        ),
    ]

    private static let genreList: [(String, String)] = [
        ("Action", "1"), ("Adult", "268929"), ("Adventure", "78"), ("Avant Garde", "3"), ("Boys Love", "4"),
        ("Comedy", "5"), ("Crime", "268921"), ("Demons", "77"), ("Drama", "6"), ("Ecchi", "7"),
        ("Fantasy", "79"), ("Girls Love", "9"), ("Gourmet", "10"), ("Harem", "11"), ("Hentai", "268930"),
        ("Historical", "268922"), ("Horror", "530"), ("Isekai", "13"), ("Iyashikei", "531"), ("Josei", "15"),
        ("Kids", "532"), ("Magic", "539"), ("Magical Girls", "268923"), ("Mahou Shoujo", "533"),
        ("Martial Arts", "534"), ("Mature", "268931"), ("Mecha", "19"), ("Medical", "268924"),
        ("Military", "535"), ("Music", "21"), ("Mystery", "22"), ("Parody", "23"), ("Philosophical", "268925"),
        ("Psychological", "536"), ("Reverse Harem", "25"), ("Romance", "26"), ("School", "73"),
        ("Sci-Fi", "28"), ("Seinen", "537"), ("Shoujo", "30"), ("Shounen", "31"), ("Slice of Life", "538"),
        ("Smut", "268932"), ("Space", "33"), ("Sports", "34"), ("Super Power", "75"),
        ("Superhero", "268926"), ("Supernatural", "76"), ("Suspense", "37"), ("Thriller", "38"),
        ("Tragedy", "268927"), ("Vampire", "39"), ("Wuxia", "268928"),
    ]

    private static let themeList: [(String, String)] = [
        ("Aliens", "268933"), ("Animals", "268934"), ("Cooking", "268935"), ("Crossdressing", "268936"),
        ("Delinquents", "268937"), ("Demons", "268938"), ("Genderswap", "268939"), ("Ghosts", "268940"),
        ("Gyaru", "268941"), ("Harem", "268942"), ("Incest", "268943"), ("Loli", "268944"),
        ("Mafia", "268945"), ("Magic", "268946"), ("Martial Arts", "268947"), ("Military", "268948"),
        ("Monster Girls", "268949"), ("Monsters", "268950"), ("Music", "268951"), ("Ninja", "268952"),
        ("Office Workers", "268953"), ("Police", "268954"), ("Post-Apocalyptic", "268955"),
        ("Reincarnation", "268956"), ("Reverse Harem", "268957"), ("Samurai", "268958"),
        ("School Life", "268959"), ("Shota", "268960"), ("Supernatural", "268961"), ("Survival", "268962"),
        ("Time Travel", "268963"), ("Traditional Games", "268964"), ("Vampires", "268965"),
        ("Video Games", "268966"), ("Villainess", "268967"), ("Virtual Reality", "268968"), ("Zombies", "268969"),
    ]
}

// MARK: - DTOs

private struct ListResponse<T: Decodable>: Decodable {
    let items: [T]
    let meta: Meta?

    struct Meta: Decodable {
        let lastPage: Int?
        let hasNext: Bool?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([T].self, forKey: .items) ?? []
        meta = try container.decodeIfPresent(Meta.self, forKey: .meta)
    }

    private enum CodingKeys: String, CodingKey { case items, meta }
}

private struct PosterDTO: Decodable {
    let small: String?, medium: String?, large: String?
    var best: String? { large ?? medium ?? small }
}

private struct EntityDTO: Decodable { let title: String }

private struct TitleDTO: Decodable {
    let hid: String
    let slug: String?
    let url: String?
    let title: String
    let status: String?
    let poster: PosterDTO?
}

private struct DetailsResponse: Decodable {
    let data: Details

    struct Details: Decodable {
        let title: String
        let type: String?
        let status: String?
        let poster: PosterDTO?
        let synopsisHtml: String?
        let authors: [EntityDTO]?
        let artists: [EntityDTO]?
        let genres: [EntityDTO]?
        let themes: [EntityDTO]?
    }
}

private struct ChapterDTO: Decodable {
    let id: Int
    let number: Double
    let name: String?
    let createdAt: TimeInterval?
    let type: String?
}

private struct TagResponse: Decodable {
    let data: [Tag]
    struct Tag: Decodable { let id: Int; let type: String }
}

private struct PagesResponse: Decodable {
    let data: Chapter
    struct Chapter: Decodable { let pages: [Page] }
    struct Page: Decodable { let url: String }
}
