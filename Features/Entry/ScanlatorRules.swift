// ScanlatorRules.swift - Which chapters survive, given a scanlator preference.
//
// Pure and free of SwiftUI so it can be checked without a simulator: the same
// function decides what the chapter list shows and what a test asserts.

import Foundation

/// Per-entry scanlator preference.
///
/// Two independent features:
/// - **Hiding** (`disabled`) — chapters from these scanlators are dropped. Works
///   on its own, no other toggle needed.
/// - **Priority** (`priorityEnabled` + `priority`) — chapters that share a
///   number are merged, keeping the scanlator highest in the list.
///
/// They used to be one switch: hiding was gated behind the priority toggle,
/// which meant you could not simply hide a scanlator you do not want.
struct ScanlatorPreference: Codable, Equatable {
    /// Merge chapters that share a number, keeping the highest-ranked one.
    var priorityEnabled = false
    /// Highest priority first. Unknown scanlators sort after these.
    var priority: [String] = []
    /// Chapters from these scanlators are hidden. Independent of priority.
    var disabled: [String] = []

    var disabledSet: Set<String> { Set(disabled) }

    /// The saved preference for `key` (`sourceKey::url`), or the default.
    static func load(key: String, defaults: UserDefaults = .standard) -> ScanlatorPreference {
        guard let data = defaults.data(forKey: defaultsKey(key)),
              let decoded = try? JSONDecoder().decode(ScanlatorPreference.self, from: data)
        else { return ScanlatorPreference() }
        return decoded
    }

    static func defaultsKey(_ key: String) -> String { "scanlators.\(key)" }

    /// Any rule is in effect. Drives the toolbar indicator.
    var hasActiveRules: Bool { priorityEnabled || !disabled.isEmpty }

    /// `priorityEnabled` was called `enabled` on disk before hiding became
    /// independent, so the key stays as it was.
    enum CodingKeys: String, CodingKey {
        case priorityEnabled = "enabled"
        case priority
        case disabled
    }
}

enum ScanlatorRules {

    /// The only part of a chapter the rules care about.
    struct Item {
        let number: Double?
        let scanlator: String?

        init(number: Double?, scanlator: String?) {
            self.number = number
            self.scanlator = scanlator
        }
    }

    /// Indices to keep, in the original order.
    ///
    /// - Disabled scanlator → its chapters are dropped, whether or not priority
    ///   merging is on.
    /// - Priority on → one chapter per number: the one whose scanlator ranks
    ///   highest. Chapters with no number are never merged, because there is
    ///   nothing to match them on.
    /// - Priority off → nothing is merged; only hiding applies.
    static func keptIndices(for chapters: [Item], preference: ScanlatorPreference) -> [Int] {
        let disabled = preference.disabledSet

        func isHidden(_ chapter: Item) -> Bool {
            guard let scanlator = chapter.scanlator, !scanlator.isEmpty else { return false }
            return disabled.contains(scanlator)
        }

        // Hiding stands on its own. It used to require the priority toggle,
        // which made "hide this scanlator" unreachable on its own.
        guard preference.priorityEnabled else {
            return chapters.indices.filter { !isHidden(chapters[$0]) }
        }

        var rank: [String: Int] = [:]
        for (index, name) in preference.priority.enumerated() {
            rank[name] = index
        }

        func rankOf(_ chapter: Item) -> Int {
            guard let scanlator = chapter.scanlator, !scanlator.isEmpty else { return Int.max }
            return rank[scanlator] ?? Int.max - 1
        }

        var best: [Double: Int] = [:]
        for (index, chapter) in chapters.enumerated() where !isHidden(chapter) {
            guard let number = chapter.number, number > 0 else { continue }
            if let current = best[number] {
                if rankOf(chapter) < rankOf(chapters[current]) {
                    best[number] = index
                }
            } else {
                best[number] = index
            }
        }

        let winners = Set(best.values)
        return chapters.indices.filter { index in
            let chapter = chapters[index]
            if isHidden(chapter) { return false }
            guard let number = chapter.number, number > 0 else { return true }
            return winners.contains(index)
        }
    }
}
