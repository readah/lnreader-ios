// RowCoverButton.swift
// The cover at the head of a list row, which opens the book rather than the
// chapter the row is about.
//
// History had this and Updates did not: the same tap opened the reader on one
// screen and the detail screen on the other. One component keeps them together.

import SwiftUI

struct RowCoverButton: View {
    let entry: Entry?
    /// Draws a second cover behind the first, for a row that folds several reads
    /// of one book into a single line.
    var stacked = false
    var action: () -> Void

    private static let width: CGFloat = 44
    private static let height: CGFloat = 63
    private static let corner: CGFloat = 6

    var body: some View {
        Button(action: action) {
            cover
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(entry?.displayTitle ?? "book")")
        .accessibilityHint("Opens the book, not the chapter")
    }

    private var cover: some View {
        let shape = RoundedRectangle(cornerRadius: Self.corner)
        return EntryCoverView(
            url: entry?.displayThumbnailURL,
            aspectRatio: LayoutConstants.coverAspectRatio
        )
        .frame(width: Self.width, height: Self.height)
        .clipShape(shape)
        .background(alignment: .top) {
            if stacked {
                shape
                    .fill(.quaternary)
                    .frame(width: Self.width - 8, height: Self.height)
                    .offset(y: -4)
            }
        }
    }
}
