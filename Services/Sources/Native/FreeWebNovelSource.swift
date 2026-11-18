// FreeWebNovelSource.swift - Free Web Novel (freewebnovel.com), plugin id `FWN.com` in LNReader.
//
// Configuration of `FreeWebNovelEngine`. Paths are the plugin's: `novel/<slug>` for a novel and
// `novel/<slug>/chapter-<n>` for a chapter, no leading slash.

import Foundation

final class FreeWebNovelSource: NovelSource {
    let key = SourceKey.makeBuiltin(id: "freewebnovel")
    let kind = ContentKind.novel
    let name = "Free Web Novel"
    let lang = "English"
    let iconAsset: String? = "FreeWebNovelIcon"
    let supportsLatest = true
    let filtersApplyToPopular = true

    private let engine = FreeWebNovelEngine(.init(
        sourceKey: SourceKey.makeBuiltin(id: "freewebnovel"),
        baseURL: "https://freewebnovel.com",
        latestPage: "sort/latest-release",
        searchPage: "search",
        searchKey: "keyword",
        singlePageListings: ["sort/most-popular"],
        chapterListing: "api/chapterlist.php",
        chapterParam: "aid",
        defaultType: "sort/most-popular",
        types: [
            FilterOption(id: "sort/latest-release", name: "All"),
            FilterOption(id: "sort/latest-release/chinese-novel", name: "Chinese Novel"),
            FilterOption(id: "sort/latest-release/korean-novel", name: "Korean Novel"),
            FilterOption(id: "sort/latest-release/japanese-novel", name: "Japanese Novel"),
            FilterOption(id: "sort/latest-release/english-novel", name: "English Novel"),
            FilterOption(id: "sort/most-popular", name: "Most Popular"),
        ],
        genres: [
            FilterOption(id: "genre/Action", name: "Action"),
            FilterOption(id: "genre/Adult", name: "Adult"),
            FilterOption(id: "genre/Adventure", name: "Adventure"),
            FilterOption(id: "genre/Comedy", name: "Comedy"),
            FilterOption(id: "genre/Drama", name: "Drama"),
            FilterOption(id: "genre/Eastern", name: "Eastern"),
            FilterOption(id: "genre/Ecchi", name: "Ecchi"),
            FilterOption(id: "genre/Fantasy", name: "Fantasy"),
            FilterOption(id: "genre/Game", name: "Game"),
            FilterOption(id: "genre/Gender+Bender", name: "Gender Bender"),
            FilterOption(id: "genre/Harem", name: "Harem"),
            FilterOption(id: "genre/Historical", name: "Historical"),
            FilterOption(id: "genre/Horror", name: "Horror"),
            FilterOption(id: "genre/Josei", name: "Josei"),
            FilterOption(id: "genre/Martial+Arts", name: "Martial Arts"),
            FilterOption(id: "genre/Mature", name: "Mature"),
            FilterOption(id: "genre/Mecha", name: "Mecha"),
            FilterOption(id: "genre/Mystery", name: "Mystery"),
            FilterOption(id: "genre/Psychological", name: "Psychological"),
            FilterOption(id: "genre/Reincarnation", name: "Reincarnation"),
            FilterOption(id: "genre/Romance", name: "Romance"),
            FilterOption(id: "genre/School+Life", name: "School Life"),
            FilterOption(id: "genre/Sci-fi", name: "Sci-fi"),
            FilterOption(id: "genre/Seinen", name: "Seinen"),
            FilterOption(id: "genre/Shoujo", name: "Shoujo"),
            FilterOption(id: "genre/Shounen+Ai", name: "Shounen Ai"),
            FilterOption(id: "genre/Shounen", name: "Shounen"),
            FilterOption(id: "genre/Slice+of+Life", name: "Slice of Life"),
            FilterOption(id: "genre/Smut", name: "Smut"),
            FilterOption(id: "genre/Sports", name: "Sports"),
            FilterOption(id: "genre/Supernatural", name: "Supernatural"),
            FilterOption(id: "genre/Tragedy", name: "Tragedy"),
            FilterOption(id: "genre/Wuxia", name: "Wuxia"),
            FilterOption(id: "genre/Xianxia", name: "Xianxia"),
            FilterOption(id: "genre/Xuanhuan", name: "Xuanhuan"),
            FilterOption(id: "genre/Yaoi", name: "Yaoi"),
        ]
    ))

    var homepage: URL? { URL(string: engine.site.baseURL) }

    func filters() async throws -> [SourceFilter] { engine.filters() }

    func popular(page: Int, filters: FilterState) async throws -> EntriesPage {
        try await engine.popular(page: page, filters: filters)
    }

    func latest(page: Int, filters: FilterState) async throws -> EntriesPage {
        try await engine.latest(page: page)
    }

    func search(query: String, page: Int, filters: FilterState) async throws -> EntriesPage {
        try await engine.search(query: query, page: page)
    }

    func webURL(_ entryURL: String) -> URL? { URL(string: engine.site.absolute(entryURL)) }
    func details(_ entry: SourceEntry) async throws -> SourceEntry { try await engine.details(entry) }
    func chapters(_ entry: SourceEntry) async throws -> [SourceChapter] { try await engine.chapters(entry) }
    func chapterHTML(_ chapter: SourceChapter) async throws -> String { try await engine.chapterHTML(chapter) }
}
