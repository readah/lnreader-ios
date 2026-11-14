// ChapterCache.swift - On-disk LRU cache for chapter images.
//
// Manga reading re-reads the same pages constantly: scrolling back, jumping
// between chapters, reopening a book. The cache is keyed by the image URL, so
// it serves the pager, the webtoon strip and downloads alike.

import CryptoKit
import Foundation

/// A bounded, self-trimming disk cache.
///
/// LRU order comes from each file's modification date, which is touched on every
/// hit. That survives app restarts for free and needs no separate index file
/// that could drift from the contents of the directory.
actor ChapterCache {

    /// Process-wide cache. One instance so the pager, the webtoon strip and
    /// downloads share both the bytes and the size accounting.
    static let shared = ChapterCache()

    /// Directory holding the cached images.
    private let directory: URL
    /// Trim threshold in bytes.
    private let limitBytes: Int
    /// Trim down to this fraction of the limit, so trimming is not a per-write cost.
    private let trimTarget: Double
    private let fileManager: FileManager

    private var cachedSize: Int?

    /// When each file's modification date was last bumped, so a read that just
    /// touched it does not touch it again. Cleared wholesale past a cap.
    private var touched: [String: Date] = [:]
    private static let touchInterval: TimeInterval = 60
    private static let touchedLimit = 1024

    init(
        directory: URL = ChapterCache.defaultDirectory,
        limitBytes: Int = 512 * 1024 * 1024,
        trimTarget: Double = 0.9,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.limitBytes = limitBytes
        self.trimTarget = trimTarget
        self.fileManager = fileManager
    }

    /// `Application Support/ChapterCache`.
    ///
    /// Excluded from device backups: it is a cache, and re-downloading is
    /// cheaper than carrying hundreds of megabytes in iCloud.
    static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "ChapterCache", directoryHint: .isDirectory)
    }

    // MARK: - Keys

    /// Cache key for an image URL. MD5 matches what the plan specifies and keeps
    /// filenames short and filesystem-safe.
    nonisolated static func key(for url: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(url.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Reads

    /// Cached bytes for `url`, touching its LRU position.
    func data(for url: String) -> Data? {
        let file = fileURL(for: url)
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        // Touching the modification date is the whole LRU mechanism, but it is a
        // syscall on every read, and the reader asks for the same page several
        // times (the cell, the prefetch, then the cell again). A minute of
        // granularity is far finer than a 512 MB LRU needs.
        let now = Date.now
        if let last = touched[url], now.timeIntervalSince(last) < Self.touchInterval {
            return data
        }
        try? fileManager.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        if touched.count >= Self.touchedLimit { touched.removeAll(keepingCapacity: true) }
        touched[url] = now
        return data
    }

    func contains(_ url: String) -> Bool {
        fileManager.fileExists(atPath: fileURL(for: url).path)
    }

    // MARK: - Writes

    /// Store bytes for `url`, trimming if the cache grew past its limit.
    func store(_ data: Data, for url: String) {
        guard !data.isEmpty else { return }

        // Measure before writing: counting afterwards would include the file we
        // are about to add and double-count it.
        let sizeBeforeWrite = cachedSize ?? currentSizeBytes()

        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let file = fileURL(for: url)
        // Write-then-rename: a crash mid-write must not leave a half image that
        // the reader would happily decode into a corrupt page.
        let temporary = file.appendingPathExtension("tmp")
        do {
            try data.write(to: temporary, options: .atomic)
            _ = try fileManager.replaceItemAt(file, withItemAt: temporary)
        } catch {
            try? data.write(to: file, options: .atomic)
            try? fileManager.removeItem(at: temporary)
        }

        let newSize = sizeBeforeWrite + data.count
        cachedSize = newSize
        if newSize > limitBytes {
            trim()
        }
    }

    func remove(_ url: String) {
        let file = fileURL(for: url)
        let size = fileSize(file)
        try? fileManager.removeItem(at: file)
        touched[url] = nil
        if let cachedSize { self.cachedSize = max(0, cachedSize - size) }
    }

    func removeAll() {
        try? fileManager.removeItem(at: directory)
        touched.removeAll()
        cachedSize = 0
    }

    // MARK: - Size and trimming

    func currentSizeBytes() -> Int {
        let size = directorySize()
        cachedSize = size
        return size
    }

    /// Delete least-recently-used files until the cache is back under `trimTarget`.
    func trim() {
        let target = Int(Double(limitBytes) * trimTarget)
        var entries = filesByAge()
        var total = entries.reduce(0) { $0 + $1.size }

        while total > target, let oldest = entries.first {
            try? fileManager.removeItem(at: oldest.url)
            total -= oldest.size
            entries.removeFirst()
        }

        cachedSize = total
    }

    // MARK: - Files

    private func fileURL(for url: String) -> URL {
        directory.appending(path: Self.key(for: url))
    }

    private func fileSize(_ url: URL) -> Int {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    private func directorySize() -> Int {
        filesByAge().reduce(0) { $0 + $1.size }
    }

    /// Every cached file, oldest first.
    private func filesByAge() -> [(url: URL, size: Int)] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else {
            return []
        }

        return files
            .compactMap { file -> (url: URL, size: Int, date: Date)? in
                guard let values = try? file.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey]
                ) else { return nil }
                return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.date < $1.date }
            .map { (url: $0.url, size: $0.size) }
    }
}
