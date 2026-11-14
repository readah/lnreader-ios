// ChapterVisibility.swift - The one place that decides which chapters exist.
//
// A hidden scanlator's chapters, and the losing copies when priority merging is
// on, are not part of the user's chapter set. Rather than have every screen
// re-run `ScanlatorRules` over a relationship, the decision is written once to
// `Chapter.hidden` and everything else asks `!hidden` (in SQL where it counts).
//
// `ScanlatorRules` stays the only rule. This file only applies it to stored
// rows, and `ChapterTwins` (read state shared between scanlators) keeps a
// duplicate of a read chapter from showing up as new.
//
// When to call it: after a merge (`ChapterSourceSync.merge` does), after the
// scanlator rules change (`ScanlatorSettings` does), and after a restore that
// brings rules or chapters back (`LibraryMaintenance.reconcileVisibility`).

import Foundation
import SwiftData

enum ChapterVisibility {

    /// Posted on the main thread after the stored chapter set changed, so an
    /// open chapter list or reader can reload what it shows, and the library
    /// counts (`LibraryChapterCounts`) drop what they cached.
    ///
    /// "Changed" includes a restore, which replaces every chapter without
    /// necessarily flipping a `hidden` flag.
    static let didChange = Notification.Name("LNReaderChapterVisibilityChanged")

    /// The entry's saved scanlator rules. They live in UserDefaults, keyed
    /// `sourceKey::url`.
    static func preference(for entry: Entry, defaults: UserDefaults = .standard) -> ScanlatorPreference {
        ScanlatorPreference.load(key: "\(entry.sourceKey)::\(entry.url)", defaults: defaults)
    }

    /// Recompute `hidden` for every chapter of `entry`. Returns how many changed.
    ///
    /// Pure over the entry's chapters, so it works on any context. An entry with
    /// no rules costs one pass that finds nothing to change.
    @discardableResult
    static func reconcile(_ entry: Entry, preference: ScanlatorPreference? = nil) -> Int {
        let preference = preference ?? self.preference(for: entry)
        // Same order the chapter list is built in, so a tie between two
        // scanlators of equal rank resolves the same way everywhere.
        let chapters = ChapterOrder.oldestFirst(entry.chapters)
        var visible = Set(chapters.indices)
        if preference.hasActiveRules {
            let items = chapters.map {
                ScanlatorRules.Item(number: $0.chapterNumber > 0 ? $0.chapterNumber : nil, scanlator: $0.scanlator)
            }
            visible = Set(ScanlatorRules.keptIndices(for: items, preference: preference))
        }
        var changed = 0
        for (index, chapter) in chapters.enumerated() {
            let hidden = !visible.contains(index)
            if chapter.hidden != hidden {
                chapter.hidden = hidden
                changed += 1
            }
        }
        return changed
    }

    /// Re-apply the rules to one entry on a background context, then announce it. For when the rules change and no entry is in hand.
    static func refresh(key: String, container: ModelContainer) {
        guard let split = key.range(of: "::") else { return }
        let sourceKey = String(key[..<split.lowerBound])
        let url = String(key[split.upperBound...])
        Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let predicate = #Predicate<Entry> { $0.sourceKey == sourceKey && $0.url == url }
            guard let entry = try? context.fetch(FetchDescriptor<Entry>(predicate: predicate)).first else { return }
            guard reconcile(entry) > 0 else { return }
            try? context.save()
            await MainActor.run { NotificationCenter.default.post(name: didChange, object: nil) }
        }
    }

    /// Re-apply the rules to every entry that has any, off the main thread.
    /// Returns how many chapters changed.
    @discardableResult
    static func reconcileAll(container: ModelContainer, defaults: UserDefaults = .standard) async -> Int {
        let changed = await Task.detached(priority: .utility) { () -> Int in
            let context = ModelContext(container)
            guard let entries = try? context.fetch(FetchDescriptor<Entry>()) else { return 0 }
            var changed = 0
            for entry in entries {
                // Skip entries that have never had a rule and have nothing hidden:
                // nearly every entry, and the pass would find nothing.
                let rules = preference(for: entry, defaults: defaults)
                if !rules.hasActiveRules && !entry.chapters.contains(where: \.hidden) { continue }
                changed += reconcile(entry, preference: rules)
            }
            if changed > 0 { try? context.save() }
            return changed
        }.value
        if changed > 0 { await MainActor.run { NotificationCenter.default.post(name: didChange, object: nil) } }
        return changed
    }
}
