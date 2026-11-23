// ReaderRouter.swift - Opens the reader as its own full-screen window.
//
// The reader used to be pushed onto whichever NavigationStack the user came
// from, which made it look like a modal and kept the tab bar's navigation state
// around it. Now anything that opens a chapter asks this router, and the root
// view presents one full-screen cover.

import Observation
import SwiftUI

struct ReaderRequest: Identifiable, Hashable {
    let id = UUID()
    let sourceKey: String
    let entryURL: String?
    let kind: ContentKind
    let chapterURL: String
    let chapterName: String
    /// A paragraph to open at, used by Bookmarks.
    var paragraphIndex: Int? = nil
}

@Observable
@MainActor
final class ReaderRouter {

    var request: ReaderRequest?

    func open(
        sourceKey: String,
        entryURL: String?,
        kind: ContentKind,
        chapterURL: String,
        chapterName: String,
        paragraphIndex: Int? = nil
    ) {
        request = ReaderRequest(
            sourceKey: sourceKey,
            entryURL: entryURL,
            kind: kind,
            chapterURL: chapterURL,
            chapterName: chapterName,
            paragraphIndex: paragraphIndex
        )
    }

    func open(_ chapter: ChapterDisplay, sourceKey: String, entryURL: String?, kind: ContentKind) {
        open(
            sourceKey: sourceKey,
            entryURL: entryURL,
            kind: kind,
            chapterURL: chapter.path,
            chapterName: chapter.name
        )
    }

    func close() {
        request = nil
    }
}

extension ReaderRouter {
    /// Every History and Updates row opens the same way, whatever screen it is
    /// on. A chapter whose entry was removed still opens with blank source data.
    func open(_ chapter: Chapter) {
        open(
            sourceKey: chapter.entry?.sourceKey ?? "",
            entryURL: chapter.entry?.url,
            kind: chapter.entry?.kind ?? .novel,
            chapterURL: chapter.url,
            chapterName: chapter.name
        )
    }
}

// MARK: - Covered-by-reader environment

private struct IsReaderPresentedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the reader is presented over the tabs. The tabs stay alive
    /// underneath a full screen cover and their `@Query`s keep firing on every
    /// progress save, so screens that do real work in `body` should hold their
    /// last result while this is set.
    var isReaderPresented: Bool {
        get { self[IsReaderPresentedKey.self] }
        set { self[IsReaderPresentedKey.self] = newValue }
    }
}
