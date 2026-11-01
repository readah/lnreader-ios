// ChapterTransitionCard.swift - The card shown past the first or last page of a chapter.

import SwiftUI

/// The card between two chapters: what just ended and what comes next.
struct ChapterTransitionCard: View {
    enum Direction { case previous, next }
    let direction: Direction
    let title: String
    @Environment(\.coverTint) private var coverTint

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: direction == .next ? "chevron.down.circle" : "chevron.up.circle")
                .font(.largeTitle.weight(.light))
                .imageScale(.large)
                .foregroundStyle(coverTint ?? .white)
            Text(direction == .next ? "Next chapter" : "Previous chapter")
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.white.secondary)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            ProgressView().tint(coverTint ?? .white).padding(.top, 6)
        }
        .foregroundStyle(.white)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .accessibilityElement(children: .combine)
    }
}
