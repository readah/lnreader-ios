// LibraryToolbar.swift
// Least to most likely used, left to right: importing a book is rare, a random
// pick is occasional, the options sheet is the one people reach for. No
// one-item overflow menu: Import is a real action, so it gets its own button.

import SwiftUI

struct LibraryToolbar: AppToolbarContent {
    /// Filters on, or a per-category sort / layout override: the options
    /// button reads as "something is shaping this list".
    var isCustomised = false
    /// A novel-only library has nothing a random manga button can open.
    var hasManga = true
    /// The candidate pass is running; stop a second tap stacking two pushes.
    var isPickingRandom = false
    var onShowOptions: () -> Void = {}
    var onImport: () -> Void
    var onOpenRandom: () -> Void

    var native: some ToolbarContent { content.native }
    var classic: some View { content.classic }

    private var content: some AppToolbarContent {
        AppToolbarItemGroup(placement: .primaryAction) {
            Button(action: onImport) {
                AppIcon(systemName: "square.and.arrow.down", size: 17, relativeTo: .body)
            }
            .accessibilityLabel("Import EPUB or PDF")

            Button(action: onOpenRandom) {
                AppIcon(systemName: "dice", size: 17, relativeTo: .body)
            }
            .disabled(!hasManga || isPickingRandom)
            .accessibilityLabel("Open random unread manga")

            Button(action: onShowOptions) {
                // The accent is plain white in dark mode, so tinting the icon
                // cannot show "on". The filled variant of the symbol does.
                AppIcon(systemName: isCustomised
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease", size: 17)
            }
            .accessibilityLabel("Library options: filter, sort and display")
            .accessibilityValue(isCustomised ? "Customised" : "")
        }
    }
}
