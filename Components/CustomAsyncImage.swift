// CustomAsyncImage.swift
// Cover loading: disk cache, dedupe, off-main decode, and the app's HTTP stack.

import CryptoKit
import ImageIO
import SwiftUI

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #elseif canImport(AppKit)
        self.init(nsImage: platformImage)
        #endif
    }
}

/// Decoding helpers for cover art.
///
/// `UIImage(data:)` keeps the compressed data and decodes lazily on first
/// draw — on the main thread, inside the render pass. A 1200×1800 cover
/// decodes to ~8 MB, and a library grid asks for a dozen at once. Downsampling
/// with ImageIO decodes once, off the main thread, to the size actually shown.
enum CoverDecode {

    /// Longest edge of a decoded cover. A grid cell is at most ~200 pt wide
    /// (600 px at 3×), so a 1200 px cover is 4× the memory for no visible gain.
    static let defaultMaxPixelSize = 700

    /// Longest edge for the detail screen's full-bleed hero. One image, sized
    /// for a 560 pt header at 3× — the 700 px grid decode would be visibly
    /// soft there, but a library's worth of covers must not pay for it.
    static let heroMaxPixelSize = 1800

    static func image(from data: Data, maxPixelSize: Int = defaultMaxPixelSize) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        // `ShouldCacheImmediately` decodes now rather than at draw time, which
        // is the whole point: the work happens on whatever executor we are on.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return PlatformImage(cgImage: cgImage)
    }

    /// Bytes the decoded image occupies, for `NSCache` cost accounting.
    static func cost(of image: PlatformImage) -> Int {
        #if canImport(UIKit)
        let size = image.size
        let scale = image.scale
        #else
        let size = image.size
        let scale: CGFloat = 1
        #endif
        return max(Int(size.width * scale * size.height * scale * 4), 1)
    }
}

/// Simple in-memory cache to prevent redundant image downloads.
///
/// Keyed by URL *and* decoded size: the hero asks for 1800 px where a grid
/// cell asks for 700, and sharing one key would hand whichever was decoded
/// first to both. Bytes still come from one disk entry per URL.
final class ImageCache {
    static let shared: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        // Cost is set from the decoded pixel size on every insert, so this is a
        // real byte budget rather than a count that happens to be bounded.
        cache.countLimit = 200
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    /// The cache key for one URL at one decode size.
    static func key(for url: URL, maxPixelSize: Int = CoverDecode.defaultMaxPixelSize) -> NSString {
        "\(maxPixelSize)|\(url.absoluteString)" as NSString
    }

    static func cached(_ url: URL, maxPixelSize: Int = CoverDecode.defaultMaxPixelSize) -> PlatformImage? {
        shared.object(forKey: key(for: url, maxPixelSize: maxPixelSize))
    }

    /// In-flight downloads keyed by URL and size so 20 cells showing the same
    /// cover share one network request instead of firing 20.
    private static let lock = NSLock()
    private static var inFlight: [NSString: Task<PlatformImage, Error>] = [:]

    static func dedupedDownload(for key: NSString, download: @escaping () async throws -> PlatformImage) async throws -> PlatformImage {
        let (task, isOwner) = claim(key, download: download)
        // Only the request's owner clears the entry; waiters just share its result.
        defer { if isOwner { release(key) } }
        return try await task.value
    }

    // Synchronous so the lock is never held across a suspension point.
    private static func claim(_ key: NSString, download: @escaping () async throws -> PlatformImage) -> (Task<PlatformImage, Error>, Bool) {
        lock.withLock {
            if let existing = inFlight[key] { return (existing, false) }
            let task = Task<PlatformImage, Error> { try await download() }
            inFlight[key] = task
            return (task, true)
        }
    }

    private static func release(_ key: NSString) {
        lock.withLock { _ = inFlight.removeValue(forKey: key) }
    }

    static func store(_ image: PlatformImage, for url: URL, maxPixelSize: Int = CoverDecode.defaultMaxPixelSize) {
        shared.setObject(
            image,
            forKey: key(for: url, maxPixelSize: maxPixelSize),
            cost: CoverDecode.cost(of: image))
    }
}

/// On-disk cover store under `Caches/`, independent of server cache headers.
///
/// `URLCache` only keeps what the CDN's headers allow, and many sources send
/// `no-store` or no validators, so an evicted cover was a full re-download.
/// This keeps the downloaded bytes keyed by a hash of the URL; a hit costs one
/// small file read and an off-main ImageIO decode.
enum CoverDiskCache {
    private static let maxAge: TimeInterval = 30 * 24 * 3600
    private static let maxBytes = 300 * 1024 * 1024

    private static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let writes = NSLock()
    private static var writeCount = 0

    private static func file(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return directory.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined())
    }

    /// Stored bytes, and whether they are older than `maxAge`.
    static func read(_ url: URL) -> (data: Data, isStale: Bool)? {
        let path = file(for: url)
        guard let data = try? Data(contentsOf: path), !data.isEmpty else { return nil }
        let modified = (try? path.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let stale = modified.map { Date().timeIntervalSince($0) > maxAge } ?? true
        return (data, stale)
    }

    static func write(_ data: Data, for url: URL) {
        try? data.write(to: file(for: url), options: .atomic)
        let shouldTrim = writes.withLock { () -> Bool in
            writeCount += 1
            return writeCount % 50 == 0
        }
        if shouldTrim { trim() }
    }

    /// Drops the oldest files once the folder passes `maxBytes`.
    private static func trim() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { url -> (URL, Date, Int)? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, v.contentModificationDate ?? .distantPast, v.fileSize ?? 0)
        }
        var total = entries.reduce(0) { $0 + $1.2 }
        guard total > maxBytes else { return }
        entries.sort { $0.1 < $1.1 }
        for entry in entries where total > maxBytes * 3 / 4 {
            try? FileManager.default.removeItem(at: entry.0)
            total -= entry.2
        }
    }
}

/// A drop-in replacement for SwiftUI's AsyncImage that keeps covers in a memory and a disk cache,
/// shares one download between the cells that show the same URL, and decodes off the main thread.
struct CustomAsyncImage: View {
    private let url: URL?
    private let maxPixelSize: Int
    private let content: (AsyncImagePhase) -> AnyView

    @State private var phase: AsyncImagePhase = .empty

    /// Initialize with a phase closure.
    init<Content: View>(
        url: URL?,
        maxPixelSize: Int = CoverDecode.defaultMaxPixelSize,
        @ViewBuilder content: @escaping (AsyncImagePhase) -> Content
    ) {
        self.url = url
        self.maxPixelSize = maxPixelSize
        self.content = { phase in AnyView(content(phase)) }
        _phase = State(initialValue: Self.cachedPhase(for: url, maxPixelSize: maxPixelSize))
    }

    /// Initialize with separate success and placeholder closures.
    init<I: View, P: View>(
        url: URL?,
        maxPixelSize: Int = CoverDecode.defaultMaxPixelSize,
        @ViewBuilder content: @escaping (Image) -> I,
        @ViewBuilder placeholder: @escaping () -> P
    ) {
        self.url = url
        self.maxPixelSize = maxPixelSize
        self.content = { phase in
            switch phase {
            case .success(let image):
                return AnyView(content(image))
            default:
                return AnyView(placeholder())
            }
        }
        _phase = State(initialValue: Self.cachedPhase(for: url, maxPixelSize: maxPixelSize))
    }

    /// A memory hit is known at construction, so a cell that scrolls back into
    /// view never renders the loading state first.
    private static func cachedPhase(for url: URL?, maxPixelSize: Int) -> AsyncImagePhase {
        guard let url, let image = ImageCache.cached(url, maxPixelSize: maxPixelSize) else { return .empty }
        return .success(Image(platformImage: image))
    }

    var body: some View {
        content(phase)
            .task(id: url) {
                await loadImage()
            }
    }

    private func loadImage() async {
        guard let url else {
            phase = .empty
            return
        }

        // Check in-memory cache first
        if let cachedImage = ImageCache.cached(url, maxPixelSize: maxPixelSize) {
            phase = .success(Image(platformImage: cachedImage))
            return
        }

        phase = .empty

        do {
            let key = ImageCache.key(for: url, maxPixelSize: maxPixelSize)
            let image = try await ImageCache.dedupedDownload(for: key) {
                try await Self.fetch(url, maxPixelSize: maxPixelSize)
            }
            ImageCache.store(image, for: url, maxPixelSize: maxPixelSize)
            phase = .success(Image(platformImage: image))
        } catch {
            // The only trace a cover failure leaves. One line per URL: the dedupe means one per
            // session, and a blank card on its own says nothing about why.
            print("❌ [CustomAsyncImage] \(url.absoluteString): \(error.localizedDescription)")
            phase = .failure(error)
        }
    }

    /// Runs inside the dedupe task, off the main actor: disk, then network.
    private static func fetch(_ url: URL, maxPixelSize: Int) async throws -> PlatformImage {
        if url.scheme == "local" || url.isFileURL {
            let fileURL: URL
            if url.scheme == "local" {
                let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                fileURL = docDir.appendingPathComponent((url.host ?? "").appending(url.path))
            } else {
                fileURL = url
            }
            let data = try Data(contentsOf: fileURL)
            guard let image = CoverDecode.image(from: data, maxPixelSize: maxPixelSize) else { throw URLError(.cannotDecodeContentData) }
            return image
        }

        let stored = CoverDiskCache.read(url)
        if let stored, !stored.isStale, let image = CoverDecode.image(from: stored.data, maxPixelSize: maxPixelSize) {
            return image
        }

        do {
            let data = try await HTTPClient.covers.send(HTTPRequest(url: url)).data
            guard let image = CoverDecode.image(from: data, maxPixelSize: maxPixelSize) else {
                throw URLError(.cannotDecodeContentData)
            }
            CoverDiskCache.write(data, for: url)
            return image
        } catch {
            // An expired copy beats a blank cover when the network is down.
            if let stored, let image = CoverDecode.image(from: stored.data, maxPixelSize: maxPixelSize) { return image }
            throw error
        }
    }
}
