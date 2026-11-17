import SwiftUI

/// Platform-aware layout constants for the LNReader app.
///
/// All spatial values live here so they can be tuned in a single place.
/// Computed properties marked `@MainActor` use device idiom checks that
/// require main-thread access.
struct LayoutConstants {

    // MARK: - Grid

    /// Minimum width of a grid item — adapts to iPhone vs iPad / Mac.
    @MainActor static var gridItemMinSize: CGFloat {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            return 220
        } else {
            return 160
        }
        #else
        return 220
        #endif
    }

    /// Width-to-height ratio for novel cover images.
    static let coverAspectRatio: CGFloat = 0.7

    /// Height used for cover thumbnails inside grid cells.
    static let coverHeight: CGFloat = 200

    // MARK: - Corner Radii

    /// Default corner radius for cards and containers.
    static let cornerRadius: CGFloat = 12

    /// Corner radius for Liquid Glass surfaces.
    static let glassCornerRadius: CGFloat = 16

    /// Corner radius for badge / pill shapes.
    static let badgeCornerRadius: CGFloat = 24

    // MARK: - Spacing

    /// Standard spacing between glass elements inside a `AppGlassEffectContainer`.
    static let glassSpacing: CGFloat = 16

    /// Default horizontal padding for screen-edge content.
    static let horizontalPadding: CGFloat = 16

    /// Default vertical spacing between stacked elements.
    static let verticalSpacing: CGFloat = 12

    // MARK: - Row Sizing

    /// Fixed height for list rows (e.g., library list mode).
    static let listRowHeight: CGFloat = 80
}
