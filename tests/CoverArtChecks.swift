// CoverArtChecks.swift - When an AniList hit may replace a cover without asking, headless.

import Foundation

@main
struct CoverArtChecks {
    static func main() {
        checkNormalize()
        checkSameBook()
        checkScore()
        print("PASS: cover matching — edition words ignored, punctuation and case folded, "
            + "spin-offs and subtitled entries rejected, similar titles scored but not accepted")
    }

    private static func checkNormalize() {
        precondition(CoverMatching.normalize("  Re:Zero  ") == "re zero", "punctuation becomes a space, edges trimmed")
        precondition(CoverMatching.normalize("Solo-Leveling!") == "solo leveling", "punctuation folded")
        precondition(CoverMatching.normalize("Café") == "cafe", "diacritics folded")
        precondition(CoverMatching.core("Shadow Slave (Novel)") == "shadow slave", "edition words dropped")
        precondition(CoverMatching.core("Light Novel") == "", "an edition-only title has no core")
    }

    private static func checkSameBook() {
        precondition(CoverMatching.isSameBook("Solo Leveling", "Solo Leveling"), "equal titles match")
        precondition(CoverMatching.isSameBook("solo leveling", "Solo-Leveling!"), "case and punctuation do not matter")
        precondition(CoverMatching.isSameBook("Café", "Cafe"), "accents do not matter")
        precondition(
            CoverMatching.isSameBook("Shadow Slave (Novel)", "Shadow Slave"),
            "an edition suffix on either side is not a different book")
        precondition(
            CoverMatching.isSameBook("The Beginning After the End", "The Beginning After the End (Novel)"),
            "the AniList edition suffix is ignored")

        precondition(!CoverMatching.isSameBook("", "Solo Leveling"), "an empty title never matches")
        precondition(!CoverMatching.isSameBook("Solo Leveling", "  "), "an empty candidate never matches")
        precondition(!CoverMatching.isSameBook("Novel", "Light Novel"), "two edition-only titles are not the same book")
        precondition(
            !CoverMatching.isSameBook("Solo Leveling", "Solo Leveling: Ragnarok"),
            "a spin-off is not the same book")
        precondition(
            !CoverMatching.isSameBook("Solo Leveling", "Solo Max-Level Newbie"),
            "a different series that shares a word is not the same book")
        precondition(
            !CoverMatching.isSameBook("Re:Zero", "Re:Zero − Starting Life in Another World"),
            "a shortened title does not auto-accept the full subtitle")
        precondition(!CoverMatching.isSameBook("Perfect Run", "Perfect Run 2"), "a sequel is not the same book")
    }

    private static func checkScore() {
        precondition(CoverMatching.score("Solo Leveling", "solo leveling") == 1, "equal titles score 1")
        precondition(CoverMatching.score("", "Solo Leveling") == 0, "nothing in common scores 0")
        precondition(CoverMatching.score("Solo Leveling", "Reverend Insanity") == 0, "disjoint titles score 0")
        let partial = CoverMatching.score("Solo Leveling", "Solo Max-Level Newbie")
        precondition(partial > 0 && partial < 0.9, "a shared word scores but stays under the cut-off")
        precondition(CoverMatching.score("Solo Leveling", "Solo Leveling Ragnarok") < 1, "similar is capped under 1")
    }
}
