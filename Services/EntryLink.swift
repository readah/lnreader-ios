// EntryLink.swift - the `lnreader://entry` link a shared entry is.
//
// Pure: build and parse only, so the round trip is checkable headless.

import Foundation

/// A link to one entry.
///
///     lnreader://entry?source=<source key>&url=<source-relative path>&kind=<kind>&title=<name>
///
/// `url` is source-relative, like `SourceEntry.url`, so the link survives a
/// source changing its domain.
struct EntryLink: Equatable {
    static let scheme = "lnreader"
    static let host = "entry"

    let sourceKey: String
    /// Source-relative, as `SourceEntry.url` is.
    let entryPath: String
    let kind: ContentKind
    let title: String

    init(sourceKey: String, entryPath: String, kind: ContentKind, title: String) {
        self.sourceKey = sourceKey
        self.entryPath = entryPath
        self.kind = kind
        self.title = title
    }

    init(sourceEntry: SourceEntry) {
        self.init(
            sourceKey: sourceEntry.sourceKey,
            entryPath: sourceEntry.url,
            kind: sourceEntry.kind,
            title: sourceEntry.title
        )
    }

    /// What a screen can open straight away; it fetches details and chapters.
    var sourceEntry: SourceEntry {
        SourceEntry(sourceKey: sourceKey, kind: kind, url: entryPath, title: title)
    }

    /// The link to hand to a share sheet, or `nil` when there is nothing to
    /// point at.
    var shareURL: URL? {
        guard !sourceKey.isEmpty, !entryPath.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [
            URLQueryItem(name: "source", value: sourceKey),
            URLQueryItem(name: "url", value: entryPath),
            URLQueryItem(name: "kind", value: kind.rawValue),
            URLQueryItem(name: "title", value: title),
        ]
        return components.url
    }

    /// The link an opened URL describes, or `nil` for anything else.
    static func parse(_ url: URL) -> EntryLink? {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems
        else { return nil }

        func value(_ name: String) -> String? {
            guard let value = items.first(where: { $0.name == name })?.value,
                  !value.isEmpty else { return nil }
            return value
        }

        guard let sourceKey = value("source"), let entryPath = value("url") else { return nil }
        // An unknown kind is a novel: that is the app's default, and a link
        // written by hand should still open.
        let kind = value("kind").flatMap(ContentKind.init(rawValue:)) ?? .novel
        return EntryLink(
            sourceKey: sourceKey,
            entryPath: entryPath,
            kind: kind,
            title: value("title") ?? entryPath
        )
    }
}
