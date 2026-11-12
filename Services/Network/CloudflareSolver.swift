// CloudflareSolver.swift - Solves Cloudflare interstitials in a web view.
//
// Some sources (Comick, several Madara sites) gate every page behind a
// `cf_clearance` cookie that only a real browser can earn. We load the
// challenged URL in an off-screen WKWebView, wait for the challenge to clear,
// and hand the cookies back to the HTTP client. A challenge the hidden view
// cannot pass (a checkbox) is shown to the user when the app is in front.

import Foundation
import UIKit
import WebKit

/// `CloudflareChallengeSolving` backed by a `WKWebView`.
struct WebKitCloudflareSolver: CloudflareChallengeSolving {

    /// How long to let the interstitial run hidden before giving up.
    var timeout: TimeInterval = 25

    func solve(url: URL, interactive: Bool) async throws -> CloudflareClearance {
        try await CloudflareWebView.solve(url: url, interactive: interactive, timeout: timeout)
    }
}

// MARK: - Web view driver

/// Challenge solving. Main-actor isolated because `WKWebView` is.
@MainActor
private enum CloudflareWebView {

    /// How long the user gets to complete a verification.
    private static let userAllowance: TimeInterval = 180

    /// Whether a verification sheet is up. One at a time: a second host's challenge fails
    /// rather than stacking a sheet on top of the first.
    private static var verifying = false

    /// Clears the challenge: hidden, under each agent a challenge may accept, then with the user.
    ///
    /// WebKit's own agent is what clears it on macOS; a Safari-looking one is what the same site
    /// may want on iOS. Which one wins is the site's decision, so both are tried, and whichever
    /// earns the clearance is the one the client has to keep presenting.
    static func solve(
        url: URL, interactive: Bool, timeout: TimeInterval
    ) async throws -> CloudflareClearance {
        // In the background WebKit throttles the view and the challenge never finishes: fail now
        // rather than hold a background refresh for the whole budget.
        guard UIApplication.shared.applicationState != .background else {
            throw AttemptFailure(detail: "the app was in the background; open it to clear the challenge")
        }

        let attempts: [(label: String, agent: String?)] = [
            ("webkit", nil),
            ("safari", UserAgentInterceptor.defaultUserAgent),
        ]
        var failures: [String] = []
        for attempt in attempts {
            do {
                return try await clearHidden(
                    url: url, agent: attempt.agent, timeout: timeout / Double(attempts.count)
                )
            } catch {
                failures.append("\(attempt.label) agent: \(error.localizedDescription)")
            }
        }

        if interactive, UIApplication.shared.applicationState == .active {
            do {
                return try await verifyWithUser(url: url)
            } catch {
                failures.append("verification: \(error.localizedDescription)")
            }
        }
        throw AttemptFailure(detail: failures.joined(separator: "; "))
    }

    /// One hidden web view, one agent, one budget.
    private static func clearHidden(
        url: URL, agent: String?, timeout: TimeInterval
    ) async throws -> CloudflareClearance {
        let webView = makeWebView()
        if let agent { webView.customUserAgent = agent }
        let attached = WebViewCapture.parkHidden(webView)
        let previous = await clearanceValue(for: url, in: webView)
        webView.load(URLRequest(url: url))

        defer {
            webView.stopLoading()
            webView.removeFromSuperview()
            webView.loadHTMLString("", baseURL: nil)
        }

        let deadline = Date().addingTimeInterval(timeout)
        if let clearance = try await waitForClearance(
            on: url, in: webView, replacing: previous, until: deadline, agent: agent
        ) {
            return clearance
        }

        // Say what the page was showing, so a failure is not just "timeout". A detached view is
        // the difference between "the challenge never ran" and "the site refused us".
        let title = await javascript("document.title", in: webView) ?? "-"
        throw AttemptFailure(
            detail: "no clearance in \(Int(timeout))s (title \"\(title)\", "
                + "window: \(attached ? "yes" : "no"))"
        )
    }

    /// Shows the challenge in a sheet, for the ones a hidden view cannot pass: a checkbox, or a
    /// check that escalates to one.
    private static func verifyWithUser(url: URL) async throws -> CloudflareClearance {
        guard !verifying, let presenter = WebViewCapture.topViewController() else {
            throw AttemptFailure(detail: "needed the user, but nothing could show the page")
        }
        verifying = true
        defer { verifying = false }

        let webView = makeWebView()
        let previous = await clearanceValue(for: url, in: webView)
        let cancelled = Flag()
        let controller = ChallengeController(
            webView: webView, title: url.host ?? "Verify you are human"
        ) { cancelled.isSet = true }
        let sheet = UINavigationController(rootViewController: controller)
        presenter.present(sheet, animated: true)
        webView.load(URLRequest(url: url))

        defer {
            webView.stopLoading()
            if sheet.presentingViewController != nil { sheet.dismiss(animated: true) }
        }

        let deadline = Date().addingTimeInterval(userAllowance)
        if let clearance = try await waitForClearance(
            on: url, in: webView, replacing: previous, until: deadline, agent: nil,
            stopIf: { cancelled.isSet }
        ) {
            return clearance
        }
        throw AttemptFailure(detail: cancelled.isSet ? "cancelled" : "not completed in time")
    }

    /// Polls for a `cf_clearance` for `url`'s host that differs from `previous`.
    ///
    /// The data store is shared, so it already holds clearances for other hosts, and may hold a
    /// stale one for this host — the one the challenged request just sent. Neither is an answer.
    private static func waitForClearance(
        on url: URL,
        in webView: WKWebView,
        replacing previous: String?,
        until deadline: Date,
        agent: String?,
        stopIf stop: () -> Bool = { false }
    ) async throws -> CloudflareClearance? {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        while Date() < deadline, !stop() {
            try Task.checkCancellation()
            try? await Task.sleep(for: .milliseconds(600))

            let cookies = cookies(for: url, in: await allCookies(in: store))
            let clearance = cookies.first { $0.name == "cf_clearance" }?.value
            if let clearance, clearance != previous {
                let used = await javascript("navigator.userAgent", in: webView) ?? agent
                return CloudflareClearance(cookies: cookies, userAgent: used)
            }
        }
        return nil
    }

    private static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Share the app's data store so a solved challenge also helps the
        // login flows that use a visible web view.
        configuration.websiteDataStore = .default()
        return WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
    }

    private static func clearanceValue(for url: URL, in webView: WKWebView) async -> String? {
        let all = await allCookies(in: webView.configuration.websiteDataStore.httpCookieStore)
        return cookies(for: url, in: all).first { $0.name == "cf_clearance" }?.value
    }

    /// The cookies that would be sent to `url`'s host.
    private static func cookies(for url: URL, in cookies: [HTTPCookie]) -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        return cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return host == domain || host.hasSuffix("." + domain)
        }
    }

    private final class Flag {
        var isSet = false
    }

    private struct AttemptFailure: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    private static func javascript(_ script: String, in webView: WKWebView) async -> String? {
        (try? await webView.evaluateJavaScript(script)) as? String
    }

    private static func allCookies(in store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }
}
