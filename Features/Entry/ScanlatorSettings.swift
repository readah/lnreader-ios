// ScanlatorSettings.swift - Per-entry scanlator rules, persisted.
//
// One master toggle turns the feature on; it reveals an ordered list of
// scanlators. Dragging sets priority (used to merge duplicate chapter numbers),
// and each row has its own switch to hide that scanlator's chapters entirely.
//
// Stored in UserDefaults rather than the model: these are view preferences, and
// keeping them out of `Entry` avoids a schema migration for every tuning knob.
// The decision itself lives in `ScanlatorRules`, which is pure.

import Foundation

@Observable
@MainActor
final class ScanlatorSettings {

    /// Entry this belongs to (`sourceKey::url`).
    let key: String

    private(set) var value: ScanlatorPreference
    private let defaults: UserDefaults

    init(key: String, defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
        self.value = Self.load(key: key, defaults: defaults)
    }

    var isPriorityEnabled: Bool { value.priorityEnabled }

    /// True when any rule is in effect — priority merging or a hidden scanlator.
    var hasActiveRules: Bool { value.hasActiveRules }

    func setPriorityEnabled(_ enabled: Bool) {
        mutate { $0.priorityEnabled = enabled }
    }

    /// Show or hide one scanlator's chapters. Independent of priority merging.
    func setVisible(_ scanlator: String, _ visible: Bool) {
        mutate { value in
            if visible {
                value.disabled.removeAll { $0 == scanlator }
            } else if !value.disabled.contains(scanlator) {
                value.disabled.append(scanlator)
            }
        }
    }

    /// Show or hide every one of `scanlators` in a single write, so the chapter
    /// list is reconciled once rather than once per scanlator.
    func setAllVisible(_ scanlators: [String], _ visible: Bool) {
        mutate { value in
            if visible {
                value.disabled.removeAll { scanlators.contains($0) }
            } else {
                for name in scanlators where !value.disabled.contains(name) {
                    value.disabled.append(name)
                }
            }
        }
    }

    /// Make `order` the priority list.
    func setPriority(_ order: [String]) {
        mutate { $0.priority = order }
    }

    /// Priority order for `scanlators`: saved ones first, then anything new
    /// appended in the order the source listed it.
    func orderedScanlators(from scanlators: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for name in value.priority where scanlators.contains(name) {
            if seen.insert(name).inserted { result.append(name) }
        }
        for name in scanlators where seen.insert(name).inserted {
            result.append(name)
        }
        return result
    }

    // MARK: - Persistence

    private func mutate(_ body: (inout ScanlatorPreference) -> Void) {
        var updated = value
        body(&updated)
        guard updated != value else { return }
        value = updated
        if let data = try? JSONEncoder().encode(updated) {
            defaults.set(data, forKey: ScanlatorPreference.defaultsKey(key))
        }
        // Every chapter of the entry is hidden or shown by this, in the store
        // as well as in the list.
        if let container = LibraryMaintenance.container {
            ChapterVisibility.refresh(key: key, container: container)
        }
    }

    private static func load(key: String, defaults: UserDefaults) -> ScanlatorPreference {
        ScanlatorPreference.load(key: key, defaults: defaults)
    }
}

// MARK: - Applying to the chapter list

extension ScanlatorRules {

    /// Apply a preference to display chapters.
    static func apply(
        _ preference: ScanlatorPreference,
        to chapters: [ChapterDisplay]
    ) -> [ChapterDisplay] {
        guard preference.hasActiveRules else { return chapters }

        let items = chapters.map {
            Item(number: $0.chapterNumber, scanlator: $0.scanlator)
        }
        return keptIndices(for: items, preference: preference).map { chapters[$0] }
    }
}
