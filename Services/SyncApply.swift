import Foundation
import SwiftData

struct SyncProfilePayload: Codable {
    var username: String?
    var email: String?
    var name: String?
    var image: String?
}

struct SyncChapterPayload: Codable {
    var path: String
    var name: String
    var releaseTime: String?
    var bookmark: Bool
    var unread: Bool
    var isDownloaded: Bool
    var chapterNumber: Double?
    var page: String
    var position: Int
    var progress: Double?
    var lastReadParagraphIndex: Int?
    var lastPageRead: Int?
    var pagesLeft: Int?
    var lastRead: String?
    var timeRead: Double?
    var scanlator: String?
}

struct SyncNovelPayload: Codable {
    var path: String
    var pluginId: String
    var name: String
    var cover: String?
    var summary: String?
    var author: String?
    var artist: String?
    var status: String
    var genres: String?
    var inLibrary: Bool
    var totalPages: Int
    var libraryPosition: Int
    var chapters: [SyncChapterPayload]
    var sourceKey: String?
    var kind: ContentKind?
    var lastReadAt: String?
    var lastUpdate: String?
}

struct SyncSourcePayload: Codable {
    var id: String
    var name: String
    var site: String
    var lang: String
    var version: String
    var url: String
    var iconUrl: String
}

struct SyncFilePayload: Codable, Sendable {
    var path: String
    var size: Int
    var chunks: [String]
}

struct SyncHighlightPayload: Codable {
    var id: UUID
    var text: String
    var color: String
    var createdAt: Date
    var sourceKey: String
    var entryURL: String?
    var chapterURL: String
    var chapterName: String
    var chapterNumber: Double
    var sourceOrder: Int
    var paragraphIndex: Int
    var startOffset: Int
    var endOffset: Int
    var bookTitle: String
    var bookCoverURL: String?

    init(_ highlight: Highlight) {
        id = highlight.id
        text = highlight.text
        color = highlight.color
        createdAt = highlight.createdAt
        sourceKey = highlight.sourceKey
        entryURL = highlight.entryURL
        chapterURL = highlight.chapterURL
        chapterName = highlight.chapterName
        chapterNumber = highlight.chapterNumber
        sourceOrder = highlight.sourceOrder
        paragraphIndex = highlight.paragraphIndex
        startOffset = highlight.startOffset
        endOffset = highlight.endOffset
        bookTitle = highlight.bookTitle
        bookCoverURL = highlight.bookCoverURL
    }

    func makeModel() -> Highlight {
        let highlight = Highlight(text: text, color: color, sourceKey: sourceKey, entryURL: entryURL,
            chapterURL: chapterURL, chapterName: chapterName, chapterNumber: chapterNumber,
            sourceOrder: sourceOrder, paragraphIndex: paragraphIndex, startOffset: startOffset,
            endOffset: endOffset, bookTitle: bookTitle, bookCoverURL: bookCoverURL)
        highlight.id = id
        highlight.createdAt = createdAt
        return highlight
    }
}

struct SyncPayload: Codable {
    var profile: SyncProfilePayload
    var library: [SyncNovelPayload]
    var sources: [SyncSourcePayload]
    var clientUpdatedAt: String?
    var overwrite = true
    var localFiles: [SyncFilePayload] = []
    var highlights: [SyncHighlightPayload] = []
}

struct RemoteSyncData: Decodable {
    let profile: SyncProfilePayload
    let library: [SyncNovelPayload]
    let sources: [SyncSourcePayload]
    let updatedAt: String?
    var syncVersion: Int?
    var localFiles: [SyncFilePayload]?
    var highlights: [SyncHighlightPayload]?
}

enum SyncWire {
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(from value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

enum SyncApplier {
    static func splitGenres(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func validate(_ data: RemoteSyncData) throws {
        var identities = Set<String>()
        for book in data.library {
            let source = book.sourceKey ?? SourceKey.makeBuiltin(id: book.pluginId)
            guard identities.insert("\(source)\u{1F}\(book.path)").inserted,
                  Set(book.chapters.map(\.path)).count == book.chapters.count else { throw CocoaError(.fileReadCorruptFile) }
            for chapter in book.chapters {
                guard (chapter.progress ?? 0).isFinite, (0...100).contains(chapter.progress ?? 0),
                      (chapter.lastReadParagraphIndex ?? 0) >= 0, (chapter.lastPageRead ?? 0) >= 0,
                      (chapter.pagesLeft ?? 0) >= 0, (chapter.timeRead ?? 0) >= 0 else { throw CocoaError(.fileReadCorruptFile) }
            }
        }
        if let highlights = data.highlights {
            guard Set(highlights.map(\.id)).count == highlights.count,
                  highlights.allSatisfy({ $0.startOffset >= 0 && $0.endOffset >= $0.startOffset }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
    }

    static func apply(_ data: RemoteSyncData, context: ModelContext,
                      onProgress: ((Int, Int, String) -> Void)? = nil) throws {
        try validate(data)
        context.autosaveEnabled = false
        let profiles = try context.fetch(FetchDescriptor<UserProfile>())
        let profile = profiles.first ?? UserProfile()
        if profiles.isEmpty { context.insert(profile) }
        if let name = data.profile.name, !name.isEmpty { profile.name = name }
        profile.avatarData = data.profile.image.flatMap { Data(base64Encoded: $0) }

        for (index, remoteNovel) in data.library.enumerated() {
            let sourceKey = remoteNovel.sourceKey ?? (remoteNovel.pluginId == SourceKey.local
                ? SourceKey.local : SourceKey.makeBuiltin(id: remoteNovel.pluginId))
            let path = remoteNovel.path
            let predicate = #Predicate<Entry> { $0.url == path && $0.sourceKey == sourceKey }
            let existing = try context.fetch(FetchDescriptor(predicate: predicate)).first
            let novel = existing ?? Entry(kind: remoteNovel.kind ?? .novel, sourceKey: sourceKey, url: path, title: remoteNovel.name)
            if existing == nil { context.insert(novel) }
            novel.kind = remoteNovel.kind ?? novel.kind
            novel.title = remoteNovel.name
            novel.thumbnailURL = remoteNovel.cover
            novel.summary = remoteNovel.summary
            novel.author = remoteNovel.author
            novel.artist = remoteNovel.artist
            novel.status = EntryStatus.parse(remoteNovel.status)
            novel.genres = splitGenres(remoteNovel.genres)
            novel.inLibrary = remoteNovel.inLibrary
            novel.libraryOrder = remoteNovel.libraryPosition
            novel.lastReadAt = SyncWire.date(from: remoteNovel.lastReadAt)
            novel.lastUpdate = SyncWire.date(from: remoteNovel.lastUpdate)

            var existingChapters: [String: Chapter] = [:]
            for chapter in novel.chapters { existingChapters[chapter.url] = chapter }
            for remoteChapter in remoteNovel.chapters {
                let chapter = existingChapters[remoteChapter.path] ?? Chapter(url: remoteChapter.path, name: remoteChapter.name)
                if chapter.entry == nil {
                    context.insert(chapter)
                    chapter.entry = novel
                }
                chapter.name = remoteChapter.name
                chapter.dateUpload = DateParsing.parse(remoteChapter.releaseTime)
                chapter.bookmark = remoteChapter.bookmark
                chapter.read = !remoteChapter.unread
                chapter.chapterNumber = remoteChapter.chapterNumber ?? -1
                chapter.sourceOrder = remoteChapter.position
                chapter.progress = remoteChapter.progress ?? 0
                chapter.paragraphIndex = remoteChapter.lastReadParagraphIndex
                chapter.lastPageRead = remoteChapter.lastPageRead ?? 0
                chapter.pagesLeft = remoteChapter.pagesLeft ?? 0
                chapter.scanlator = remoteChapter.scanlator
                if let date = SyncWire.date(from: remoteChapter.lastRead) {
                    let history = chapter.history ?? History(chapterURL: "\(sourceKey)\u{1F}\(path)\u{1F}\(chapter.url)", lastRead: date)
                    if chapter.history == nil {
                        context.insert(history)
                        history.chapter = chapter
                        chapter.history = history
                    }
                    history.lastRead = date
                    history.timeRead = remoteChapter.timeRead ?? 0
                } else if data.syncVersion == 2, let history = chapter.history {
                    chapter.history = nil
                    context.delete(history)
                }
            }
            onProgress?(index + 1, data.library.count, novel.title)
        }

        if let highlights = data.highlights {
            for highlight in try context.fetch(FetchDescriptor<Highlight>()) { context.delete(highlight) }
            for highlight in highlights { context.insert(highlight.makeModel()) }
        }
        try context.save()
    }
}

extension SyncNovelPayload {
    init(entry: Entry) {
        path = entry.url
        pluginId = SourceKey.identifier(from: entry.sourceKey)
        name = entry.title
        cover = entry.thumbnailURL
        summary = entry.summary
        author = entry.author
        artist = entry.artist
        status = entry.status.displayName
        genres = entry.genres.isEmpty ? nil : entry.genres.joined(separator: ", ")
        inLibrary = entry.inLibrary
        totalPages = 0
        libraryPosition = entry.libraryOrder
        chapters = ChapterOrder.oldestFirst(entry.visibleChapters).map { SyncChapterPayload(chapter: $0) }
        sourceKey = entry.sourceKey
        kind = entry.kind
        lastReadAt = entry.lastReadAt.map(SyncWire.string(from:))
        lastUpdate = entry.lastUpdate.map(SyncWire.string(from:))
    }
}

extension SyncChapterPayload {
    init(chapter: Chapter) {
        path = chapter.url
        name = chapter.name
        releaseTime = chapter.dateUpload.map(SyncWire.string(from:))
        bookmark = chapter.bookmark
        unread = !chapter.read
        isDownloaded = false
        chapterNumber = chapter.chapterNumber >= 0 ? chapter.chapterNumber : nil
        page = String(chapter.lastPageRead)
        position = chapter.sourceOrder
        progress = chapter.progress
        lastReadParagraphIndex = chapter.paragraphIndex
        lastPageRead = chapter.lastPageRead
        pagesLeft = chapter.pagesLeft
        lastRead = (chapter.history?.lastRead).map(SyncWire.string(from:))
        timeRead = chapter.history?.timeRead
        scanlator = chapter.scanlator
    }
}
