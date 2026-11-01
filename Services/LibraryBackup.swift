import CryptoKit
import Foundation
import Security
import SwiftData

/// Version 2 is an authenticated local snapshot. It is deliberately distinct from
/// the planned version-1 Argon2/protobuf envelope; it never accepts .tachibk files.
enum LibraryBackup {
    struct Snapshot: Codable {
        var version = 2
        let createdAt: Date
        let entries: [Book]
        let categories: [Group]
        let preferences: Data
        let localFiles: [String: Data]
        let profiles: [Profile]
    }
    struct Profile: Codable { let name: String; let avatar: Data? }
    struct Group: Codable { let name: String; let order: Int; let flags: Int }
    struct Book: Codable {
        let sourceKey: String; let url: String; let kind: ContentKind
        let title: String; let author: String?; let artist: String?; let summary: String?
        let genres: [String]; let status: EntryStatus; let thumbnail: String?
        let inLibrary: Bool; let dateAdded: Date; let lastUpdate: Date?; let lastReadAt: Date?
        let order: Int; let viewerFlags: Int; let strategy: UpdateStrategy; let memo: String
        let customTitle: String?; let customAuthor: String?; let customArtist: String?
        let customDescription: String?; let customThumbnail: String?
        let categories: [String]; let chapters: [Part]; let tracks: [Tracking]
    }
    struct Part: Codable {
        let url: String; let name: String; let number: Double; let order: Int; let scanlator: String?
        let uploaded: Date?; let fetched: Date?; let read: Bool; let bookmark: Bool
        let progress: Double; let page: Int; let pagesLeft: Int; let paragraph: Int?; let memo: String
        let lastRead: Date?; let timeRead: TimeInterval?
    }
    struct Tracking: Codable {
        let syncId: Int; let remoteId: Int64; let libraryId: Int64?; let title: String
        let lastChapter: Double; let total: Int; let status: Int; let score: Double
        let url: String; let start: Date?; let finish: Date?
    }
    /// Version 2 sealed raw JSON. Version 3 deflates the JSON first (encrypted bytes do not compress).
    static let legacyHeader = Data([0x4c, 0x4e, 0x52, 0x42, 2])
    static let header = Data([0x4c, 0x4e, 0x52, 0x42, 3])
    static let limit = 256 * 1024 * 1024
    static let prefixes = ["reader.", "manga.", "general.", "browse.", "downloads.", "scanlators."]
    static func key() throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.lnreader.backup.v2", kSecAttrAccount as String: "recovery"]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { _, new in new } as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return data.base64EncodedString() }
        guard status == errSecItemNotFound else { throw CocoaError(.fileReadNoPermission) }
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let add = query.merging([kSecValueData as String: bytes,
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { _, new in new }
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw CocoaError(.fileWriteNoPermission) }
        return bytes.base64EncodedString()
    }
    static func seal(_ plaintext: Data, recoveryKey: String) throws -> Data {
        guard let bytes = Data(base64Encoded: recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines)), bytes.count == 32,
              plaintext.count <= limit else { throw CocoaError(.fileReadCorruptFile) }
        let packed = try (plaintext as NSData).compressed(using: .zlib) as Data
        let sealed = try AES.GCM.seal(packed, using: SymmetricKey(data: bytes), authenticating: header)
        guard let combined = sealed.combined else { throw CocoaError(.fileWriteUnknown) }
        return header + combined
    }
    static func open(_ encrypted: Data, recoveryKey: String) throws -> Snapshot {
        let compressed = encrypted.starts(with: header)
        guard encrypted.count <= limit + 64, compressed || encrypted.starts(with: legacyHeader),
              let key = Data(base64Encoded: recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines)), key.count == 32 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let used = compressed ? header : legacyHeader
        let box = try AES.GCM.SealedBox(combined: encrypted.dropFirst(used.count))
        var plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: used)
        if compressed { plaintext = try (plaintext as NSData).decompressed(using: .zlib) as Data }
        guard plaintext.count <= limit else { throw CocoaError(.fileReadTooLarge) }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: plaintext)
        guard snapshot.version == 2 else { throw CocoaError(.fileReadCorruptFile) }
        try validate(snapshot)
        return snapshot
    }
    static func validate(_ snapshot: Snapshot) throws {
        guard (try PropertyListSerialization.propertyList(from: snapshot.preferences, format: nil)) is [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard snapshot.entries.count <= 100_000, snapshot.localFiles.values.reduce(0, { $0 + $1.count }) <= limit else {
            throw CocoaError(.fileReadTooLarge)
        }
        // Validate every relative local-book path before any restore mutation.
        for path in snapshot.localFiles.keys {
            let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"), !path.contains("\\"), pieces.count > 1,
                  pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw CocoaError(.fileReadInvalidFileName) }
        }
        guard Set(snapshot.entries.map { "\($0.sourceKey.utf8.count):\($0.sourceKey)\($0.url)" }).count == snapshot.entries.count,
              Set(snapshot.categories.map(\.name)).count == snapshot.categories.count else { throw CocoaError(.fileReadCorruptFile) }
        for entry in snapshot.entries {
            guard Set(entry.chapters.map(\.url)).count == entry.chapters.count,
                  entry.chapters.allSatisfy({ $0.progress.isFinite && $0.progress >= 0 && $0.progress <= 100 && $0.page >= 0 }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
    }
    @MainActor static func snapshot(context: ModelContext) throws -> Snapshot {
        let entries = try context.fetch(FetchDescriptor<Entry>())
        let groups = try context.fetch(FetchDescriptor<Category>())
        let prefs = UserDefaults.standard.dictionaryRepresentation().filter { key, _ in prefixes.contains { key.hasPrefix($0) } }
        let preferences = try PropertyListSerialization.data(fromPropertyList: prefs, format: .binary, options: 0)
        var files: [String: Data] = [:]
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalNovels")
        var total = 0
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            for case let file as URL in enumerator {
                let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard properties.isRegularFile == true, properties.isSymbolicLink != true else { continue }
                guard (properties.fileSize ?? 0) < limit / 2 - total else { throw CocoaError(.fileReadTooLarge) }
                let data = try Data(contentsOf: file); total += data.count
                guard total < limit / 2 else { throw CocoaError(.fileReadTooLarge) }
                files[String(file.path.dropFirst(root.path.count + 1))] = data
            }
        }
        return Snapshot(createdAt: .now, entries: entries.map { e in
            Book(sourceKey: e.sourceKey, url: e.url, kind: e.kind, title: e.title, author: e.author, artist: e.artist,
                summary: e.summary, genres: e.genres, status: e.status, thumbnail: e.thumbnailURL, inLibrary: e.inLibrary,
                dateAdded: e.dateAdded, lastUpdate: e.lastUpdate, lastReadAt: e.lastReadAt, order: e.libraryOrder,
                viewerFlags: e.viewerFlags, strategy: e.updateStrategy, memo: e.memo, customTitle: e.customTitle,
                customAuthor: e.customAuthor, customArtist: e.customArtist, customDescription: e.customDescription,
                customThumbnail: e.customThumbnailURL, categories: e.categories.map(\.name), chapters: e.chapters.map { c in
                    Part(url: c.url, name: c.name, number: c.chapterNumber, order: c.sourceOrder, scanlator: c.scanlator,
                        uploaded: c.dateUpload, fetched: c.dateFetch, read: c.read, bookmark: c.bookmark, progress: c.progress,
                        page: c.lastPageRead, pagesLeft: c.pagesLeft, paragraph: c.paragraphIndex, memo: c.memo,
                        lastRead: c.history?.lastRead, timeRead: c.history?.timeRead)
                }, tracks: e.tracks.map { t in
                    Tracking(syncId: t.syncId, remoteId: t.remoteId, libraryId: t.libraryId, title: t.title,
                        lastChapter: t.lastChapterRead, total: t.totalChapters, status: t.status, score: t.score,
                        url: t.remoteURL, start: t.startDate, finish: t.finishDate)
                })
        }, categories: groups.map { Group(name: $0.name, order: $0.order, flags: $0.flags) }, preferences: preferences,
            localFiles: files, profiles: try context.fetch(FetchDescriptor<UserProfile>()).map { Profile(name: $0.name, avatar: $0.avatarData) })
    }
    @MainActor static func restore(_ snapshot: Snapshot, container: ModelContainer) throws -> Int {
        try validate(snapshot)
        let context = ModelContext(container)
        var categories = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Category>()).map { ($0.name, $0) })
        for group in snapshot.categories where categories[group.name] == nil {
            let category = Category(name: group.name, order: group.order, flags: group.flags)
            context.insert(category); categories[group.name] = category
        }
        let existing = try context.fetch(FetchDescriptor<Entry>())
        for book in snapshot.entries {
            let found = existing.first { $0.sourceKey == book.sourceKey && $0.url == book.url }
            let entry = found ?? Entry(kind: book.kind, sourceKey: book.sourceKey, url: book.url, title: book.title)
            if found == nil {
                context.insert(entry); entry.author = book.author; entry.artist = book.artist; entry.summary = book.summary
                entry.genres = book.genres; entry.status = book.status; entry.thumbnailURL = book.thumbnail
                entry.dateAdded = book.dateAdded; entry.lastUpdate = book.lastUpdate; entry.libraryOrder = book.order
                entry.viewerFlags = book.viewerFlags; entry.updateStrategy = book.strategy; entry.memo = book.memo
                entry.customTitle = book.customTitle; entry.customAuthor = book.customAuthor; entry.customArtist = book.customArtist
                entry.customDescription = book.customDescription; entry.customThumbnailURL = book.customThumbnail
            }
            entry.inLibrary = entry.inLibrary || book.inLibrary
            if let date = book.lastReadAt { entry.lastReadAt = max(entry.lastReadAt ?? .distantPast, date) }
            for name in book.categories where !entry.categories.contains(where: { $0.name == name }) {
                if let category = categories[name] { entry.categories.append(category) }
            }
            let saved = Dictionary(uniqueKeysWithValues: entry.chapters.map { ($0.url, $0) })
            for part in book.chapters {
                let chapter = saved[part.url] ?? Chapter(url: part.url, name: part.name, chapterNumber: part.number, sourceOrder: part.order)
                if saved[part.url] == nil {
                    context.insert(chapter); chapter.entry = entry; chapter.scanlator = part.scanlator
                    chapter.dateUpload = part.uploaded; chapter.dateFetch = part.fetched; chapter.memo = part.memo
                }
                chapter.read = chapter.read || part.read; chapter.bookmark = chapter.bookmark || part.bookmark
                if part.progress > chapter.progress {
                    chapter.progress = part.progress; chapter.paragraphIndex = part.paragraph
                }
                if part.page > chapter.lastPageRead { chapter.lastPageRead = part.page; chapter.pagesLeft = part.pagesLeft }
                if let date = part.lastRead {
                    if chapter.history == nil {
                        let history = History(chapterURL: part.url, lastRead: date)
                        context.insert(history); history.chapter = chapter; chapter.history = history
                    }
                    chapter.history?.lastRead = max(chapter.history?.lastRead ?? .distantPast, date)
                    chapter.history?.timeRead = max(chapter.history?.timeRead ?? 0, part.timeRead ?? 0)
                }
            }
            for track in book.tracks {
                if let old = entry.tracks.first(where: { $0.syncId == track.syncId }) {
                    old.lastChapterRead = max(old.lastChapterRead, track.lastChapter)
                } else {
                    let t = Track(syncId: track.syncId, remoteId: track.remoteId, title: track.title)
                    context.insert(t); t.entry = entry; t.libraryId = track.libraryId; t.lastChapterRead = track.lastChapter
                    t.totalChapters = track.total; t.status = track.status; t.score = track.score; t.remoteURL = track.url
                    t.startDate = track.start; t.finishDate = track.finish
                }
            }
        }
        if try context.fetch(FetchDescriptor<UserProfile>()).isEmpty, let profile = snapshot.profiles.first {
            context.insert(UserProfile(name: profile.name, avatarData: profile.avatar))
        }
        // Existing local files win. Do not overwrite books already imported on this device.
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalNovels")
        for (path, data) in snapshot.localFiles {
            let target = root.appendingPathComponent(path)
            let resolved = target.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw CocoaError(.fileWriteNoPermission) }
            if !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            }
        }
        try context.save()
        if let prefs = try PropertyListSerialization.propertyList(from: snapshot.preferences, format: nil) as? [String: Any] {
            for (key, value) in prefs where prefixes.contains(where: { key.hasPrefix($0) }) {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        // Restored chapters and restored scanlator rules decide what exists.
        Task { await ChapterVisibility.reconcileAll(container: container) }
        return snapshot.entries.count
    }
}
