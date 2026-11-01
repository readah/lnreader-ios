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
        NavigationStack {
            WebView(page)
                .webViewBackForwardNavigationGestures(.enabled)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) { progressBar }
                .navigationTitle(page.title.isEmpty ? title : page.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
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

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Button {
                if let item = page.backForwardList.backList.last { page.load(item) }
            } label: {
                Label("Back", systemImage: "chevron.backward")
            }
            .disabled(page.backForwardList.backList.isEmpty)

            Button {
                if let item = page.backForwardList.forwardList.first { page.load(item) }
            } label: {
                Label("Forward", systemImage: "chevron.forward")
            }
            .disabled(page.backForwardList.forwardList.isEmpty)

            Spacer()

            Button { page.reload() } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }

            ShareLink(item: currentURL)

            Button { openURL(currentURL) } label: {
                Label("Open in Safari", systemImage: "safari")
            }
        }
    }
}
