// WebViewCapture.swift - Lets a native source borrow a real browser engine.
//
// Some sources (AllManga) hide their image list behind client-side code that only a browser can
// run: the page boots a crypto handshake, then asks its API for the chapter. Upstream Mihon
// extensions solve that with a WebView that loads the site and listens for the payload. A source
// calls `WebViewCapture.capture(_:)`; the session loads the page on the main actor and hands back
// the first message the page posts through `window.__lnrPost`. When the site asks a human to
// verify, the web view is shown in a sheet so they can.

import Foundation
import WebKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// What a source asks the web view to do.
struct WebViewCaptureOptions: Sendable {
    /// Document URL. Also the base URL when `html` is supplied.
    var url: String
    /// Load this markup instead of fetching `url`, so the source controls what
    /// the page starts from (cookies and headers it already holds).
    var html: String?
    var userAgent: String?
    /// Run at document start, in every frame, before any page script.
    /// `window.__lnrPost(string)` is defined for them; the first call resolves
    /// the capture.
    var startScripts: [String]?
    var blockImages: Bool?
    var timeoutMs: Int?
    /// JS expression that is truthy while the site is asking a human to
    /// verify (a captcha overlay, an interstitial). When it stays truthy for a
    /// few seconds the web view is shown to the user so they can complete it;
    /// capture then carries on. Nothing here solves or skips the check.
    var challengeScript: String?
    /// Title for the sheet the user sees.
    var challengeTitle: String?
    /// Print the page's console output, script errors and failed requests to
    /// stdout. For developing a source; never set in a shipped one.
    var debug: Bool?

    init(
        url: String,
        html: String? = nil,
        userAgent: String? = nil,
        startScripts: [String]? = nil,
        blockImages: Bool? = nil,
        timeoutMs: Int? = nil,
        challengeScript: String? = nil,
        challengeTitle: String? = nil,
        debug: Bool? = nil
    ) {
        self.url = url
        self.html = html
        self.userAgent = userAgent
        self.startScripts = startScripts
        self.blockImages = blockImages
        self.timeoutMs = timeoutMs
        self.challengeScript = challengeScript
        self.challengeTitle = challengeTitle
        self.debug = debug
    }
}

enum WebViewCapture {

    enum CaptureError: LocalizedError {
        case badOptions
        case timedOut
        case blocked(String)
        case navigation(String)

        var errorDescription: String? {
            switch self {
            case .badOptions: "The page address was not valid"
            case .timedOut: "The page did not produce a result in time"
            case .blocked(let message): message
            case .navigation(let message): message
            }
        }
    }

    /// Loads the page and returns the first string it posts through `window.__lnrPost`.
    ///
    /// Runs on the main actor; the caller may be anywhere. Throws `CaptureError` on timeout,
    /// navigation failure, or a verification the user did not complete.
    static func capture(_ options: WebViewCaptureOptions) async throws -> String {
        try await Task { @MainActor in
            if options.debug == true { print("[webview] session starting") }
            return try await Session(options: options).run()
        }.value
    }

    // MARK: - Session

    /// One throwaway web view. Main-actor isolated because `WKWebView` is.
    @MainActor
    fileprivate final class Session: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

        private let options: WebViewCaptureOptions
        private let handlerName = "h" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        private var webView: WKWebView?
        private var continuation: CheckedContinuation<String, Error>?
        private var finished = false
        #if canImport(UIKit)
        private var challengeController: ChallengeController?
        #else
        private var hostWindow: NSWindow?
        #endif

        init(options: WebViewCaptureOptions) {
            self.options = options
        }

        func run() async throws -> String {
            guard let pageURL = URL(string: options.url) else { throw CaptureError.badOptions }

            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            let controller = WKUserContentController()
            controller.add(self, name: handlerName)

            let bridge = """
            window.__lnrPost = function (s) {
              window.webkit.messageHandlers.\(handlerName).postMessage(String(s));
            };
            """
            controller.addUserScript(WKUserScript(
                source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            if options.debug == true {
                controller.add(self, name: handlerName + "log")
                controller.addUserScript(WKUserScript(
                    source: Self.debugScript(handler: handlerName + "log"),
                    injectionTime: .atDocumentStart, forMainFrameOnly: false))
            }
            for source in options.startScripts ?? [] {
                controller.addUserScript(WKUserScript(
                    source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            }

            if options.blockImages == true, let list = await Self.imageBlockList() {
                controller.add(list)
            }
            configuration.userContentController = controller

            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844),
                                 configuration: configuration)
            if let agent = options.userAgent { view.customUserAgent = agent }
            view.navigationDelegate = self
            attach(view)
            webView = view

            defer { teardown() }

            deadline = Date().addingTimeInterval(Double(options.timeoutMs ?? 20_000) / 1000)
            // Two independent tasks: `evaluateJavaScript` never returns when the
            // web content process is gone, and the deadline must still fire.
            let watchdog = Task { [weak self] in await self?.watchDeadline() }
            let challenges = Task { [weak self] in await self?.watchChallenge() }
            defer { watchdog.cancel(); challenges.cancel() }

            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if let html = options.html {
                    view.loadHTMLString(html, baseURL: pageURL)
                } else {
                    view.load(URLRequest(url: pageURL))
                }
            }
        }

        // MARK: Results

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? String else { return }
            if message.name == handlerName + "log" {
                print("[webview] \(body)")
            } else {
                finish(.success(body))
            }
        }

        private static func debugScript(handler: String) -> String {
            """
            (function () {
              var send = function (s) { window.webkit.messageHandlers.\(handler).postMessage(String(s).slice(0, 400)); };
              ['log', 'warn', 'error'].forEach(function (k) {
                var original = console[k];
                console[k] = function () { send(k + ': ' + Array.prototype.join.call(arguments, ' ')); return original.apply(console, arguments); };
              });
              window.addEventListener('error', function (e) { send('onerror: ' + e.message + ' ' + (e.filename || '')); });
              window.addEventListener('unhandledrejection', function (e) { send('rejection: ' + e.reason); });
              var f = window.fetch;
              window.fetch = function (u) {
                var url = (u && u.url) || u;
                return f.apply(this, arguments).then(function (r) {
                  send('fetch ' + r.status + ' ' + String(url).slice(0, 60));
                  if (String(url).indexOf('chapterString') >= 0) { r.clone().text().then(function (t) { send('BODY ' + t.slice(0, 300)); }); }
                  return r; },
                  function (err) { send('fetch FAIL ' + url + ' ' + err); throw err; });
              };
            })();
            """
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            if options.debug == true { print("[webview] didCommit \(webView.url?.absoluteString ?? "?")") }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if options.debug == true { print("[webview] didFinish") }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            finish(.failure(CaptureError.navigation("The web content process stopped")))
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finish(.failure(CaptureError.navigation(error.localizedDescription)))
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            finish(.failure(CaptureError.navigation(error.localizedDescription)))
        }

        private func finish(_ result: Result<String, Error>) {
            guard !finished, let continuation else { return }
            finished = true
            self.continuation = nil
            continuation.resume(with: result)
        }

        // MARK: Deadline and human verification

        private var deadline = Date()
        private var challengeShown = false

        /// How long a person gets to complete a verification.
        nonisolated fileprivate static let challengeAllowance: TimeInterval = 180

        private func watchDeadline() async {
            while !Task.isCancelled && !finished {
                try? await Task.sleep(for: .milliseconds(250))
                guard Date() >= deadline else { continue }
                if options.debug == true, let webView {
                    Task { @MainActor in
                        let state = try? await webView.evaluateJavaScript(
                            "document.title + ' | ' + document.body.innerText.slice(0, 200)")
                        print("[webview] timeout state: \(String(describing: state))")
                    }
                }
                finish(.failure(challengeShown
                    ? CaptureError.blocked("Verification was not completed. Open the chapter again to retry.")
                    : CaptureError.timedOut))
                return
            }
        }

        private func watchChallenge() async {
            guard let script = options.challengeScript, !script.isEmpty else { return }
            var visibleFor = 0
            var goneFor = 0
            while !Task.isCancelled && !finished {
                try? await Task.sleep(for: .milliseconds(250))
                let showing = await evaluateTruthy(script)
                if !challengeShown {
                    visibleFor = showing ? visibleFor + 1 : 0
                    if visibleFor >= 12 { presentChallenge() }   // about 3 s
                } else {
                    // Verified, but the page produced nothing afterwards.
                    goneFor = showing ? 0 : goneFor + 1
                    if goneFor >= 40 {                            // about 10 s
                        finish(.failure(CaptureError.blocked(
                            "Verification finished, but the chapter did not load. Open it again.")))
                        return
                    }
                }
            }
        }

        private func evaluateTruthy(_ script: String) async -> Bool {
            guard let webView else { return false }
            let value = try? await webView.evaluateJavaScript("!!(\(script))")
            return (value as? Bool) == true
        }

        private func presentChallenge() {
            guard !challengeShown, let webView else { return }
            challengeShown = true
            deadline = Date().addingTimeInterval(Self.challengeAllowance)
            #if canImport(UIKit)
            let controller = ChallengeController(
                webView: webView,
                title: options.challengeTitle ?? "Verify you are human",
                onCancel: { [weak self] in
                    self?.finish(.failure(CaptureError.blocked("Verification was cancelled.")))
                })
            challengeController = controller
            let presenter = WebViewCapture.topViewController()
            presenter?.present(UINavigationController(rootViewController: controller), animated: true)
            if presenter == nil {
                finish(.failure(CaptureError.blocked("The page needs verification, but nothing could show it.")))
            }
            #elseif canImport(AppKit)
            hostWindow?.setFrame(CGRect(x: 200, y: 200, width: 420, height: 760), display: true)
            hostWindow?.orderFrontRegardless()
            #endif
            if options.debug == true { print("[webview] showing verification to the user") }
        }

        // MARK: Lifecycle

        private func attach(_ view: WKWebView) {
            #if canImport(UIKit)
            view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            WebViewCapture.parkHidden(view)
            #elseif canImport(AppKit)
            // Command-line harness: an off-screen window keeps WebKit awake.
            let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 390, height: 844),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFront(nil)
            hostWindow = window
            #endif
        }

        private func teardown() {
            webView?.stopLoading()
            webView?.configuration.userContentController.removeAllUserScripts()
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: handlerName)
            if options.debug == true {
                webView?.configuration.userContentController.removeScriptMessageHandler(forName: handlerName + "log")
            }
            #if canImport(UIKit)
            if let challengeController {
                challengeController.navigationController?.dismiss(animated: true)
                self.challengeController = nil
            }
            webView?.removeFromSuperview()
            #elseif canImport(AppKit)
            hostWindow?.close()
            hostWindow = nil
            #endif
            webView = nil
        }

        private static var cachedImageBlockList: WKContentRuleList?

        private static func imageBlockList() async -> WKContentRuleList? {
            if let cachedImageBlockList { return cachedImageBlockList }
            let rules = #"[{"trigger":{"url-filter":".*","resource-type":["image","media","font"]},"action":{"type":"block"}}]"#
            let list = try? await WKContentRuleListStore.default()
                .compileContentRuleList(forIdentifier: "lnr-block-media", encodedContentRuleList: rules)
            cachedImageBlockList = list
            return list
        }
    }

}

#if canImport(UIKit)
extension WebViewCapture {
    /// Puts a web view in the app's window, invisible and behind the app's own content.
    ///
    /// WebKit throttles a web view that is not in a window, and page scripts (a Cloudflare
    /// challenge, a reader that builds its pages in JavaScript) then never finish.
    ///
    /// - Returns: whether a window was found.
    @MainActor @discardableResult
    static func parkHidden(_ view: UIView) -> Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first else {
            return false
        }
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        window.insertSubview(view, at: 0)
        return true
    }
}

extension WebViewCapture {
    /// The view controller a sheet should be presented from.
    @MainActor
    static func topViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?.rootViewController
        var top = root
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// The sheet that holds the web view while the user completes a verification.
final class ChallengeController: UIViewController {
    private let webView: WKWebView
    private let onCancel: () -> Void

    init(webView: WKWebView, title: String, onCancel: @escaping () -> Void) {
        self.webView = webView
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.onCancel() })
        webView.removeFromSuperview()
        webView.alpha = 1
        webView.isUserInteractionEnabled = true
        webView.frame = view.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(webView)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Swiped away instead of cancelled.
        if isBeingDismissed || navigationController?.isBeingDismissed == true { onCancel() }
    }
}
#endif
