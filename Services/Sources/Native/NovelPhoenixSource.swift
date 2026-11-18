// NovelPhoenixSource.swift - novelphoenix.com, on the shared `[novelfire]` engine.

import Foundation

final class NovelPhoenixSource: NovelSource {
    let key = SourceKey.makeBuiltin(id: "novelphoenix")
    let kind = ContentKind.novel
    let name = "Novel Phoenix"
    let lang = "English"
    let iconAsset: String? = "NovelPhoenixIcon"
    let supportsLatest = true
    let filtersApplyToPopular = true

    private let engine = NovelFireEngine(
        sourceKey: SourceKey.makeBuiltin(id: "novelphoenix"),
        baseURL: "https://novelphoenix.com", defaultSort: "rank-top"
    )

    var homepage: URL? { URL(string: engine.client.baseURL) }

    func filters() async throws -> [SourceFilter] { engine.filters() }

    func popular(page: Int, filters: FilterState) async throws -> EntriesPage {
        try await engine.browse(page: page, latest: false, filters: filters)
    }

    func latest(page: Int, filters: FilterState) async throws -> EntriesPage {
        try await engine.browse(page: page, latest: true, filters: filters)
    }

    func search(query: String, page: Int, filters: FilterState) async throws -> EntriesPage {
        try await engine.search(query: query, page: page)
    }

    func webURL(_ entryURL: String) -> URL? { URL(string: engine.client.absolute(entryURL)) }
    func details(_ entry: SourceEntry) async throws -> SourceEntry { try await engine.details(entry) }
    func chapters(_ entry: SourceEntry) async throws -> [SourceChapter] { try await engine.chapters(entry) }
    func chapterHTML(_ chapter: SourceChapter) async throws -> String { try await engine.chapterHTML(chapter) }
}
