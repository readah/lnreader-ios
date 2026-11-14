import SwiftUI

// MARK: - App Theme

/// Semantic color tokens for the LNReader app.
///
/// Use these instead of raw `Color` literals so the palette can be
/// updated in a single place.
enum AppTheme {

    // MARK: Interactive Palette

    /// Primary interactive color: black in light mode, white in dark mode.
    ///
    /// The interface is deliberately monochrome, like the system's own glass
    /// apps: text is primary or secondary, and anything you can tap is
    /// primary too. Grey means "less important", never "tappable". Red is
    /// *not* the accent — it is reserved for destructive actions and error
    /// states so that it still means something when it does appear.
    ///
    /// This is also the `AccentColor` asset, which is where controls get
    /// their tint. Do not put a `.tint` at the root: an explicit tint beats a
    /// button's role, so destructive swipe actions would lose their red.
    static let accent = Color.primary

    /// High-contrast fill for a primary control (play button, selected dot).
    static let primaryFill = Color.primary

    /// Track fill for an enabled switch. A primary track would be
    /// white-on-white in dark mode, so switches get this mid gray instead,
    /// applied once at the root by `AppToggleStyle`.
    static let controlFill = Color(light: Color(white: 0.12), dark: Color(white: 0.62))

    /// Content drawn on top of `primaryFill`.
    static let onPrimaryFill = Color(light: .white, dark: .black)

    /// Grouped surface for cards and inset rows (systemGray6).
    static let surface = Color(
        light: Color(red: 242 / 255, green: 242 / 255, blue: 247 / 255),
        dark: Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    )

    // MARK: Reader

    /// Warm, paper-like background for the reader view.
    static let readerBackground = Color(
        light: Color(hue: 0.10, saturation: 0.08, brightness: 0.98),
        dark: Color(hue: 0.10, saturation: 0.05, brightness: 0.12)
    )

    /// Primary text color for the reader view.
    static let readerText = Color(
        light: Color(hue: 0.0, saturation: 0.0, brightness: 0.12),
        dark: Color(hue: 0.0, saturation: 0.0, brightness: 0.90)
    )

    // MARK: Surface & Text

    /// Subtle card background (systemGray6).
    static let cardBackground = surface

    /// Hairline outline for cards and avatars.
    static let hairline = Color(uiColor: .separator)

    // MARK: Semantic

    /// Destructive action color (delete, remove, failed state).
    ///
    /// Red is intentionally rare: use it only where the user must recognize a
    /// destructive or failed outcome, never for decoration or ordinary accents.
    static let destructive = Color.red

    /// Recoverable problems: a paused job, a failed preview, a bulk delete
    /// that sits beside the red single delete.
    static let warning = Color.orange
}

// MARK: - Switches

/// The app's switch: the stock switch with the `controlFill` track. Applied
/// once at the root with `.toggleStyle(AppToggleStyle())`, which reaches every
/// toggle without a root `.tint`, so buttons keep the primary accent and their
/// roles. Toggles inside menus still draw as checkmarks.
struct AppToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration)
            .toggleStyle(.switch)
            .tint(AppTheme.controlFill)
    }
}

// MARK: - Adaptive Color Helper

extension Color {
    /// Creates a color that adapts between light and dark appearances.
    init(light: Color, dark: Color) {
        #if os(iOS)
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(dark)
                : UIColor(light)
        })
        #elseif os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(dark)
                : NSColor(light)
        })
        #else
        self = light
        #endif
    }
}

// MARK: - Typography

/// Typographic scale for the LNReader app.
///
/// Provides a consistent set of fonts sized for the app's
/// information hierarchy — from large titles down to small captions.
enum Typography {

    // Every token is a text style, so the scale follows the user's Dynamic Type
    // setting. The point sizes in the comments are the default (Large) sizes.

    /// Extra-large heading — 28pt bold rounded.
    static let largeTitle: Font = .system(.title, design: .rounded, weight: .bold)

    /// Section heading — 22pt semibold rounded.
    static let title: Font = .system(.title2, design: .rounded, weight: .semibold)

    /// Row / card heading — 17pt semibold.
    static let headline: Font = .headline

    /// Body text — 15pt regular.
    static let body: Font = .subheadline

    /// Captions and metadata — 13pt medium.
    static let caption: Font = .footnote.weight(.medium)

    /// Smallest text — 11pt regular.
    static let small: Font = .caption2
}

// MARK: - Hex Color Helper

extension Color {
    /// Converts a Color to its hex string representation (e.g. "#RRGGBB").
    func toHex() -> String? {
        #if os(iOS)
        let uiColor = UIColor(self)
        guard let cgColor = uiColor.cgColor.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
              let components = cgColor.components,
              components.count >= 3 else {
            return nil
        }
        let red = components[0]
        let green = components[1]
        let blue = components[2]
        let alpha = components.count > 3 ? components[3] : 1.0
        #elseif os(macOS)
        let nsColor = NSColor(self)
        guard let rgbColor = nsColor.usingColorSpace(.deviceRGB) else { return nil }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        rgbColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #endif
        
        if alpha < 1.0 {
            return String(format: "#%02lX%02lX%02lX%02lX",
                          Int(round(red * 255)),
                          Int(round(green * 255)),
                          Int(round(blue * 255)),
                          Int(round(alpha * 255)))
        } else {
            return String(format: "#%02lX%02lX%02lX",
                          Int(round(red * 255)),
                          Int(round(green * 255)),
                          Int(round(blue * 255)))
        }
    }
}

// Native navigation keeps the source view alive for the interactive return zoom.
extension View {
    @ViewBuilder func bookTransitionSource<ID: Hashable>(_ id: ID, in namespace: Namespace.ID?) -> some View {
        #if os(iOS)
        if let namespace { self.matchedTransitionSource(id: id, in: namespace) } else { self }
        #else
        self
        #endif
    }
    func bookZoom<ID: Hashable>(from id: ID, in namespace: Namespace.ID) -> some View {
        modifier(BookZoomTransition(sourceID: id, namespace: namespace))
    }
}
private struct BookZoomTransition<ID: Hashable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let sourceID: ID
    let namespace: Namespace.ID
    @ViewBuilder func body(content: Content) -> some View {
        #if os(iOS)
        if reduceMotion { content } else { content.navigationTransition(.zoom(sourceID: sourceID, in: namespace)) }
        #else
        content
        #endif
    }
}


// MARK: - Ambient Background

/// Slow, touch-reactive light field for full-screen surfaces.
///
/// A blurred mesh gradient: soft, static in feel, and cheap enough to keep behind
/// frosted cards without fighting the content for attention.
struct AuroraBackdrop: View {
    /// Finger position in this view's coordinate space.
    var touch: CGPoint = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let px = Float(min(max(touch.x / 390, 0), 1)) - 0.5
            let py = Float(min(max(touch.y / 800, 0), 1)) - 0.5
            MeshGradient(
                width: 3,
                height: 3,
                points: [
                    SIMD2<Float>(0, 0),
                    SIMD2<Float>(Float(0.5 + 0.03 * sin(t * 0.20)), 0),
                    SIMD2<Float>(1, 0),
                    SIMD2<Float>(0, Float(0.5 + 0.04 * cos(t * 0.16))),
                    SIMD2<Float>(Float(0.5 + 0.07 * sin(t * 0.12)) + px * 0.08,
                                 Float(0.5 + 0.06 * cos(t * 0.18)) + py * 0.08),
                    SIMD2<Float>(1, Float(0.5 + 0.04 * sin(t * 0.21))),
                    SIMD2<Float>(0, 1),
                    SIMD2<Float>(Float(0.5 + 0.03 * cos(t * 0.14)), 1),
                    SIMD2<Float>(1, 1)
                ],
                colors: [
                    .black, Color(white: 0.07), .black,
                    Color(white: 0.10), Color(white: 0.42), Color(white: 0.09),
                    .black, Color(white: 0.05), .black
                ]
            )
            .blur(radius: 40)
        }
        .overlay(Color.black.opacity(0.30))
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

extension View {
    /// The one filled call to action on a screen (Log in, Retry, Sync): a
    /// prominent glass capsule in the primary fill with contrasting text.
    func primaryActionStyle() -> some View {
        self
            .buttonStyle(.glassProminent)
            .tint(AppTheme.primaryFill)
            .foregroundStyle(AppTheme.onPrimaryFill)
    }

    /// Chrome shared by every settings screen: a large sentence-case title.
    func settingsScreen(_ title: String) -> some View {
        self
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
    }
}
