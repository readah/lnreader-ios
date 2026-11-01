// EntryLinkChecks.swift - the shared entry link, headless.
//
// A link outlives the build that wrote it, so the round trip and the refusals
// are checked rather than assumed.

import Foundation

@main
struct EntryLinkChecks {

    static func main() {
        checkRoundTrip()
        checkAwkwardPaths()
        checkMissingFields()
        checkForeignLinks()
        checkDefaults()
        print("PASS: entry links — round trip, awkward paths, missing fields, "
            + "foreign links, defaults")
    }

    /// Every field survives being written to a URL and read back.
    private static func checkRoundTrip() {
        let entry = SourceEntry(
            sourceKey: "novelupdates",
            kind: .manga,
            url: "/manga/that-time-i-was-reincarnated",
            title: "That Time I Was Reincarnated"
        )
        let link = EntryLink(sourceEntry: entry)
        guard let url = link.shareURL else { preconditionFailure("no share url") }
        precondition(url.scheme == "lnreader", "scheme is \(url.scheme ?? "nil")")
        precondition(url.host == "entry", "host is \(url.host ?? "nil")")

        guard let parsed = EntryLink.parse(url) else {
            preconditionFailure("link did not parse: \(url.absoluteString)")
        }
        precondition(parsed == link, "round trip changed the link: \(parsed) != \(link)")

        // And what it opens is the entry it was made from.
        let reopened = parsed.sourceEntry
        precondition(reopened.sourceKey == entry.sourceKey, "source key lost")
        precondition(reopened.url == entry.url, "url lost")
        precondition(reopened.kind == entry.kind, "kind lost")
        precondition(reopened.title == entry.title, "title lost")
    }

    /// A path and a title with the characters that break a hand-built URL.
    private static func checkAwkwardPaths() {
        let entry = SourceEntry(
            sourceKey: "manga::dex",
            kind: .manga,
            url: "/title/one piece?x=1&y=2#read",
            title: "One Piece — Vol. 1 & 2 (50% off) #1"
        )
        let link = EntryLink(sourceEntry: entry)
        guard let url = link.shareURL, let parsed = EntryLink.parse(url) else {
            preconditionFailure("awkward link did not survive: \(link)")
        }
        precondition(parsed == link, "awkward round trip changed the link: \(parsed)")
        precondition(
            !url.absoluteString.contains(" "),
            "a space was left unencoded: \(url.absoluteString)"
        )
    }

    /// A link with no source or no path cannot be opened, and is not written.
    private static func checkMissingFields() {
        precondition(
            EntryLink(sourceKey: "", entryPath: "/a", kind: .novel, title: "A").shareURL == nil,
            "a link with no source key must not be written"
        )
        precondition(
            EntryLink(sourceKey: "k", entryPath: "", kind: .novel, title: "A").shareURL == nil,
            "a link with no path must not be written"
        )
        precondition(
            EntryLink.parse(URL(string: "lnreader://entry?url=%2Fa")!) == nil,
            "a link with no source key must not parse"
        )
        precondition(
            EntryLink.parse(URL(string: "lnreader://entry?source=k")!) == nil,
            "a link with no path must not parse"
        )
    }

    /// Anything that is not one of our entry links is refused, not guessed at.
    private static func checkForeignLinks() {
        let refused = [
            "https://example.com/entry?source=k&url=%2Fa",
            "lnreader://anilist-auth#access_token=abc",
            "lnreader://reset-password?token=abc",
            "lnreader://entry",
            "not a url at all",
        ]
        for string in refused {
            guard let url = URL(string: string) else { continue }
            precondition(
                EntryLink.parse(url) == nil,
                "should not have parsed: \(string)"
            )
        }
    }

    /// A hand-written link opens: the kind falls back to a novel, and the title
    /// to the path, so nothing downstream sees an empty name.
    private static func checkDefaults() {
        guard let parsed = EntryLink.parse(
            URL(string: "lnreader://entry?source=k&url=%2Fnovel%2Ffoo-1")!
        ) else { preconditionFailure("minimal link did not parse") }
        precondition(parsed.kind == .novel, "kind should default to a novel, got \(parsed.kind)")
        precondition(parsed.title == "/novel/foo-1", "title should fall back to the path")

        // An unknown kind is a novel too, rather than a refusal.
        guard let unknown = EntryLink.parse(
            URL(string: "lnreader://entry?source=k&url=%2Fa&kind=light-novel")!
        ) else { preconditionFailure("unknown kind did not parse") }
        precondition(unknown.kind == .novel, "unknown kind should fall back to a novel")
    }
}
