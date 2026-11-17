// EntryWebView.swift - An entry's page on its site, opened from the detail toolbar.
//
// The page runs in the app's own WebKit data store with the scraper's User-Agent,
// and cookies are synced both ways: what the scraper holds goes in before the
// page loads, and what the page earned (a Cloudflare clearance, a login) comes
// back out when the sheet closes, so the next refresh can use it.

import SwiftUI
import WebKit

struct EntryWebView: View {
    let url: URL
    let title: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var page: WebPage = {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .default()
        let page = WebPage(configuration: configuration)
        page.customUserAgent = UserAgentInterceptor.defaultUserAgent
        return page
    }()

    var body: some View {
        AppNavigationStack {
            WebView(page)
                .webViewBackForwardNavigationGestures(.enabled)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) { progressBar }
                .appNavigationTitle(page.title.isEmpty ? title : page.title)
                .navigationBarTitleDisplayMode(.inline)
                .appToolbar { toolbar }
        }
        .task {
            await CookieJar.exportToWebKit()
            page.load(URLRequest(url: url))
        }
        .onDisappear {
            Task { await CookieJar.importFromWebKit() }
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if page.isLoading {
            ProgressView(value: page.estimatedProgress)
                .progressViewStyle(.linear)
                .transition(.opacity)
        }
    }

    /// The address the page is on now, falling back to the one it was opened with.
    private var currentURL: URL { page.url ?? url }

    @AppToolbarBuilder
    private var toolbar: some AppToolbarContent {
        AppToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
        AppToolbarItemGroup(placement: .bottomBar) {
            Button {
                if let item = page.backForwardList.backList.last { page.load(item) }
            } label: {
                AppLabel("Back", systemName: "chevron.backward", size: 17, relativeTo: .body)
            }
            .disabled(page.backForwardList.backList.isEmpty)

            Button {
                if let item = page.backForwardList.forwardList.first { page.load(item) }
            } label: {
                AppLabel("Forward", systemName: "chevron.forward", size: 17, relativeTo: .body)
            }
            .disabled(page.backForwardList.forwardList.isEmpty)

            Spacer()

            Button { page.reload() } label: {
                AppLabel("Reload", systemName: "arrow.clockwise", size: 17, relativeTo: .body)
            }

            ShareLink(item: currentURL)

            Button { openURL(currentURL) } label: {
                AppLabel("Open in Safari", systemName: "safari", size: 17, relativeTo: .body)
            }
        }
    }
}
