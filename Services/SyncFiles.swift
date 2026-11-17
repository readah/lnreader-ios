import CryptoKit
import Foundation

enum SyncFiles {
    static let chunkSize = 4 * 1024 * 1024
    static let fileLimit = 256 * 1024 * 1024
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func localID(_ book: SyncNovelPayload) throws -> String {
        guard book.path.hasPrefix("local://") else { throw CocoaError(.fileReadInvalidFileName) }
        let id = String(book.path.dropFirst(8))
        guard UUID(uuidString: id) != nil else { throw CocoaError(.fileReadInvalidFileName) }
        return id
    }

    static func fileURL(_ path: String, root: URL) throws -> URL {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.contains("\\"), !path.contains("\0"),
              pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              (pieces.first == "LocalNovels" && pieces.count >= 3) || (pieces.first == "Covers" && pieces.count == 2) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let target = resolvedRoot.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard target.path.hasPrefix(resolvedRoot.path + "/") else { throw CocoaError(.fileReadInvalidFileName) }
        return target
    }

    static func snapshot(_ books: [SyncNovelPayload], includeLocalBooks: Bool = true, root: URL = documents,
                         onProgress: (Int, Int) -> Void = { _, _ in }) throws -> [SyncFilePayload] {
        var paths = Set<String>()
        let fm = FileManager.default
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        if includeLocalBooks {
            let locals = books.filter { $0.sourceKey == SourceKey.local }
            for (index, book) in locals.enumerated() {
                let id = try localID(book)
                let directory = resolvedRoot.appendingPathComponent("LocalNovels/\(id)")
                var enumerationError: Error?
                guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    errorHandler: { _, error in enumerationError = error; return false }) else { throw CocoaError(.fileNoSuchFile) }
                for case let file as URL in enumerator {
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isSymbolicLink != true else { throw CocoaError(.fileReadInvalidFileName) }
                    guard values.isRegularFile == true else { continue }
                    let resolved = file.resolvingSymlinksInPath().standardizedFileURL.path
                    guard resolved.hasPrefix(directory.path + "/") else { throw CocoaError(.fileReadInvalidFileName) }
                    paths.insert(String(resolved.dropFirst(resolvedRoot.path.count + 1)))
                }
                if let enumerationError { throw enumerationError }
                onProgress(index + 1, locals.count)
            }
        }
        for book in books {
            if let cover = book.cover, cover.hasPrefix("local://Covers/") {
                let relPath = String(cover.dropFirst(8))
                if fm.fileExists(atPath: resolvedRoot.appendingPathComponent(relPath).path) {
                    paths.insert(relPath)
                }
            }
        }
        var files: [SyncFilePayload] = []
        for path in paths.sorted() {
            let url = try fileURL(path, root: root)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= fileLimit else { throw CocoaError(.fileReadTooLarge) }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var chunks: [String] = []
            while let bytes = try handle.read(upToCount: chunkSize), !bytes.isEmpty { chunks.append(hash(bytes)) }
            files.append(SyncFilePayload(path: path, size: size, chunks: chunks))
        }
        try validate(files, books: books, allowMissingLocalFiles: !includeLocalBooks)
        return files
    }

    static func validate(_ files: [SyncFilePayload], books: [SyncNovelPayload], allowMissingLocalFiles: Bool = false) throws {
        guard files.count <= 100_000, Set(files.map(\.path)).count == files.count else { throw CocoaError(.fileReadCorruptFile) }
        for file in files {
            _ = try fileURL(file.path, root: documents)
            guard file.size >= 0, file.size <= fileLimit,
                  file.chunks.count == (file.size + chunkSize - 1) / chunkSize,
                  file.chunks.allSatisfy({ $0.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        let paths = Set(files.map(\.path))
        for book in books where book.sourceKey == SourceKey.local {
            let id = try localID(book)
            guard !book.chapters.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            let hasAnyBookFiles = book.chapters.contains { paths.contains("LocalNovels/\(id)/\($0.path)") }
            if !allowMissingLocalFiles || hasAnyBookFiles {
                for chapter in book.chapters {
                    guard paths.contains("LocalNovels/\(id)/\(chapter.path)") else { throw CocoaError(.fileNoSuchFile) }
                }
            }
            if let cover = book.cover, cover.hasPrefix("local://Covers/") {
                if !allowMissingLocalFiles || paths.contains(String(cover.dropFirst(8))) {
                    guard paths.contains(String(cover.dropFirst(8))) else { throw CocoaError(.fileNoSuchFile) }
                }
            }
        }
    }

    static func chunk(_ file: SyncFilePayload, index: Int, root: URL = documents) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL(file.path, root: root))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(index * chunkSize))
        let bytes = try handle.read(upToCount: chunkSize) ?? Data()
        guard hash(bytes) == file.chunks[index], bytes.count == min(chunkSize, file.size - index * chunkSize) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return bytes
    }

    static func stage(_ bytes: Data, file: SyncFilePayload, index: Int, root: URL) throws {
        guard hash(bytes) == file.chunks[index], bytes.count == min(chunkSize, file.size - index * chunkSize) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let target = try fileURL(file.path, root: root)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if index == 0 { try Data().write(to: target, options: .atomic) }
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(index * chunkSize))
        try handle.write(contentsOf: bytes)
    }

    static func install(_ files: [SyncFilePayload], staging: URL, root: URL = documents) throws {
        let fm = FileManager.default
        for file in files {
            let target = try fileURL(file.path, root: root)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if file.size == 0 {
                try Data().write(to: target, options: .atomic)
            } else {
                let source = try fileURL(file.path, root: staging)
                guard try source.resourceValues(forKeys: [.fileSizeKey]).fileSize == file.size else { throw CocoaError(.fileReadCorruptFile) }
                if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: source) }
                else { try fm.moveItem(at: source, to: target) }
            }
        }
    }
}
