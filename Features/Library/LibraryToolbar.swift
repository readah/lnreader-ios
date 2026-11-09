// LibraryToolbar.swift
// Least to most likely used, left to right: importing a book is rare, the
// options sheet is the one people reach for. No one-item overflow menu: Import
// is a real action, so it gets its own button.

import SwiftUI

struct LibraryToolbar: ToolbarContent {
    /// Filters on, or a per-category sort / layout override: the options
    /// button reads as "something is shaping this list".
    var isCustomised = false
    var onShowOptions: () -> Void = {}
    var onImport: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: onImport) {
                Image(systemName: "square.and.arrow.down")
            }
            .accessibilityLabel("Import EPUB or PDF")

            Button(action: onShowOptions) {
                // The accent is plain white in dark mode, so tinting the icon
                // cannot show "on". The filled variant of the symbol does.
                Image(systemName: isCustomised
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease")
            }
            .accessibilityLabel("Library options: filter, sort and display")
            .accessibilityValue(isCustomised ? "Customised" : "")
        }
    }
}
