import SwiftUI
import WebKit
import Combine

#if os(iOS)
typealias PlatformViewRepresentable = UIViewRepresentable
#else
typealias PlatformViewRepresentable = NSViewRepresentable
#endif

struct NovelFireLoginView: View {
    @Environment(\.dismiss) private var dismiss
    var onLoginSuccess: () -> Void
    /// Which LNW-family site to sign in to. Defaults to NovelFire for backwards compatibility.
    var site: CommentSite = .novelFire
    
    @State private var retryID = UUID()
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    
    var body: some View {
        NavigationStack {
          ZStack {
            NovelFireWebViewWrapper(
                url: site.googleAuthURL,
                site: site,
                isLoading: $isLoading,
                errorMessage: $errorMessage,
                onSuccess: {
                    onLoginSuccess()
                    dismiss()
                }
            )
            .id(retryID)
            .ignoresSafeArea(edges: .bottom)
            
            if isLoading {
                ProgressView("Loading Google Sign-in...")
                    .padding()
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
            }
            
            if let error = errorMessage {
                ContentUnavailableView {
                    AppLabel("Sign-in failed", systemName: "exclamationmark.triangle.fill", size: 17, relativeTo: .body)
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") {
                        errorMessage = nil
                        isLoading = true
                        retryID = UUID()
                    }
                    .primaryActionStyle()
                }
                .appBackdrop()
            }
          }
          .appNavigationTitle("Sign In to \(site.displayName)")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
          #endif
        }
    }
}

struct NovelFireWebViewWrapper: PlatformViewRepresentable {
    let url: URL
    var site: CommentSite = .novelFire
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?
    var onSuccess: () -> Void
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    #if os(iOS)
    func makeUIView(context: Context) -> WKWebView {
        return createWebView(context: context)
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) { context.coordinator.parent = self }
    #else
    func makeNSView(context: Context) -> WKWebView {
        return createWebView(context: context)
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) { context.coordinator.parent = self }
    #endif
    
    private func createWebView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        
        // Use a clean desktop Safari user agent to bypass Google disallowed_useragent OAuth block
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
        
        // Keep existing cookies. Laravel creates session cookies for guests too;
        // their presence alone is never proof that Google sign-in completed.
        webView.load(URLRequest(url: url))

        return webView
    }
    
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private var completed = false
        var parent: NovelFireWebViewWrapper
        
        init(parent: NovelFireWebViewWrapper) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = true
            }
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
            checkCookies(webView: webView)
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.errorMessage = error.localizedDescription
            }
        }
        
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.errorMessage = error.localizedDescription
            }
        }
        
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }

        private func checkCookies(webView: WKWebView) {
            guard !completed, let url = webView.url, parent.site.matches(host: url.host) else { return }
            let site = parent.site
            webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self, weak webView] value, _ in
                guard let self, let webView, !self.completed, site.matches(host: webView.url?.host), let html = value as? String,
                      NovelFireCommentsService.isAuthenticatedPage(html) else { return }
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    let matching = cookies.filter { site.matches(host: $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
                    guard matching.contains(where: { $0.name == site.sessionCookieName }) else { return }
                    DispatchQueue.main.async {
                        guard !self.completed else { return }
                        self.completed = true
                        matching.forEach { HTTPCookieStorage.shared.setCookie($0) }
                        UserDefaults.standard.set(true, forKey: "comments.authenticated." + site.rawValue)
                        self.parent.onSuccess()
                    }
                }
            }
        }
    }
}
