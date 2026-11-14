// ChapterReader.swift - Picks the reader for a chapter's kind.
//
// Novels keep the WKWebView reader (TTS, comments, highlighting); manga get the
// image reader. Everything that opens a chapter goes through here so the choice
// is made in one place.

import SwiftUI

struct ChapterReader: View {

    let sourceKey: String
    let entryURL: String?
    let kind: ContentKind
    let chapterURL: String
    let chapterName: String
    var highlightParagraph: Int? = nil

    var body: some View {
        switch kind {
        case .manga:
            MangaReaderView(
                sourceKey: sourceKey,
                entryURL: entryURL,
                chapterURL: chapterURL,
                chapterName: chapterName
            )
        case .novel:
            ReaderView(
                chapterPath: chapterURL,
                chapterName: chapterName,
                sourceKey: sourceKey,
                entryURL: entryURL,
                highlightParagraph: highlightParagraph
            )
        }
    }
}
