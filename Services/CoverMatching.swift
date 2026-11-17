// CoverMatching.swift
// Whether an AniList hit is the same book, for replacing a cover without asking.

import Foundation

/// Title rules for accepting a cover automatically.
///
/// AniList is a metadata site, not a cover CDN: a search for "Solo Leveling"
/// also returns the manhwa, side stories and spin-offs. A swap is only safe
/// when the names describe the same work once edition words are gone
/// ("Shadow Slave (Novel)" against "Shadow Slave"); anything merely similar
/// keeps the source cover and leaves the picker to the user.
enum CoverMatching {

    /// Words that name the edition, not the book.
    private static let editionWords: Set<String> = [
        "novel", "light", "manga", "manhwa", "manhua", "webtoon", "webnovel",
        "comic", "official", "colored", "coloured", "version",
    ]

    /// Lowercased, accents and punctuation gone, whitespace collapsed.
    static func normalize(_ title: String) -> String {
        let folded = title.folding(
            options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let letters = folded.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        }
        return String(letters).split(separator: " ").joined(separator: " ")
    }

    /// The title with edition words removed: "solo leveling novel" becomes
    /// "solo leveling". Empty when the title is only edition words.
    static func core(_ title: String) -> String {
        normalize(title)
            .split(separator: " ")
            .filter { !editionWords.contains(String($0)) }
            .joined(separator: " ")
    }

    /// Whether these names are the same book, closely enough to replace its
    /// cover without the user's approval.
    static func isSameBook(_ wanted: String, _ candidate: String) -> Bool {
        let lhs = normalize(wanted), rhs = normalize(candidate)
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        let wantedCore = core(wanted), candidateCore = core(candidate)
        guard !wantedCore.isEmpty, !candidateCore.isEmpty else { return false }
        if wantedCore == candidateCore { return true }
        return score(wantedCore, candidateCore) >= 0.9
    }

    /// 0...1, the shared share of words. Orders the picker's results; the
    /// automatic path never accepts one on this score alone.
    static func score(_ wanted: String, _ candidate: String) -> Double {
        let lhs = normalize(wanted), rhs = normalize(candidate)
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        if lhs == rhs { return 1 }
        let a = Set(lhs.split(separator: " ")), b = Set(rhs.split(separator: " "))
        let shared = Double(a.intersection(b).count)
        guard shared > 0 else { return 0 }
        return min(0.99, 2 * shared / Double(a.count + b.count))
    }
}
