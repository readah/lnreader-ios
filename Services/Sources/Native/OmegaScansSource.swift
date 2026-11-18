// OmegaScansSource.swift - Omega Scans (omegascans.org), ported from keiyoushi's src/en/omegascans.
//
// A HeanCMS site (see HeanCmsSource.swift). Upstream also sets `enableLogin`; sign-in and paid chapters
// are not ported, so paid chapters stay hidden. `fetchBadge` is on, as upstream.

import Foundation

final class OmegaScansSource: MangaSource {

    /// Mihon source id: `MihonSourceID.make(name: "Omega Scans", lang: "en", versionId: 2)`.
    static let mihonID: Int64 = MihonSourceID.make(name: "Omega Scans", lang: "en", versionId: 2)

    let key = SourceKey.makeBuiltin(id: "omegascans")
    let kind = ContentKind.manga
    let name = "Omega Scans"
    let lang = "en"
    let iconAsset: String? = "OmegaScansIcon"
    let isAdult = true
    let supportsLatest = true
    let filtersAreRemote = true

    func filtersAreComplete(_ filters: [SourceFilter]) -> Bool {
        filters.contains { $0.id == "genres" }
    }

    private let engine = HeanCmsEngine(
        HeanCmsConfig(
            sourceKey: SourceKey.makeBuiltin(id: "omegascans"),
            baseURL: "https://omegascans.org",
            fetchBadge: true
        )
    )

    var homepage: URL? { URL(string: engine.config.baseURL) }

    func filters() async throws -> [SourceFilter] { try await engine.filters() }
    func popular(page: Int, filters: FilterState) async throws -> EntriesPage { try await engine.popular(page: page) }
    func latest(page: Int, filters: FilterState) async throws -> EntriesPage { try await engine.latest(page: page) }

    func search(query: String, page: Int, filters: FilterState) async throws -> EntriesPage {
        try await engine.search(query: query, page: page, filters: filters)
    }

    func webURL(_ entryURL: String) -> URL? { engine.webURL(entryURL) }
    func details(_ entry: SourceEntry) async throws -> SourceEntry { try await engine.details(entry) }
    func chapters(_ entry: SourceEntry) async throws -> [SourceChapter] { try await engine.chapters(entry) }
    func pages(_ chapter: SourceChapter) async throws -> [SourcePage] { try await engine.pages(chapter) }
}
