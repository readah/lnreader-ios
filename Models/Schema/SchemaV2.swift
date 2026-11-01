// SchemaV2.swift - The app's current SwiftData schema.
//
// V1 plus `Chapter.hidden`. `SchemaV1.swift` is frozen so the migration knows what
// the old store looked like; views use the typealiases at the bottom of this file.

import Foundation
import SwiftData

/// Version 2 of the schema: adds `Chapter.hidden`.
enum SchemaV2: VersionedSchema {

    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            Entry.self,
            Chapter.self,
            History.self,
            Category.self,
            Track.self,
            ExtensionRepo.self,
            DownloadItem.self,
            PendingTrackUpdate.self,
            // Account profile. Lives outside the namespace and has no schema of
            // its own, but it shares the store.
            UserProfile.self,
        ]
    }

    // MARK: - Entry

    /// Anything the user can read: a novel or a manga.
    ///
    /// One model for both kinds keeps the library, categories, history,
    /// downloads and tracking tables shared. Kind-specific columns (viewer
    /// flags, page counters) are simply unused by the other kind.
    @Model
    final class Entry {

        #Unique<Entry>([\.sourceKey, \.url])

        /// Which reader opens this entry.
        var kind: ContentKind = ContentKind.novel

        /// `"ln:<pluginId>"` for LN JS plugins, `"mihon:<extensionId>"` for
        /// transpiled Mihon extensions. Part of the backup format.
        var sourceKey: String = ""

        /// Source-relative identifier: a plugin path for LN sources, a
        /// relative URL for Mihon sources. Not necessarily an absolute URL.
        var url: String = ""

        var title: String = ""
        var author: String?
        var artist: String?
        var summary: String?
        var genres: [String] = []
        var status: EntryStatus = EntryStatus.unknown
        var thumbnailURL: String?

        // MARK: Library state

        var inLibrary: Bool = false
        var dateAdded: Date = Date.now
        /// When this entry was last refreshed from its source (set on every
        /// successful update, whether or not new chapters arrived).
        var lastUpdate: Date?
        /// Manual drag-and-drop position inside the library.
        var libraryOrder: Int = 0

        /// Cached `max(History.lastRead)` for this entry.
        ///
        /// Denormalized on purpose: the library sorts by "recently read" and a
        /// predicate cannot walk chapters → history. The reader keeps it in
        /// sync; `History` stays the source of truth for the History screen.
        var lastReadAt: Date?

        // MARK: Kind-specific / source-specific

        /// Yokai's packed viewer flags (reading mode + orientation), manga only.
        var viewerFlags: Int = 0
        var updateStrategy: UpdateStrategy = UpdateStrategy.always

        /// Opaque per-source scratch space. Yokai calls it `memo` and expects
        /// JSON; kept as a string so a backup round-trip is lossless.
        var memo: String = "{}"

        // MARK: User overrides

        var customTitle: String?
        var customAuthor: String?
        var customArtist: String?
        var customDescription: String?
        var customThumbnailURL: String?

        // MARK: Relationships

        @Relationship(deleteRule: .cascade, inverse: \Chapter.entry)
        var chapters: [Chapter] = []

        /// Many-to-many with `Category`. The inverse is declared on the
        /// `Category` side only: declaring it on both sides makes the
        /// `@Relationship` macro recurse forever.
        var categories: [Category] = []

        @Relationship(deleteRule: .cascade, inverse: \Track.entry)
        var tracks: [Track] = []

        @Relationship(deleteRule: .cascade, inverse: \PendingTrackUpdate.entry)
        var pendingTrackUpdates: [PendingTrackUpdate] = []

        init(
            kind: ContentKind,
            sourceKey: String,
            url: String,
            title: String
        ) {
            self.kind = kind
            self.sourceKey = sourceKey
            self.url = url
            self.title = title
        }

        // MARK: Display values (overrides win)

        /// Some sources put the whole anchor tag in the author field, so the
        /// library used to show `Editor:+CKtalon/" class="a1" title="…`. Cut it
        /// back to the name. Display only: the stored value is left alone.
        private static func cleanAuthor(_ raw: String?) -> String? {
            guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            if let range = text.range(of: "title=\"") {
                text = String(text[range.upperBound...])
            }
            if let quote = text.firstIndex(of: "\"") {
                text = String(text[..<quote])
            }
            if let tag = text.firstIndex(of: "<") {
                text = String(text[..<tag])
            }
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }

        var displayTitle: String { customTitle ?? title }
        var displayAuthor: String? { Self.cleanAuthor(customAuthor ?? author) }
        var displayArtist: String? { customArtist ?? artist }
        var displaySummary: String? { customDescription ?? summary }
        var displayThumbnailURL: String? { customThumbnailURL ?? thumbnailURL }

        // MARK: Derived state

        /// Local books live in `Documents/LocalNovels` and are read from disk
        /// instead of a source. They use the reserved `"local"` source key.
        var isLocal: Bool { sourceKey == SourceKey.local }

        /// Chapters that exist for the user: everything not `hidden`. Every
        /// in-memory walk of `chapters` that is not about storage starts here.
        var visibleChapters: [Chapter] { chapters.filter { !$0.hidden } }

        /// Chapters the user has not read yet, newest-first ordering assumed.
        var unreadCount: Int { chapters.count { !$0.hidden && !$0.read } }

        var totalChapterCount: Int { chapters.count { !$0.hidden } }

        var hasUnread: Bool { chapters.contains { !$0.hidden && !$0.read } }

        /// Highest-numbered chapter, used by "Continue reading" and Updates.
        var latestChapter: Chapter? {
            chapters.filter { !$0.hidden }.max { lhs, rhs in
                if lhs.chapterNumber != rhs.chapterNumber {
                    return lhs.chapterNumber < rhs.chapterNumber
                }
                return lhs.sourceOrder < rhs.sourceOrder
            }
        }
    }

    // MARK: - Chapter

    /// One chapter of an entry. Same model for novels and manga.
    @Model
    final class Chapter {

        #Unique<Chapter>([\.entry, \.url])
        #Index<Chapter>([\.entry, \.read], [\.entry, \.sourceOrder], [\.entry, \.hidden, \.read])

        var url: String = ""
        var name: String = ""
        var scanlator: String?

        /// Parsed chapter number; `-1` when the source gives nothing usable.
        var chapterNumber: Double = -1

        /// Index in the source's own chapter list.
        var sourceOrder: Int = 0

        /// Date the chapter was released, as reported by the source.
        var dateUpload: Date?
        /// Date we first saw the chapter. Newer fetch wins, so it orders Updates.
        var dateFetch: Date?

        var read: Bool = false
        var bookmark: Bool = false

        /// The chapter does not exist as far as the user is concerned: its
        /// scanlator is hidden, or priority merging kept another scanlator's
        /// copy of the same number.
        ///
        /// A cached decision, not a setting. `ChapterVisibility` is the only
        /// writer and recomputes it from the entry's scanlator rules, so counts,
        /// Updates, statistics, downloads and the readers all ask the same
        /// question (`!hidden`) in SQL instead of re-deriving it each their own
        /// way.
        var hidden: Bool = false

        /// 0–100, kind-agnostic. Novels derive it from paragraphs, manga from pages.
        var progress: Double = 0

        /// Manga: last page the user was on (0-based).
        var lastPageRead: Int = 0
        /// Manga: pages remaining, used for the "3 pages left" hint.
        var pagesLeft: Int = 0
        /// Novels: last paragraph the user was on.
        var paragraphIndex: Int?

        var memo: String = "{}"

        var entry: Entry?

        /// One history row per chapter, deleted with it.
        @Relationship(deleteRule: .cascade, inverse: \History.chapter)
        var history: History?

        /// Queue row for this chapter, deleted with it. Declared here, not on
        /// `DownloadItem`: a cascade rule on `DownloadItem.chapter` would mean
        /// "deleting a queue row deletes the chapter", which is backwards.
        @Relationship(deleteRule: .cascade, inverse: \DownloadItem.chapter)
        var downloadItem: DownloadItem?

        init(
            url: String,
            name: String,
            chapterNumber: Double = -1,
            sourceOrder: Int = 0
        ) {
            self.url = url
            self.name = name
            self.chapterNumber = chapterNumber
            self.sourceOrder = sourceOrder
        }

        /// Chapter is finished once progress reaches the threshold, or when the
        /// reader explicitly marks it read.
        static let finishedThreshold: Double = 95

        var isInProgress: Bool { !read && progress > 0 }

        /// Whether the chapter can be opened without a network call.
        ///
        /// Local books keep their chapters on disk by definition; everything
        /// else is offline only once its download finished.
        var isDownloaded: Bool {
            if entry?.isLocal == true { return true }
            return downloadItem?.state == .completed
        }
    }

    // MARK: - History

    /// Reading history.
    ///
    /// `chapterURL` carries the unique constraint because SwiftData does not
    /// support uniqueness across a relationship; the relationship is still the
    /// thing the History view traverses.
    @Model
    final class History {

        #Unique<History>([\.chapterURL])

        var chapterURL: String = ""
        var lastRead: Date = Date.now
        /// Seconds spent reading, accumulated by the reader.
        var timeRead: TimeInterval = 0

        @Relationship(deleteRule: .nullify)
        var chapter: Chapter?

        init(chapterURL: String, lastRead: Date = .now) {
            self.chapterURL = chapterURL
            self.lastRead = lastRead
        }
    }

    // MARK: - Category

    /// User-defined library category, shared by both kinds.
    @Model
    final class Category {

        #Unique<Category>([\.name])

        var name: String = ""
        var order: Int = 0
        /// Bit flags; see `CategoryFlags` (bit 0: excluded from library updates).
        var flags: Int = 0

        @Relationship(inverse: \Entry.categories)
        var entries: [Entry] = []

        init(name: String, order: Int = 0, flags: Int = 0) {
            self.name = name
            self.order = order
            self.flags = flags
        }
    }

    // MARK: - Track

    /// A tracker binding for one entry (AniList today, more later).
    @Model
    final class Track {

        #Index<Track>([\.entry, \.syncId])

        /// Yokai tracker id: MAL=1, AniList=2, Kitsu=3, … Kept for backup compat.
        var syncId: Int = 0
        var remoteId: Int64 = 0
        var libraryId: Int64?

        var title: String = ""
        var lastChapterRead: Double = 0
        var totalChapters: Int = 0
        var status: Int = 0
        var score: Double = 0
        var remoteURL: String = ""
        var startDate: Date?
        var finishDate: Date?
        /// Hidden from the user's public AniList profile and activity feed.
        var isPrivate: Bool = false

        var entry: Entry?

        init(syncId: Int, remoteId: Int64, title: String) {
            self.syncId = syncId
            self.remoteId = remoteId
            self.title = title
        }
    }

    // MARK: - ExtensionRepo

    /// A repository of sources: LN plugin repos and Mihon extension repos.
    @Model
    final class ExtensionRepo {

        #Unique<ExtensionRepo>([\.baseURL])

        var baseURL: String = ""
        var name: String = ""
        var shortName: String?
        var website: String?
        /// SHA-256 of the repo's signing key, pinned on first install.
        var signingKeyFingerprint: String?
        /// Which kind of sources this repo serves.
        var kind: ContentKind = ContentKind.novel
        var lastFetched: Date?

        init(baseURL: String, name: String, kind: ContentKind) {
            self.baseURL = baseURL
            self.name = name
            self.kind = kind
        }
    }

    // MARK: - DownloadItem

    /// One row of the persisted download queue.
    @Model
    final class DownloadItem {

        #Index<DownloadItem>([\.state, \.order])

        /// Queue position; lower runs first.
        var order: Int = 0
        var state: DownloadState = DownloadState.queued
        /// 0–1 within the chapter, for the progress ring.
        var progress: Double = 0
        var error: String?
        var createdAt: Date = Date.now

        /// The chapter being downloaded. Its `downloadItem` relationship owns
        /// the cascade, so removing this row never removes the chapter.
        var chapter: Chapter?

        init(chapter: Chapter?, order: Int = 0) {
            self.chapter = chapter
            self.order = order
        }
    }

    // MARK: - PendingTrackUpdate

    /// Tracker update queued while offline, flushed when the network returns.
    @Model
    final class PendingTrackUpdate {

        var syncId: Int = 0
        var chapterNumber: Double = 0
        var createdAt: Date = Date.now

        var entry: Entry?

        init(syncId: Int, chapterNumber: Double) {
            self.syncId = syncId
            self.chapterNumber = chapterNumber
        }
    }
}

// MARK: - Type aliases

/// Short handles so views read naturally (`Entry`, `Chapter`, …).
typealias Entry = SchemaV2.Entry
typealias Chapter = SchemaV2.Chapter
typealias History = SchemaV2.History
typealias Category = SchemaV2.Category
typealias Track = SchemaV2.Track
typealias ExtensionRepo = SchemaV2.ExtensionRepo
typealias DownloadItem = SchemaV2.DownloadItem
typealias PendingTrackUpdate = SchemaV2.PendingTrackUpdate
