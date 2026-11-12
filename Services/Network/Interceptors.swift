// Interceptors.swift - Cross-cutting behaviour for every outgoing request.

import Foundation

// MARK: - Context

/// Everything an interceptor needs to know about who is making the request.
struct InterceptorContext: Sendable {
    /// `"ln:<id>"` / `"mihon:<id>"`, or `nil` for app-internal traffic.
    let sourceKey: String?
    /// Host of the request, pre-computed so interceptors don't re-parse URLs.
    let host: String
    /// Whether a challenge the hidden web view cannot pass may be shown to the user.
    var allowsUserVerification = true
}

// MARK: - Protocol

/// A hook into the request pipeline.
///
/// `adapt` runs before the request leaves the app and may rewrite it (headers,
/// cookies, retargeting). `retryDelay` runs after a non-2xx response and is the
/// only place that may recover a request, e.g. by solving a Cloudflare
/// challenge and asking for a replay.
protocol HTTPInterceptor: Sendable {

    func adapt(_ request: HTTPRequest, context: InterceptorContext) async throws -> HTTPRequest

    /// - Returns: seconds to wait before replaying the request, or `nil` to let
    ///   the client give up and surface the error.
    func retryDelay(
        for request: HTTPRequest,
        response: HTTPResponse,
        attempt: Int,
        context: InterceptorContext
    ) async -> TimeInterval?
}

extension HTTPInterceptor {
    func adapt(_ request: HTTPRequest, context: InterceptorContext) async throws -> HTTPRequest {
        request
    }

    func retryDelay(
        for request: HTTPRequest,
        response: HTTPResponse,
        attempt: Int,
        context: InterceptorContext
    ) async -> TimeInterval? {
        nil
    }
}

// MARK: - User agent

/// The user agent each host's Cloudflare challenge was solved under.
///
/// Cloudflare binds `cf_clearance` to the agent that earned it: the same cookie from a different
/// agent is challenged again, exactly as if there were no cookie. `CloudflareSolveGate` records
/// what the web view presented, and the user agent interceptor replays it for that host.
///
/// A lock rather than an actor: every request reads it, and only a solve writes.
final class BrowserIdentity: @unchecked Sendable {

    static let shared = BrowserIdentity()

    /// Persisted because the cookie jar keeps `cf_clearance` across launches, and the cookie is
    /// worthless under any other agent.
    private static let defaultsKey = "cloudflare.agents"

    private let lock = NSLock()
    private var agents: [String: String]

    private init() {
        agents = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }

    func agent(for host: String) -> String? {
        lock.withLock { agents[host] }
    }

    func setAgent(_ agent: String, for host: String) {
        lock.withLock {
            guard agents[host] != agent else { return }
            agents[host] = agent
            UserDefaults.standard.set(agents, forKey: Self.defaultsKey)
        }
    }

    /// Called when the cookie jar is cleared: without the clearance the binding means nothing.
    func forgetAll() {
        lock.withLock {
            agents.removeAll()
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        }
    }
}

/// Stamps a browser-like User-Agent on requests that don't carry one.
///
/// Sources routinely 403 a bare `URLSession` UA, and several serve different
/// markup to mobile clients, so the default mirrors Mobile Safari.
struct UserAgentInterceptor: HTTPInterceptor {

    static let defaultUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    var userAgent: String = UserAgentInterceptor.defaultUserAgent

    func adapt(_ request: HTTPRequest, context: InterceptorContext) async throws -> HTTPRequest {
        // A host whose challenge has been solved has to see the agent that earned the clearance,
        // even when the request already carries the app's own.
        if let agent = BrowserIdentity.shared.agent(for: context.host) {
            var request = request
            request.setHeader("User-Agent", agent)
            return request
        }
        guard request.header("User-Agent") == nil else { return request }
        var request = request
        request.setHeader("User-Agent", userAgent)
        return request
    }
}

// MARK: - Rate limiting

/// Spaces requests out per source and per host.
///
/// Kept as a separate actor because the state is the point: a source that
/// scrapes 400 chapters in a burst must be throttled across all its concurrent
/// callers, not per call site.
actor RateLimiter {

    private var nextAllowed: [String: ContinuousClock.Instant] = [:]

    /// Reserve a slot for `key`, sleeping until it is ours.
    ///
    /// Slots are reserved in arrival order, so concurrent callers queue up
    /// instead of all waking at the same instant.
    func acquire(key: String, minimumInterval: TimeInterval) async {
        guard minimumInterval > 0 else { return }

        let now = ContinuousClock.now
        let slot = max(nextAllowed[key] ?? now, now)
        nextAllowed[key] = slot.advanced(by: .seconds(minimumInterval))

        let wait = slot - now
        if wait > .zero {
            try? await Task.sleep(for: wait)
        }
    }

    /// Drop the state for a host, e.g. when the user clears source data.
    func reset() {
        nextAllowed.removeAll()
    }
}

/// Applies `RateLimiter` to every request, keyed by source + host.
struct RateLimitInterceptor: HTTPInterceptor {

    let limiter: RateLimiter
    /// Minimum spacing between two requests to the same host for the same source.
    var minimumInterval: TimeInterval

    init(limiter: RateLimiter = RateLimiter(), minimumInterval: TimeInterval = 0.25) {
        self.limiter = limiter
        self.minimumInterval = minimumInterval
    }

    func adapt(_ request: HTTPRequest, context: InterceptorContext) async throws -> HTTPRequest {
        await limiter.acquire(
            key: "\(context.sourceKey ?? "app")|\(context.host)",
            minimumInterval: minimumInterval
        )
        return request
    }
}

// MARK: - Retry

/// Retries idempotent requests on transient failures with exponential backoff.
struct RetryInterceptor: HTTPInterceptor {

    var maxAttempts: Int = 3
    var baseDelay: TimeInterval = 2

    func retryDelay(
        for request: HTTPRequest,
        response: HTTPResponse,
        attempt: Int,
        context: InterceptorContext
    ) async -> TimeInterval? {
        guard attempt < maxAttempts else { return nil }

        // 429 and 503 often tell us exactly how long to wait.
        if let retryAfter = response.header("Retry-After"), let seconds = TimeInterval(retryAfter) {
            return min(seconds, 60)
        }

        let code = response.statusCode
        guard code == 408 || code == 429 || (500..<600).contains(code) else { return nil }
        // 501/505 are permanent.
        guard code != 501, code != 505 else { return nil }

        return baseDelay * pow(2, Double(attempt - 1))
    }
}

// MARK: - Cloudflare

/// What a solved challenge leaves behind: the cookies, and the agent they were issued to.
struct CloudflareClearance: Sendable {
    let cookies: [HTTPCookie]
    /// `nil` when the solver cannot tell; the host then keeps the agent it already had.
    let userAgent: String?
}

/// Solves a Cloudflare interstitial and hands back the clearance.
///
/// Implemented with a `WKWebView` in `WebKitCloudflareSolver`. Kept behind a
/// protocol so the pipeline can be exercised in tests without a web view.
protocol CloudflareChallengeSolving: Sendable {
    /// - Parameter interactive: whether the solver may ask the user to complete a challenge it
    ///   cannot pass on its own.
    func solve(url: URL, interactive: Bool) async throws -> CloudflareClearance
}

/// Detects a challenge, asks the solver for clearance cookies, replays once.
struct CloudflareInterceptor: HTTPInterceptor {

    func retryDelay(
        for request: HTTPRequest,
        response: HTTPResponse,
        attempt: Int,
        context: InterceptorContext
    ) async -> TimeInterval? {
        // One replay is enough: a second challenge means the solver failed.
        guard attempt == 1, response.looksLikeCloudflareChallenge,
              await CloudflareSolveGate.shared.solve(
                  for: request, interactive: context.allowsUserVerification
              ) else {
            return nil
        }
        return 0.5
    }
}

/// The app's one Cloudflare solver, the one solve in flight per host, and what the last one did.
///
/// Every `HTTPClient` reads the solver from here, so a new client cannot be built without one.
/// A library grid asks for a dozen covers from one host at once and every one meets the same
/// challenge; callers that arrive during a solve wait for it instead of starting a web view each.
actor CloudflareSolveGate {

    static let shared = CloudflareSolveGate()

    private var solver: (any CloudflareChallengeSolving)?
    private var inFlight: [String: Task<Bool, Never>] = [:]
    private var notes: [String: String] = [:]

    /// Installed once at launch; until then a challenge is reported, not solved.
    func install(_ solver: any CloudflareChallengeSolving) {
        self.solver = solver
    }

    /// What the last solve for `host` did, for the error a request reports when the challenge
    /// survives. A 403 that still looks like a challenge says nothing on its own about whether the
    /// web view never cleared it or cleared it and the replay was refused anyway.
    func note(for host: String) -> String? { notes[host] }

    /// Solves the challenge `request` met and stores the clearance: cookies in the shared jar, the
    /// agent in `BrowserIdentity`.
    ///
    /// - Returns: whether there is a clearance to replay with.
    func solve(for request: HTTPRequest, interactive: Bool) async -> Bool {
        guard let solver else { return false }
        let host = request.host
        if let existing = inFlight[host] { return await existing.value }

        let page = Self.challengePage(for: request)
        let task = Task { await self.run(solver, page: page, host: host, interactive: interactive) }
        inFlight[host] = task
        // Only the request that started the solve clears the entry; the waiters just share it.
        defer { inFlight[host] = nil }
        return await task.value
    }

    /// The url to clear the challenge on.
    ///
    /// The solver loads a page in a web view, which is a navigation. A request that is not one —
    /// a POST, or a GET that declares itself a `fetch`/XHR — may not be challenged when navigated
    /// to (an API route that only takes POST is not), so the web view would never earn a cookie.
    /// The site's root is a page, and `cf_clearance` covers the whole host.
    static func challengePage(for request: HTTPRequest) -> URL {
        let isNavigation = request.method.uppercased() == "GET"
            && ["cors", "no-cors", "same-origin"].contains(request.header("Sec-Fetch-Mode") ?? "") == false
            && request.header("X-Requested-With") == nil
        guard !isNavigation, let root = URL(string: request.origin + "/") else { return request.url }
        return root
    }

    private func run(
        _ solver: any CloudflareChallengeSolving, page: URL, host: String, interactive: Bool
    ) async -> Bool {
        do {
            let clearance = try await solver.solve(url: page, interactive: interactive)
            guard !clearance.cookies.isEmpty else {
                notes[host] = "The solver returned no cookies."
                return false
            }
            CookieJar.setCookies(clearance.cookies)
            if let agent = clearance.userAgent {
                BrowserIdentity.shared.setAgent(agent, for: host)
            }
            notes[host] = "Cleared on \(page.absoluteString) with \(clearance.cookies.count) cookie(s)."
            return true
        } catch {
            notes[host] = "Solving on \(page.absoluteString) failed: \(error.localizedDescription)"
            return false
        }
    }
}
