// HTTPClient.swift - The single HTTP entry point for every source.
//
// LN JS plugins, Mihon extensions, image loaders and the backup uploader all go
// through here, so UA spoofing, cookies, rate limiting and Cloudflare handling
// are implemented once instead of per source.

import Foundation

/// An interceptor-driven HTTP client.
///
/// An actor because the request path is shared by every source thread. The
/// Cloudflare solver is not per client: `CloudflareSolveGate` holds the app's one.
actor HTTPClient {

    // MARK: Configuration

    struct Configuration: Sendable {
        /// Per-request timeout, unless the request overrides it.
        var timeout: TimeInterval = 30
        /// Ceiling for a whole transfer, including retries of large bodies.
        var resourceTimeout: TimeInterval = 120
        /// Total tries per request, including the first one.
        var maxAttempts: Int = 3
        /// Connections to one host. Sources are serialized per source anyway.
        var maxConnectionsPerHost: Int = 6
        /// Disk/memory cache for covers and plugin JS.
        var memoryCacheBytes: Int = 8 * 1024 * 1024
        var diskCacheBytes: Int = 64 * 1024 * 1024
        /// Hold the request until a connection exists instead of failing at once.
        ///
        /// On for sources: a chapter that fails to refresh is worse than one that waits. Off for
        /// covers, where a library grid would otherwise sit on a dozen spinners for the resource
        /// timeout, and the copy on disk is a better answer than two minutes of nothing.
        var waitsForConnectivity: Bool = true
        /// Whether a challenge the hidden web view cannot pass is shown to the user. Off for
        /// covers: a library grid must never put a sheet over the screen.
        var allowsUserVerification: Bool = true

        static let `default` = Configuration()

        /// Covers: fail fast, and be gone before the cell is looked at.
        ///
        /// Two attempts: the first, and the replay after a Cloudflare solve; a dead cover is not
        /// retried. No URL cache, because `CoverDiskCache` already keeps every cover it loads.
        static let covers: Configuration = {
            var config = Configuration()
            config.timeout = 15
            config.maxAttempts = 2
            config.memoryCacheBytes = 0
            config.diskCacheBytes = 0
            config.waitsForConnectivity = false
            config.allowsUserVerification = false
            return config
        }()
    }

    // MARK: State

    static let shared = HTTPClient()

    /// The client cover art loads through.
    ///
    /// No rate limiter (a library grid asks for a dozen covers at once, and one slot every 250 ms
    /// would spend three seconds before the last one started) and no retries. A cover is often
    /// behind the same gate as the source's own API — Kagane serves them from
    /// `/api/v2/image/<id>` on the origin that protects its JSON — so it keeps the shared cookie
    /// jar, the agent that earned `cf_clearance`, and the solver.
    static let covers = HTTPClient(
        configuration: .covers,
        interceptors: [UserAgentInterceptor(), CloudflareInterceptor()]
    )

    private let configuration: Configuration
    private let session: URLSession
    private let interceptors: [any HTTPInterceptor]

    init(
        configuration: Configuration = .default,
        interceptors: [any HTTPInterceptor]? = nil
    ) {
        self.configuration = configuration
        self.interceptors = interceptors ?? HTTPClient.makeDefaultInterceptors()

        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = configuration.timeout
        sessionConfiguration.timeoutIntervalForResource = configuration.resourceTimeout
        sessionConfiguration.httpMaximumConnectionsPerHost = configuration.maxConnectionsPerHost
        sessionConfiguration.httpShouldSetCookies = true
        sessionConfiguration.httpCookieAcceptPolicy = .always
        // One cookie jar for the whole app; the WKWebView login flows write into
        // the same `HTTPCookieStorage.shared`.
        sessionConfiguration.httpCookieStorage = .shared
        sessionConfiguration.urlCache = URLCache(
            memoryCapacity: configuration.memoryCacheBytes,
            diskCapacity: configuration.diskCacheBytes
        )
        sessionConfiguration.requestCachePolicy = .reloadRevalidatingCacheData
        sessionConfiguration.waitsForConnectivity = configuration.waitsForConnectivity
        self.session = URLSession(configuration: sessionConfiguration)
    }

    private static func makeDefaultInterceptors() -> [any HTTPInterceptor] {
        [
            UserAgentInterceptor(),
            RateLimitInterceptor(),
            CloudflareInterceptor(),
            RetryInterceptor(),
        ]
    }

    // MARK: Requests

    /// Send a request through the interceptor chain.
    ///
    /// - Parameter sourceKey: `"ln:<id>"` / `"mihon:<id>"`, used for per-source
    ///   rate limits. Pass `nil` for app-internal traffic.
    func send(_ request: HTTPRequest, sourceKey: String? = nil) async throws -> HTTPResponse {
        let context = InterceptorContext(
            sourceKey: sourceKey,
            host: request.host,
            allowsUserVerification: configuration.allowsUserVerification
        )
        var attempt = 0

        while true {
            attempt += 1
            let adapted = try await adapt(request, context: context)

            switch await perform(adapted) {
            case .success(let response) where response.isSuccess:
                return response

            case .success(let response):
                if attempt < configuration.maxAttempts,
                   let delay = await retryDelay(
                       request: adapted, response: response, attempt: attempt, context: context
                   ) {
                    try? await Task.sleep(for: .seconds(delay))
                    continue
                }
                // A challenge that survived the solver is not the site refusing the request: say
                // which it was, so a source's error message can tell the two apart.
                if response.looksLikeCloudflareChallenge {
                    throw HTTPError.cloudflareChallenge(
                        url: adapted.url.absoluteString,
                        detail: await CloudflareSolveGate.shared.note(for: context.host)
                    )
                }
                throw HTTPError.badStatus(
                    code: response.statusCode,
                    url: adapted.url.absoluteString
                )

            case .failure(let error):
                guard error.isRetryable, attempt < configuration.maxAttempts else {
                    throw error
                }
                // Transport failures get a plain exponential backoff; there is
                // no server response to ask for a Retry-After.
                try? await Task.sleep(for: .seconds(pow(2, Double(attempt - 1))))
            }
        }
    }

    /// Convenience for the common "GET a page as text" call.
    func getString(
        _ urlString: String,
        headers: [String: String] = [:],
        sourceKey: String? = nil
    ) async throws -> String {
        try await send(
            HTTPRequest(urlString: urlString, headers: headers),
            sourceKey: sourceKey
        ).text
    }

    func get(
        _ urlString: String,
        headers: [String: String] = [:],
        sourceKey: String? = nil
    ) async throws -> HTTPResponse {
        try await send(
            HTTPRequest(urlString: urlString, headers: headers),
            sourceKey: sourceKey
        )
    }

    func getJSON<T: Decodable>(
        _ urlString: String,
        headers: [String: String] = [:],
        sourceKey: String? = nil
    ) async throws -> T {
        try await get(urlString, headers: headers, sourceKey: sourceKey).decoded(T.self)
    }

    // MARK: Pipeline stages

    private func adapt(
        _ request: HTTPRequest,
        context: InterceptorContext
    ) async throws -> HTTPRequest {
        var adapted = request
        for interceptor in interceptors {
            adapted = try await interceptor.adapt(adapted, context: context)
        }
        return adapted
    }

    /// First interceptor that knows how to recover wins.
    private func retryDelay(
        request: HTTPRequest,
        response: HTTPResponse,
        attempt: Int,
        context: InterceptorContext
    ) async -> TimeInterval? {
        for interceptor in interceptors {
            if let delay = await interceptor.retryDelay(
                for: request, response: response, attempt: attempt, context: context
            ) {
                return delay
            }
        }
        return nil
    }

    private func perform(_ request: HTTPRequest) async -> Result<HTTPResponse, HTTPError> {
        var urlRequest = URLRequest(
            url: request.url,
            cachePolicy: .useProtocolCachePolicy,
            timeoutInterval: request.timeout ?? configuration.timeout
        )
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.transport("Response was not HTTP"))
            }
            var headers: [String: String] = [:]
            headers.reserveCapacity(http.allHeaderFields.count)
            for (name, value) in http.allHeaderFields {
                headers["\(name)"] = "\(value)"
            }
            return .success(
                HTTPResponse(
                    request: request,
                    url: http.url ?? request.url,
                    statusCode: http.statusCode,
                    headers: headers,
                    data: data
                )
            )
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }
}
