// AllMangaSource.swift - AllManga (en), a port of keiyoushi/extensions-source src/en/allanime.
//
// Catalogue, details and chapters are plain GraphQL. The page list is not: the site wraps
// `chapterPages` in a client-side crypto handshake, so, like upstream, it is read out of the real
// site running in a web view (`WebViewCapture`).
//
// Persisted urls keep the shape older builds stored: `/manga/{id}/{slug}` for an entry and
// `/read/{id}/{slug}/chapter-{n}-sub` for a chapter, which is also what Mihon backups carry.

import Foundation

final class AllMangaSource: MangaSource {

    /// Upstream pins this id by hand; it equals `MihonSourceID.make(name: "allanime", lang: "en")`.
    static let mihonID: Int64 = 4_709_139_914_729_853_090

    let key = SourceKey.makeBuiltin(id: "allmanga")
    let kind = ContentKind.manga
    let name = "AllManga"
    let lang = "en"
    let iconAsset: String? = "AllMangaIcon"
    let supportsLatest = true

    private static let base = "https://mkissa.to"
    private static let api = "https://api.mkissa.net/api"
    private static let limit = 20
    private static let thumbnailCDN = "https://wp.youtube-anime.com/aln.youtube-anime.com/"
    private static let imageHost = "https://ytimgf.youtube-anime.com/"
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private let client = SiteClient(sourceKey: SourceKey.makeBuiltin(id: "allmanga"), baseURL: AllMangaSource.base)
    private let state = AllMangaAPIState()

    var homepage: URL? { URL(string: client.baseURL) }

    // MARK: - Filters

    private static let sortOptions = [
        FilterOption(id: "", name: "Update"),
        FilterOption(id: "Name_ASC", name: "Name Ascending"),
        FilterOption(id: "Name_DESC", name: "Name Descending"),
    ]
    private static let countryOptions = [
        FilterOption(id: "ALL", name: "All"),
        FilterOption(id: "JP", name: "Japan"),
        FilterOption(id: "CN", name: "China"),
        FilterOption(id: "KR", name: "Korea"),
    ]
    private static let genres = [
        "4 Koma", "Action", "Adult", "Adventure", "Cars", "Comedy", "Cooking", "Crossdressing", "Dementia",
        "Demons", "Doujinshi", "Drama", "Ecchi", "Fantasy", "Game", "Gender Bender", "Gyaru", "Harem",
        "Historical", "Horror", "Isekai", "Josei", "Kids", "Loli", "Magic", "Manhua", "Manhwa", "Martial Arts",
        "Mature", "Mecha", "Medical", "Military", "Monster Girls", "Music", "Mystery", "One Shot", "Parody",
        "Police", "Post Apocalyptic", "Psychological", "Reincarnation", "Reverse Harem", "Romance", "Samurai",
        "School", "Sci-Fi", "Seinen", "Shota", "Shoujo", "Shoujo Ai", "Shounen", "Shounen Ai", "Slice of Life",
        "Smut", "Space", "Sports", "Super Power", "Supernatural", "Suspense", "Thriller", "Tragedy", "Unknown",
        "Vampire", "Webtoons", "Yaoi", "Youkai", "Yuri", "Zombies",
    ]

    func filters() async throws -> [SourceFilter] {
        [
            .select(id: "sort", name: "Sort", options: Self.sortOptions, defaultOption: ""),
            .select(id: "country", name: "Countries", options: Self.countryOptions, defaultOption: "ALL"),
            .excludable(
                id: "genres", name: "Genres",
                options: Self.genres.map { FilterOption(id: $0, name: $0) },
                defaultIncluded: [], defaultExcluded: []
            ),
        ]
    }

    // MARK: - Browsing

    func popular(page: Int, filters: FilterState) async throws -> EntriesPage {
        let data = try await graphql(Self.popularQuery, [
            "type": "manga", "size": Self.limit, "dateRange": 0, "page": page,
            "allowAdult": false, "allowUnknown": false,
        ])
        let recommendations = ((data["queryPopular"] as? [String: Any])?["recommendations"] as? [[String: Any]]) ?? []
        let entries = recommendations.compactMap { ($0["anyCard"] as? [String: Any]).flatMap(entry(from:)) }
        return EntriesPage(entries: entries, hasNextPage: recommendations.count == Self.limit)
    }

    func latest(page: Int, filters: FilterState) async throws -> EntriesPage {
        try await searchPage(page: page, query: "", filters: FilterState())
    }

    func search(query: String, page: Int, filters: FilterState) async throws -> EntriesPage {
        try await searchPage(page: page, query: query.trimmingCharacters(in: .whitespacesAndNewlines), filters: filters)
    }

    private func searchPage(page: Int, query: String, filters: FilterState) async throws -> EntriesPage {
        var sort: String?
        var country = "ALL"
        var included: [String] = []
        var excluded: [String] = []
        if case .option(let value)? = filters["sort"], !value.isEmpty { sort = value }
        if case .option(let value)? = filters["country"] { country = value }
        if case .exclude(let inc, let exc)? = filters["genres"] {
            included = Self.genres.filter(inc.contains)
            excluded = Self.genres.filter(exc.contains)
        }
        let search: [String: Any] = [
            "query": query.isEmpty ? NSNull() : query,
            "sortBy": sort ?? NSNull(),
            "genres": included.isEmpty ? NSNull() : included,
            "excludeGenres": excluded.isEmpty ? NSNull() : excluded,
            "isManga": true,
            "allowAdult": false,
            "allowUnknown": false,
        ]
        let data = try await graphql(Self.searchQuery, [
            "search": search, "size": Self.limit, "page": page,
            "translationType": "sub", "countryOrigin": country,
        ])
        let edges = ((data["mangas"] as? [String: Any])?["edges"] as? [[String: Any]]) ?? []
        return EntriesPage(entries: edges.compactMap(entry(from:)), hasNextPage: edges.count == Self.limit)
    }

    // MARK: - Details and chapters

    /// The page the chapter capture opens too; a stored url can be a bare id or carry a slug.
    func webURL(_ entryURL: String) -> URL? {
        guard let id = try? Self.mangaID(of: entryURL) else { return nil }
        return URL(string: "\(Self.base)/manga/\(id)?fromSearch=1")
    }

    func details(_ entry: SourceEntry) async throws -> SourceEntry {
        let data = try await mangaDocument(id: try Self.mangaID(of: entry.url))
        guard let manga = data["manga"] as? [String: Any] else { throw SourceError.entryNotFound(entry.url) }

        let author = (manga["authors"] as? [String])?.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        let genres = (((manga["genres"] as? [String]) ?? []) + ((manga["tags"] as? [String]) ?? []))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }

        return SourceEntry(
            sourceKey: key, kind: kind, url: entry.url,
            title: Self.title(of: manga),
            thumbnailURL: Self.thumbnail(manga["thumbnail"] as? String),
            author: author, artist: author,
            description: Self.description(of: manga),
            genres: genres,
            status: Self.status(manga["status"] as? String)
        )
    }

    func chapters(_ entry: SourceEntry) async throws -> [SourceChapter] {
        let id = try Self.mangaID(of: entry.url)
        let data = try await mangaDocument(id: id)
        guard let manga = data["manga"] as? [String: Any] else { throw SourceError.entryNotFound(entry.url) }

        let slug = Self.slug(of: manga["name"] as? String ?? "")
        var infos: [String: [String: Any]] = [:]
        for info in (data["episodeInfos"] as? [[String: Any]]) ?? [] {
            if let number = Self.string(info["episodeIdNum"]) { infos[number] = info }
        }
        let available = (((manga["availableChaptersDetail"] as? [String: Any])?["sub"]) as? [Any]) ?? []

        return available.compactMap { raw in
            guard let number = Self.string(raw), let info = infos[number] else { return nil }
            var name = "Chapter \(number)"
            if let notes = info["notes"] as? String, !notes.isEmpty, notes.rangeOfCharacter(from: .decimalDigits) == nil {
                name += ": \(notes)"
            }
            let uploaded = (info["uploadDates"] as? [String: Any])?["sub"] as? String
            return SourceChapter(
                url: "/read/\(id)/\(slug)/chapter-\(number)-sub",
                name: name,
                chapterNumber: Double(number) ?? -1,
                dateUpload: DateParsing.parse(uploaded)
            )
        }
    }

    // MARK: - Pages

    func pages(_ chapter: SourceChapter) async throws -> [SourcePage] {
        // /read/{mangaId}/{slug}/chapter-{n}-sub
        let parts = chapter.url.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[0] == "read" else { throw AllMangaError.refreshChapters }
        let mangaID = parts[1]
        let mangaURL = "\(Self.base)/manga/\(mangaID)?fromSearch=1"
        let chapterPath = "/manga/\(mangaID)/\(parts[3])"

        let shell: HTTPResponse
        do {
            shell = try await client.send(mangaURL, headers: ["User-Agent": Self.userAgent])
        } catch HTTPError.badStatus(let code, _) where code == 403 || code == 503 {
            throw AllMangaError.captcha
        } catch HTTPError.cloudflareChallenge {
            throw AllMangaError.captcha
        }

        let message = try await WebViewCapture.capture(WebViewCaptureOptions(
            url: mangaURL,
            html: shell.text,
            userAgent: Self.userAgent,
            startScripts: [
                "try { localStorage.clear(); sessionStorage.clear(); } catch (e) {}",
                Self.hookScript,
                Self.navigateScript(chapterPath: chapterPath),
            ],
            timeoutMs: 20_000,
            // The site asks for a human check on some requests. When that overlay (or a Cloudflare
            // interstitial) stays up, the user is shown the page.
            challengeScript: "document.title.indexOf('Just a moment') >= 0 || "
                + "document.querySelector('.captcha-overlay--visible') != null",
            challengeTitle: "Verify to load this chapter"
        ))

        guard let payload = try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any] else {
            throw SourceError.parseFailed("AllManga page payload")
        }
        let root = payload["chapterPages"] != nil ? payload : ((payload["data"] as? [String: Any]) ?? [:])
        let edges = ((root["chapterPages"] as? [String: Any])?["edges"] as? [[String: Any]]) ?? []
        guard !edges.isEmpty else { return [] }

        // Prefer a server whose urls are usable as they are or that names a host.
        let chosen = edges.first { edge in
            let urls = (edge["pictureUrls"] as? [[String: Any]]) ?? []
            let sample = urls.randomElement()?["url"] as? String
            return (sample?.hasPrefix("http") ?? false) || (edge["pictureUrlHead"] as? String)?.isEmpty == false
        } ?? edges[0]

        var head = Self.imageHost
        if let server = chosen["pictureUrlHead"] as? String, !server.isEmpty {
            let trimmed = server.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
            head = (server.hasPrefix("http") ? trimmed : "https://" + trimmed) + "/"
        }

        let referer = ["Referer": Self.base + "/"]
        let urls = ((chosen["pictureUrls"] as? [[String: Any]]) ?? []).compactMap { $0["url"] as? String }.filter { !$0.isEmpty }
        return urls.enumerated().map { index, value in
            let absolute = value.hasPrefix("http") ? value : head + (value.hasPrefix("/") ? String(value.dropFirst()) : value)
            return SourcePage(index: index, url: absolute, headers: referer)
        }
    }

    // MARK: - Transport

    /// One request per second to the API host, as upstream does.
    private func graphql(_ query: String, _ variables: [String: Any]) async throws -> [String: Any] {
        await state.throttle()
        let response: HTTPResponse
        do {
            response = try await client.postJSON(
                Self.api, ["query": query, "variables": variables],
                headers: ["Referer": Self.base + "/", "Origin": Self.base]
            )
        } catch HTTPError.badStatus(let code, _) {
            throw AllMangaError.http(code)
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw AllMangaError.http(response.statusCode)
        }
        if let errors = parsed["errors"] as? [[String: Any]], !errors.isEmpty, parsed["data"] == nil {
            throw AllMangaError.graphql(errors[0]["message"] as? String ?? "GraphQL error")
        }
        return (parsed["data"] as? [String: Any]) ?? [:]
    }

    private func mangaDocument(id: String) async throws -> [String: Any] {
        let raw = try await state.manga(id: id) { id in
            let document = try await self.fetchManga(id: id)
            return try JSONSerialization.data(withJSONObject: document)
        }
        return (try JSONSerialization.jsonObject(with: raw) as? [String: Any]) ?? [:]
    }

    /// Upstream retries up to five times: the API answers `manga: null` or a "try again in N
    /// seconds" error while it rate limits.
    private func fetchManga(id: String) async throws -> [String: Any] {
        var delay = 1.0
        var lastError: Error?
        for attempt in 0...5 {
            if attempt > 0 { try await Task.sleep(for: .seconds(delay)) }
            do {
                let data = try await graphql(Self.updateQuery, [
                    "id": id, "showId": "manga@\(id)",
                    "search": ["fromSearch": true, "allowAdult": true],
                ])
                if data["manga"] is [String: Any] { return data }
                delay += 1
            } catch AllMangaError.graphql(let message) {
                lastError = AllMangaError.graphql(message)
                if let match = message.range(of: #"again in (\d+)\s*second"#, options: .regularExpression),
                   let seconds = Double(message[match].filter(\.isNumber)) {
                    delay = seconds
                } else {
                    delay += 1
                }
            }
        }
        throw lastError ?? SourceError.entryNotFound(id)
    }

    // MARK: - Mapping

    private func entry(from item: [String: Any]) -> SourceEntry? {
        guard let id = item["_id"] as? String, let rawName = item["name"] as? String else { return nil }
        return SourceEntry(
            sourceKey: key, kind: kind,
            url: "/manga/\(id)/\(Self.slug(of: rawName))",
            title: Self.title(of: item),
            thumbnailURL: Self.thumbnail(item["thumbnail"] as? String)
        )
    }

    private static func title(of item: [String: Any]) -> String {
        if let english = item["englishName"] as? String, !english.isEmpty { return english }
        return item["name"] as? String ?? ""
    }

    private static func thumbnail(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        // No `?w=250`: the CDN's original is the only copy sharp enough for the
        // detail hero, and `CoverDecode` downsamples it for grid cells.
        return value.hasPrefix("http") ? value : thumbnailCDN + value
    }

    private static func status(_ value: String?) -> EntryStatus {
        let text = (value ?? "").lowercased()
        if text.contains("releasing") { return .ongoing }
        if text.contains("finished") { return .completed }
        return .unknown
    }

    private static func slug(of name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
    }

    /// Accepts `/manga/{id}/{slug}`, `/read/{id}/...` and a bare id (newer Mihon backups).
    private static func mangaID(of url: String) throws -> String {
        let parts = url.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let marker = parts.firstIndex(of: "manga") ?? parts.firstIndex(of: "read")
        let id = marker.flatMap { parts.indices.contains($0 + 1) ? parts[$0 + 1] : nil } ?? parts.last ?? ""
        guard !id.isEmpty else { throw AllMangaError.unsupportedURL(url) }
        return id
    }

    /// JSON numbers and strings both appear for chapter numbers.
    private static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    private static func stripHTML(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, plain) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: plain)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func description(of manga: [String: Any]) -> String {
        var text = stripHTML(manga["description"] as? String ?? "") + "\n\n"
        if let mal = string(manga["malId"]), !mal.isEmpty { text += "[MyAnimeList](https://myanimelist.net/manga/\(mal))\n" }
        if let ani = string(manga["aniListId"]), !ani.isEmpty { text += "[AniList](https://anilist.co/manga/\(ani))\n" }
        text += "\n\n"
        if let alt = manga["altNames"] as? [String], !alt.isEmpty {
            text += "Alternative Titles:\n" + alt.map { "- \($0)" }.joined(separator: "\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Queries and page scripts

    private static let popularQuery =
        "query ($type: VaildPopularTypeEnumType!, $size: Int!, $page: Int, $dateRange: Int, "
        + "$allowAdult: Boolean, $allowUnknown: Boolean) { queryPopular(type: $type, size: $size, "
        + "dateRange: $dateRange, page: $page, allowAdult: $allowAdult, allowUnknown: $allowUnknown) "
        + "{ recommendations { anyCard { _id name thumbnail englishName } } } }"

    private static let searchQuery =
        "query ($search: SearchInput, $size: Int, $page: Int, "
        + "$translationType: VaildTranslationTypeMangaEnumType, $countryOrigin: VaildCountryOriginEnumType) "
        + "{ mangas(search: $search, limit: $size, page: $page, translationType: $translationType, "
        + "countryOrigin: $countryOrigin) { edges { _id name thumbnail englishName } } }"

    private static let updateQuery =
        "query ($id: String!, $showId: String!, $search: SearchInput) { "
        + "manga(_id: $id, search: $search) { _id name thumbnail description authors genres tags status "
        + "altNames englishName malId aniListId relatedMangas availableChaptersDetail } "
        + "episodeInfos(showId: $showId, episodeNumStart: 0, episodeNumEnd: 9999) "
        + "{ episodeIdNum notes uploadDates } }"

    /// Runs at document start. Surfaces the payload that carries `chapterPages`. The site now
    /// decrypts it with `crypto.subtle` and parses it where `JSON.parse` cannot be hooked (a fresh
    /// iframe realm), so the decoded text is caught at `TextDecoder.decode` as well. Upstream nulls
    /// every iframe's `contentWindow` to force the hooked path; that breaks Cloudflare Turnstile,
    /// so it is left out and the site's own verification is allowed to run.
    private static let hookScript = """
    (function () {
      var post = function (s) { if (window.__lnrPost) window.__lnrPost(s); };
      var originalJson = Response.prototype.json;
      Response.prototype.json = function () {
        return originalJson.call(this).then(function (data) {
          if (data && data.chapterPages) post(JSON.stringify(data));
          return data;
        });
      };
      var originalParse = JSON.parse;
      JSON.parse = new Proxy(originalParse, {
        apply: function (target, thisArg, args) {
          var result = Reflect.apply(target, thisArg, args);
          if (result && result.chapterPages) post(args[0]);
          return result;
        }
      });
      var originalDecode = TextDecoder.prototype.decode;
      TextDecoder.prototype.decode = function () {
        var text = originalDecode.apply(this, arguments);
        if (typeof text === 'string' && text.indexOf('"chapterPages"') >= 0) post(text);
        return text;
      };
    })();
    """

    /// Waits for the SPA router, then navigates to the chapter the way a click would.
    private static func navigateScript(chapterPath: String) -> String {
        let path = (try? JSONSerialization.data(withJSONObject: [chapterPath]))
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { String($0.dropFirst().dropLast()) } ?? "\"\(chapterPath)\""
        return """
        (function () {
          var go = function () {
            var a = document.createElement('a');
            a.href = a.dataset.href = \(path);
            document.body.append(a); a.click();
          };
          var tries = 0;
          var check = function () {
            if (document.querySelector('[data-href]')) go();
            else if (tries++ < 200) setTimeout(check, 50);
            else go();
          };
          document.addEventListener('DOMContentLoaded', check);
          if (document.readyState !== 'loading') check();
        })();
        """
    }
}

// MARK: - Errors

private enum AllMangaError: LocalizedError {
    case http(Int)
    case graphql(String)
    case unsupportedURL(String)
    case captcha
    case refreshChapters

    var errorDescription: String? {
        switch self {
        case .http(let code): "AllManga: HTTP \(code)"
        case .graphql(let message): message
        case .unsupportedURL(let url): "AllManga: unsupported URL \(url)"
        case .captcha: "Solve captcha in WebView and retry"
        case .refreshChapters: "Refresh Chapter List"
        }
    }
}

// MARK: - Shared state

/// The API allows one call per second, and `details` and `chapters` ask for the same document back
/// to back, so the second reuses the first for a short while.
private actor AllMangaAPIState {

    private var nextCall = ContinuousClock.now
    private var cached: (id: String, at: ContinuousClock.Instant, data: Data)?

    func throttle() async {
        let slot = max(nextCall, .now)
        nextCall = slot.advanced(by: .seconds(1))
        let wait = slot - .now
        if wait > .zero { try? await Task.sleep(for: wait) }
    }

    func manga(id: String, fetch: @Sendable (String) async throws -> Data) async throws -> Data {
        if let cached, cached.id == id, ContinuousClock.now - cached.at < .seconds(30) { return cached.data }
        let data = try await fetch(id)
        cached = (id, .now, data)
        return data
    }
}
