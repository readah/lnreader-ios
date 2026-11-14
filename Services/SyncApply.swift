// SyncApply.swift - the wire format and the "server copy wins" mapping.
//
// Split out of `SyncManager` so the mapping can be exercised headlessly
// (`./scripts/check.sh sync`). Everything here is pure: types plus one function
// that takes a decoded payload and a `ModelContext`. No networking, no
// `@Observable`, so a check can compile it against the schema alone.

import Foundation
import SwiftData

// MARK: - Wire format

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
    var progress: Int?
    var lastReadParagraphIndex: Int?
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

struct SyncPayload: Codable {
    var profile: SyncProfilePayload
    var library: [SyncNovelPayload]
    var sources: [SyncSourcePayload]
    /// The server timestamp this upload is based on.
    ///
    /// The backend compares it with its own `updatedAt` and answers 409 when its
    /// copy is newer, which is what makes the server authoritative instead of
    /// whichever device happened to push last. Omitted on a device that has
    /// never synced, which the backend treats as a legacy write.
    var clientUpdatedAt: String?
}

struct RemoteSyncData: Decodable {
    let profile: SyncProfilePayload
    let library: [SyncNovelPayload]
    let sources: [SyncSourcePayload]
    /// When the server last accepted a write. Absent on older backends.
    let updatedAt: String?
}

// MARK: - Timestamps

/// Every timestamp on the wire is ISO-8601 with milliseconds.
///
/// The chapter `releaseTime` used to be `Date.formatted`, which is a localized
/// human string ("10/29/2026, 8:45 PM"). `DateParsing` cannot read that back, so
/// every restore silently dropped the release date of every chapter. One format
/// for the whole payload keeps the round trip lossless.
enum SyncWire {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    /// Accepts the fractional form we write and the plain form other clients
    /// wrote, so a payload from an older build still restores.
    static func date(from value: String?) -> Date? {
        guard let value else { return nil }
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

// MARK: - Applying the server's copy

/// Writes a decoded `/api/sync` payload into the store.
///
/// The server wins wherever the two disagree: titles, metadata and reading
/// state are copied over, chapters are matched by `url` and created when they
/// are new. Two things are deliberately *not* copied:
///
/// - `isDownloaded` — whether a chapter can be read offline depends on files on
///   this device, not on another device's claim.
/// - `dateFetch` — it drives the Updates feed, which is about what *this* device
///   has seen since it last checked.
enum SyncApplier {

    /// The wire format carries genres as one comma-separated string.
    static func splitGenres(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func apply(_ data: RemoteSyncData, context: ModelContext) throws {
        let profiles = try context.fetch(FetchDescriptor<UserProfile>())
        let profile = profiles.first ?? UserProfile()
        if profiles.isEmpty {
            context.insert(profile)
        }
        if let name = data.profile.name, !name.isEmpty {
            profile.name = name
        }
        if let image = data.profile.image {
            profile.avatarData = Data(base64Encoded: image)
        }

        for remoteNovel in data.library {
            // The wire format still calls the source id `pluginId`; v2 stores the
            // prefixed source key.
            let sourceKey = SourceKey.makeBuiltin(id: remoteNovel.pluginId)
            let path = remoteNovel.path
            let predicate = #Predicate<Entry> { $0.url == path && $0.sourceKey == sourceKey }
            let existing = try context.fetch(FetchDescriptor(predicate: predicate)).first
            let novel = existing
                ?? Entry(kind: .novel, sourceKey: sourceKey, url: remoteNovel.path, title: remoteNovel.name)
            if existing == nil {
                context.insert(novel)
            }

            novel.title = remoteNovel.name
            novel.thumbnailURL = remoteNovel.cover
            novel.summary = remoteNovel.summary
            novel.author = remoteNovel.author
            novel.artist = remoteNovel.artist
            novel.status = EntryStatus.parse(remoteNovel.status)
            novel.genres = splitGenres(remoteNovel.genres)
            novel.inLibrary = remoteNovel.inLibrary
            novel.libraryOrder = remoteNovel.libraryPosition

            var existingChapters: [String: Chapter] = [:]
            for chapter in novel.chapters {
                existingChapters[chapter.url] = chapter
            }
            for remoteChapter in remoteNovel.chapters {
                let chapter = existingChapters[remoteChapter.path]
                    ?? Chapter(url: remoteChapter.path, name: remoteChapter.name)
                if chapter.entry == nil {
                    chapter.entry = novel
                    context.insert(chapter)
                }
                chapter.name = remoteChapter.name
                chapter.dateUpload = DateParsing.parse(remoteChapter.releaseTime)
                chapter.bookmark = remoteChapter.bookmark
                chapter.read = !remoteChapter.unread
                chapter.chapterNumber = remoteChapter.chapterNumber ?? -1
                chapter.sourceOrder = remoteChapter.position
                chapter.progress = Double(remoteChapter.progress ?? 0)
                chapter.paragraphIndex = remoteChapter.lastReadParagraphIndex
            }
        }

        try context.save()
        // A sync rewrites read state, so every badge it touched is now wrong and
        // an open chapter list has to redraw. Announced through the one event
        // that already means "stored chapters changed": this file compiles
        // without `LibraryManager`, so it cannot name the count cache directly.
        NotificationCenter.default.post(name: ChapterVisibility.didChange, object: nil)
        // Synced chapters and rules decide what exists.
        Task { await ChapterVisibility.reconcileAll(container: context.container) }
    }
}
