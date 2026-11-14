// EntryMigrationApply.swift - The app-facing half of migrating: builds the new entry
// through `LibraryManager` and retires the old one. The matching and the progress
// carry live in EntryMigration.swift so they can be checked headlessly.

import Foundation
import SwiftData

extension EntryMigrator {

    /// Replace `old` with `target` from another source.
    ///
    /// Nothing about `old` changes until the new entry has its chapters, and
    /// there is one `save()` at the end.
    @discardableResult
    static func migrate(
        _ old: Entry,
        to target: SourceEntry,
        chapters: [SourceChapter],
        options: MigrationOptions = MigrationOptions(),
        context: ModelContext,
        libraryManager: LibraryManager
    ) -> (entry: Entry, outcome: MigrationOutcome) {
        let new = libraryManager.addToLibrary(entry: target, chapters: chapters, context: context)
        guard new !== old else { return (new, MigrationOutcome()) }

        var outcome = MigrationOutcome()
        if options.carryProgress {
            outcome = carryProgress(from: old, to: new, context: context)
        }

        new.dateAdded = old.dateAdded
        new.lastReadAt = old.lastReadAt ?? new.lastReadAt
        new.viewerFlags = old.viewerFlags
        new.updateStrategy = old.updateStrategy
        new.customTitle = old.customTitle
        new.customAuthor = old.customAuthor
        new.customArtist = old.customArtist
        new.customDescription = old.customDescription
        new.customThumbnailURL = old.customThumbnailURL

        if options.carryCategories {
            new.categories = old.categories
            old.categories = []
        }
        if options.carryTracking {
            for track in old.tracks { track.entry = new }
            for pending in old.pendingTrackUpdates { pending.entry = new }
        }
        copyReaderOverrides(from: old, to: new)

        old.inLibrary = false
        if options.deleteOldDownloads { ChapterDownloadManager.shared.deleteDownloads(in: old) }
        try? context.save()
        LibraryChapterCounts.shared.invalidate()
        return (new, outcome)
    }
}
