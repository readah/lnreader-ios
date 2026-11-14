// SchemaV3.swift - The app's current SwiftData schema.
//
// V2 plus `Highlight`, the reader's saved highlights. The V2 models are reused
// unchanged, not copied: `SchemaV2.swift` stays frozen as the shape shipped
// before highlights existed, so a store opened by that build migrates straight
// through the lightweight stage below. Further changes to those models start a
// SchemaV4 instead of editing V2.

import Foundation
import SwiftData

/// Version 3 of the schema: adds the `Highlight` table.
enum SchemaV3: VersionedSchema {

    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

    static var models: [any PersistentModel.Type] {
        SchemaV2.models + [Highlight.self]
    }

    // MARK: - Highlight

    /// One saved reader highlight.
    ///
    /// A highlight is anchored to a chapter by url and to a paragraph by the
    /// `data-tts-index` the reader gives every text block, plus raw character
    /// offsets into that block's `textContent`. Offsets survive bionic reading
    /// (which only wraps glyphs in `<strong>`) and reflows; if a source returns
    /// changed text the range simply stops resolving, and the highlight remains
    /// in the Bookmarks screen until the reader deletes it.
    ///
    /// Book title and cover are copied in so Bookmarks can draw a book that has
    /// left the library, and so the screen never needs a relationship walk.
    @Model
    final class Highlight {

        #Index<Highlight>([\.chapterURL])

        var id: UUID = UUID()
        /// The selected text, as the reader saw it.
        var text: String = ""
        /// `ReaderHighlightColor.rawValue`. The eraser is never stored.
        var color: String = ""
        var createdAt: Date = Date.now

        // MARK: Anchor

        var sourceKey: String = ""
        var entryURL: String?
        var chapterURL: String = ""
        var chapterName: String = ""
        /// `-1` when the source gave no usable number.
        var chapterNumber: Double = -1
        var sourceOrder: Int = 0
        var paragraphIndex: Int = -1
        var startOffset: Int = 0
        var endOffset: Int = 0

        // MARK: Book face (denormalized for the store)

        var bookTitle: String = ""
        var bookCoverURL: String?

        init(
            text: String,
            color: String,
            sourceKey: String,
            entryURL: String?,
            chapterURL: String,
            chapterName: String,
            chapterNumber: Double,
            sourceOrder: Int,
            paragraphIndex: Int,
            startOffset: Int,
            endOffset: Int,
            bookTitle: String,
            bookCoverURL: String?
        ) {
            self.text = text
            self.color = color
            self.sourceKey = sourceKey
            self.entryURL = entryURL
            self.chapterURL = chapterURL
            self.chapterName = chapterName
            self.chapterNumber = chapterNumber
            self.sourceOrder = sourceOrder
            self.paragraphIndex = paragraphIndex
            self.startOffset = startOffset
            self.endOffset = endOffset
            self.bookTitle = bookTitle
            self.bookCoverURL = bookCoverURL
        }

        /// Separator between a source key and an entry url in `entryKey`.
        static let entrySeparator = "\u{1F}"

        static func entryKey(sourceKey: String, entryURL: String?) -> String {
            sourceKey + entrySeparator + (entryURL ?? "")
        }

        /// Identifies the book without needing a relationship.
        var entryKey: String {
            Self.entryKey(sourceKey: sourceKey, entryURL: entryURL)
        }

        var displayBookTitle: String {
            bookTitle.isEmpty ? "Untitled" : bookTitle
        }
    }
}

// MARK: - Type aliases

/// `Highlight` is new in V3; the other handles stay pointed at the frozen V2
/// models, which V3 reuses.
typealias Highlight = SchemaV3.Highlight
