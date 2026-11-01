// MangaPageView.swift - One page image, loaded through PageLoader.

import SwiftUI

/// Displays a single page, with its own loading and failure state.
///
/// Each page owns its load task, so a slow page in the middle of a chapter never
/// blocks the ones around it.
struct MangaPageView: View {

    let page: SourcePage
    let sourceKey: String
    let loader: PageLoader

    @Environment(\.displayScale) private var displayScale
    @Environment(\.coverTint) private var coverTint
    @State private var image: UIImage?
    @State private var loadedURL: String?
    @State private var didFail = false
    @State private var attempt = 0

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
            } else if didFail {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundStyle(.white.opacity(0.7))
                    Text("Page \(page.index + 1) could not be loaded")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                    Button("Retry") {
                        attempt += 1
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                placeholder
            }
        }
        // Re-runs when the page changes or the user retries, and on every
        // reappearance (a `.task` restarts when its view comes back on screen).
        .task(id: "\(page.url)#\(attempt)") {
            await load()
        }
        // Off screen, give the bitmap back. The decoded-image cache still holds
        // the neighbourhood, so scrolling straight back is instant; a long
        // chapter no longer keeps every page's bitmap alive.
        .onDisappear {
            image = nil
        }
    }

    /// Keeps the page's real height when it is known, so releasing the bitmap
    /// does not collapse the slot to a spinner-sized row.
    @ViewBuilder
    private var placeholder: some View {
        if let ratio = PageImageCache.aspectRatios[page.url], ratio > 0 {
            Color.clear
                .aspectRatio(ratio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay { ProgressView().tint(coverTint ?? .white) }
        } else {
            ProgressView()
                .tint(coverTint ?? .white)
                .frame(maxWidth: .infinity, minHeight: 220)
        }
    }

    /// Width of the screen this app is on, without the deprecated `UIScreen.main`.
    static var screenWidth: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen.bounds.width }
            .first ?? 390
    }

    private func load() async {
        let requestedURL = page.url
        didFail = false
        if image != nil, loadedURL == requestedURL { return }

        if let cached = PageImageCache.shared.object(forKey: requestedURL as NSString) {
            image = cached
            loadedURL = requestedURL
            return
        }

        image = nil
        do {
            let data = try await loader.image(for: page, sourceKey: sourceKey)
            guard !Task.isCancelled else { return }
            let decoded = await PageDecode.decode(
                data,
                targetWidth: Self.screenWidth * displayScale,
                screenScale: displayScale
            )
            guard !Task.isCancelled else { return }
            guard let decoded else {
                throw HTTPError.transport("Page \(page.index + 1) is not a valid image")
            }
            PageImageCache.store(decoded, forKey: requestedURL)
            image = decoded
            loadedURL = requestedURL
        } catch {
            if !Task.isCancelled {
                didFail = true
            }
        }
    }
}
