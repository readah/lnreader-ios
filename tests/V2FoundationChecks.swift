// V2FoundationChecks.swift - Behaviour checks for the v2 foundation layer.
//
// Runs on macOS against the platform-independent parts of the new layer:
// schema enums, source value types, filters, date parsing and the HTTP value
// types. SwiftData models are excluded (they need a container), so the store is
// exercised in the app rather than here.

import Foundation

@main
struct V2FoundationChecks {

    static func main() {
        checkEntryStatus()
        checkContentKind()
        checkSourceIdentity()
        checkFilters()
        checkDateParsing()
        checkCloudflareDetection()
        checkHeaderHandling()
        checkRetryPolicy()
        print("PASS: v2 foundation — status mapping, source identity, filter defaults, "
            + "date parsing, Cloudflare detection, header handling, retry policy")
    }

    // MARK: Status

    private static func checkEntryStatus() {
        // Free-text from LN plugins.
        precondition(EntryStatus.parse("Ongoing") == .ongoing)
        precondition(EntryStatus.parse("  COMPLETED ") == .completed)
        precondition(EntryStatus.parse("hiatus") == .onHiatus)
        precondition(EntryStatus.parse("dropped") == .cancelled)
        // Numeric from Mihon extensions, same values as Yokai's SManga.
        precondition(EntryStatus.parse("2") == .completed)
        precondition(EntryStatus(rawValue: 6) == .onHiatus)
        // Junk must not become "ongoing".
        precondition(EntryStatus.parse(nil) == .unknown)
        precondition(EntryStatus.parse("") == .unknown)
        precondition(EntryStatus.parse("something else") == .unknown)
        // Raw values are the on-disk format.
        precondition(EntryStatus.ongoing.rawValue == 1)
        precondition(EntryStatus.completed.rawValue == 2)
        precondition(EntryStatus.onHiatus.rawValue == 6)
    }

    // MARK: Kind

    private static func checkContentKind() {
        // sourceKey prefixes are persisted in the store and in backups.
        precondition(ContentKind.novel.sourceKeyPrefix == "ln")
        precondition(ContentKind.manga.sourceKeyPrefix == "mihon")
        precondition(ContentKind.allCases.count == 2)
    }

    // MARK: Identity

    private static func checkSourceIdentity() {
        let a = SourceEntry(sourceKey: "ln:foo", kind: .novel, url: "novel/1", title: "One")
        let b = SourceEntry(sourceKey: "ln:foo", kind: .novel, url: "novel/1", title: "One (updated)")
        let c = SourceEntry(sourceKey: "ln:bar", kind: .novel, url: "novel/1", title: "One")

        // Identity ignores the title so a rename in the source does not fork the entry.
        precondition(a.id == b.id)
        precondition(a.id != c.id)
        precondition(a.id == "ln:foo::novel/1")

        // Same url in a different kind is still a different source key.
        let manga = SourceEntry(sourceKey: "mihon:1", kind: .manga, url: "novel/1", title: "One")
        precondition(manga.id != a.id)

        let chapter = SourceChapter(url: "ch/1", name: "Chapter 1", chapterNumber: 1)
        precondition(chapter.id == "ch/1")

        let pages = (0..<3).map { SourcePage(index: $0, url: "p\($0)") }
        precondition(pages.map(\.id) == [0, 1, 2])
    }

    // MARK: Filters

    private static func checkFilters() {
        let filters: [SourceFilter] = [
            .header(id: "h", name: "General"),
            .text(id: "q", name: "Title", hint: nil, defaultValue: "abc"),
            .select(
                id: "status",
                name: "Status",
                options: [FilterOption(id: "1", name: "Ongoing")],
                defaultOption: "1"
            ),
            .checkbox(id: "nsfw", name: "NSFW", defaultValue: true),
            .multiSelect(
                id: "genres",
                name: "Genres",
                options: [FilterOption(id: "g1", name: "Action")],
                defaultSelection: ["g1"]
            ),
            .excludable(
                id: "tags",
                name: "Tags",
                options: [FilterOption(id: "t1", name: "Harem")],
                defaultIncluded: ["t1"],
                defaultExcluded: []
            ),
            .sort(
                id: "sort",
                name: "Sort",
                options: [FilterOption(id: "0", name: "Popular")],
                defaultIndex: 0,
                defaultAscending: false
            ),
            .group(
                id: "g",
                name: "Advanced",
                children: [.text(id: "year", name: "Year", hint: nil, defaultValue: "2024")]
            ),
        ]

        // Groups flatten to their leaves so a form can render one list.
        let leaves = SourceFilter.flatten(filters)
        precondition(leaves.contains { $0.id == "year" })
        precondition(!leaves.contains { $0.id == "g" })

        let state = FilterState.defaults(for: filters)
        precondition(state.value(for: filters[1]) == .text("abc"))
        precondition(state.value(for: filters[2]) == .option("1"))
        precondition(state.value(for: filters[3]) == .checkbox(true))
        precondition(state.value(for: filters[4]) == .options(["g1"]))
        precondition(state.value(for: filters[5]) == .exclude(included: ["t1"], excluded: []))
        precondition(state.value(for: filters[6]) == .sort(index: 0, ascending: false))
        precondition(state.value(for: filters[7]) == nil, "A group carries no value of its own")
        precondition(state["year"] == .text("2024"), "Nested defaults are seeded too")

        // Explicit selections win over defaults.
        var edited = state
        edited["status"] = .option("2")
        precondition(edited.value(for: filters[2]) == .option("2"))
        precondition(state.value(for: filters[2]) == .option("1"), "FilterState is a value type")
    }

    // MARK: Dates

    private static func checkDateParsing() {
        precondition(DateParsing.parse(nil) == nil)
        precondition(DateParsing.parse("") == nil)
        precondition(DateParsing.parse("not a date") == nil)

        let iso = DateParsing.parse("2024-03-05T10:30:00.000Z")
        precondition(iso != nil)

        let day = DateParsing.parse("2024-03-05")
        precondition(day != nil)

        let monthName = DateParsing.parse("Mar 5, 2024")
        precondition(monthName != nil)

        // Relative dates resolve against now.
        guard let relative = DateParsing.parse("2 hours ago") else {
            preconditionFailure("relative date should parse")
        }
        let delta = Date.now.timeIntervalSince(relative)
        precondition(delta > 7_000 && delta < 7_400, "2 hours ago should be ~7200s, got \(delta)")
    }

    // MARK: Cloudflare

    private static func checkCloudflareDetection() {
        func response(status: Int, headers: [String: String] = [:], body: String) -> HTTPResponse {
            HTTPResponse(
                request: HTTPRequest(url: URL(string: "https://example.com")!),
                url: URL(string: "https://example.com")!,
                statusCode: status,
                headers: headers,
                data: Data(body.utf8)
            )
        }

        precondition(
            response(status: 403, body: "<title>Just a moment...</title>")
                .looksLikeCloudflareChallenge
        )
        precondition(
            response(status: 503, body: "<div id=\"cf-chl-widget\"></div>")
                .looksLikeCloudflareChallenge
        )
        precondition(
            response(status: 403, headers: ["cf-mitigated": "challenge"], body: "")
                .looksLikeCloudflareChallenge
        )
        // A normal 200 that happens to mention the words is not a challenge.
        precondition(
            !response(status: 200, body: "just a moment of your time").looksLikeCloudflareChallenge
        )
        // A plain 403 from a paywall is not a challenge either.
        precondition(
            !response(status: 403, body: "Forbidden").looksLikeCloudflareChallenge
        )

        // A page is cleared where it was challenged; an API call is cleared on the site's root,
        // because navigating to a POST-only route earns no cookie.
        func page(_ method: String, _ headers: [String: String] = [:]) -> String {
            let request = try! HTTPRequest(
                urlString: "https://Site.example/api/v2/search?q=1", method: method, headers: headers
            )
            return CloudflareSolveGate.challengePage(for: request).absoluteString
        }
        precondition(page("GET") == "https://Site.example/api/v2/search?q=1")
        precondition(page("POST") == "https://site.example/")
        precondition(page("GET", ["Sec-Fetch-Mode": "cors"]) == "https://site.example/")
        precondition(page("GET", ["X-Requested-With": "XMLHttpRequest"]) == "https://site.example/")
        precondition(page("GET", ["Sec-Fetch-Mode": "navigate"]) == "https://Site.example/api/v2/search?q=1")
    }

    // MARK: Headers

    private static func checkHeaderHandling() {
        var request = HTTPRequest(url: URL(string: "https://Example.com/path")!)
        request.setHeader("User-Agent", "A")
        request.setHeader("user-agent", "B")
        precondition(request.headers.count == 1, "Casing variants must not duplicate a header")
        precondition(request.header("USER-AGENT") == "B")

        request.removeHeader("User-Agent")
        precondition(request.header("user-agent") == nil)

        // `host` feeds rate limiting and must ignore a path or port.
        precondition(request.host == "example.com")
        precondition(request.origin == "https://example.com")

        let withPort = HTTPRequest(url: URL(string: "http://example.com:8080/x")!)
        precondition(withPort.origin == "http://example.com:8080")
    }

    // MARK: Retry

    private static func checkRetryPolicy() {
        precondition(HTTPError.transport("timeout").isRetryable)
        precondition(HTTPError.badStatus(code: 500, url: "u").isRetryable)
        precondition(HTTPError.badStatus(code: 429, url: "u").isRetryable)
        precondition(!HTTPError.badStatus(code: 404, url: "u").isRetryable)
        precondition(!HTTPError.badStatus(code: 403, url: "u").isRetryable)
        precondition(!HTTPError.cloudflareChallenge(url: "u").isRetryable)
        precondition(!HTTPError.invalidURL("u").isRetryable)

        // Retry-After wins over exponential backoff.
        let interceptor = RetryInterceptor(maxAttempts: 3, baseDelay: 2)
        let request = HTTPRequest(url: URL(string: "https://example.com")!)
        let throttled = HTTPResponse(
            request: request,
            url: request.url,
            statusCode: 429,
            headers: ["Retry-After": "7"],
            data: Data()
        )
        let context = InterceptorContext(sourceKey: "ln:test", host: "example.com")
        let delay = waitFor {
            await interceptor.retryDelay(
                for: request, response: throttled, attempt: 1, context: context
            )
        }
        precondition(delay == 7)

        // Out of attempts means no retry.
        let exhausted = waitFor {
            await interceptor.retryDelay(
                for: request, response: throttled, attempt: 3, context: context
            )
        }
        precondition(exhausted == nil)
    }

    // MARK: Helpers

    /// Runs an async expression to completion. The checks are synchronous by
    /// design so a failure crashes with a useful message instead of hanging.
    private static func waitFor<T>(_ work: @escaping () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: T?
        Task {
            result = await work()
            semaphore.signal()
        }
        semaphore.wait()
        return result!
    }
}
