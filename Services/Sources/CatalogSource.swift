// CatalogSource.swift - What a content source has to implement.

import Foundation

/// Anything that can list, search and describe entries.
///
/// Two implementations are planned: `LNPluginSource` (the existing
/// JavaScriptCore runtime) and `MihonSource` (transpiled Kotlin extensions).
/// A hand-written `BuiltinSource` for a handful of high-traffic sites fits here
/// too — see the built-in sources section of docs/MANGA_SUPPORT_PLAN.md.
protocol CatalogSource: Identifiable, Sendable {

    /// `"ln:<pluginId>"` or `"mihon:<extensionId>"`. Persisted, so stable.
    var key: String { get }

    var kind: ContentKind { get }
    var name: String { get }
    /// Language tag or display name the source reports (e.g. `"English"`).
    var lang: String { get }
    var iconURL: String? { get }
    /// Asset-catalog name for sources whose icon ships in the binary.
    var iconAsset: String? { get }
    /// Whether the source has a distinct "latest" listing.
    var supportsLatest: Bool { get }
    /// Whether `popular(page:filters:)` applies the filters itself. Otherwise Browse runs a
    /// filtered listing as `search(query: "", ...)`, which is where Mihon-style sources read them.
    var filtersApplyToPopular: Bool { get }
    /// Whether `filters()` fetches part of its list from the site. Browse caches those on disk.
    var filtersAreRemote: Bool { get }
    /// Whether a `filters()` result includes everything it should. Remote fetches that fail
    /// quietly return a shorter list, which must not be cached.
    func filtersAreComplete(_ filters: [SourceFilter]) -> Bool
    /// Whether the whole source is adult content; Browse marks it with an 18+ chip.
    var isAdult: Bool { get }
    /// The site itself, for opening it in the app's web view. A login or a solved
    /// Cloudflare challenge earned there is what the scraper then uses, so this is
    /// the way in when a source starts answering with a challenge page. Nil when
    /// the source has no site to show.
    var homepage: URL? { get }

    // MARK: Browsing

    func filters() async throws -> [SourceFilter]
    func popular(page: Int, filters: FilterState) async throws -> EntriesPage
    func latest(page: Int, filters: FilterState) async throws -> EntriesPage
    func search(query: String, page: Int, filters: FilterState) async throws -> EntriesPage

    // MARK: Details

    /// Full metadata for one entry.
    func details(_ entry: SourceEntry) async throws -> SourceEntry
    /// Chapter list, oldest first. `ChapterOrder.normalized` fixes up a source
    /// that lists newest-first before the order is stored, so a source may hand
    /// back either direction; see `Services/ChapterOrder.swift`.
    func chapters(_ entry: SourceEntry) async throws -> [SourceChapter]
    /// The entry's page on the site, for "Open in web view". `entryURL` is the
    /// stored `url`, in whatever shape this source persists it. Nil when the
    /// source has no page to show.
    func webURL(_ entryURL: String) -> URL?
}

extension CatalogSource {
    var id: String { key }

    var iconURL: String? { nil }
    var homepage: URL? { nil }
    func webURL(_ entryURL: String) -> URL? { nil }
    var iconAsset: String? { nil }
    var supportsLatest: Bool { false }
    var isAdult: Bool { false }
    var filtersApplyToPopular: Bool { false }
    var filtersAreRemote: Bool { false }
    func filtersAreComplete(_ filters: [SourceFilter]) -> Bool { true }

    func filters() async throws -> [SourceFilter] { [] }

    func latest(page: Int, filters: FilterState) async throws -> EntriesPage {
        throw SourceError.notSupported("latest listing")
    }

    func popular(page: Int, filters: FilterState) async throws -> EntriesPage {
        throw SourceError.notSupported("popular listing")
    }

    /// Default search ignores filters, which is correct for sources that have none.
    func search(query: String, page: Int, filters: FilterState) async throws -> EntriesPage {
        throw SourceError.notSupported("search")
    }
}

// MARK: - Novel

/// A source that yields chapter HTML, rendered by the existing web reader.
protocol NovelSource: CatalogSource {
    func chapterHTML(_ chapter: SourceChapter) async throws -> String
}

// MARK: - Manga

/// A source that yields ordered image pages, rendered by the manga reader.
protocol MangaSource: CatalogSource {
    /// Ordered pages of one chapter. Index 0 is the first page.
    func pages(_ chapter: SourceChapter) async throws -> [SourcePage]

    /// Absolute image URL, for pages whose URL is produced lazily.
    func imageURL(_ page: SourcePage) async throws -> String

    /// Fully-formed request for one page, including the headers the CDN needs.
    func imageRequest(_ page: SourcePage) async throws -> URLRequest
}

extension MangaSource {
    func imageURL(_ page: SourcePage) async throws -> String { page.url }

    func imageRequest(_ page: SourcePage) async throws -> URLRequest {
        let urlString = try await imageURL(page)
        guard let url = URL(string: urlString) else {
            throw HTTPError.invalidURL(urlString)
        }
        var request = URLRequest(url: url)
        for (name, value) in page.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}
