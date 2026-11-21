import SwiftUI

#if os(iOS)
import UIKit
#endif

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
    static let accent = Color("AccentColor")
    static let confirmation = Color.blue

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
    @Environment(\.noLiquidGlass) private var classic
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if classic {
            Toggle(configuration).toggleStyle(ClassicToggleStyle())
        } else {
            Toggle(configuration).toggleStyle(.switch).tint(AppTheme.controlFill)
        }
    }
}

// MARK: - Sliding selection

/// Shared by the library, source catalogues, reader settings, and options sheets.
/// Supports both tap-to-switch and continuous drag-to-scrub across the glass lens.
struct AppSlidingPicker<Selection: Hashable>: View {
    let title: String
    @Binding var selection: Selection
    let options: [Selection]
    let label: (Selection) -> String

    @Namespace private var indicator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.coverTint) private var coverTint

    @State private var isDragging = false
    @State private var dragX: CGFloat?

    private var selectedIndex: Int {
        options.firstIndex(of: selection) ?? 0
    }

    private var isDark: Bool { colorScheme == .dark }

    private var lensSpring: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .spring(duration: 0.32, bounce: 0.18)
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                accessibilityStack
            } else {
                horizontalBar
            }
        }
        .hapticFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    // MARK: - Horizontal Liquid Glass Lens Bar

    private var horizontalBar: some View {
        let inset: CGFloat = 3
        let barHeight: CGFloat = 42

        return GeometryReader { geo in
            let count = max(options.count, 1)
            let innerWidth = max(1, geo.size.width - inset * 2)
            let segmentWidth = innerWidth / CGFloat(count)
            let maxOffset = max(0, innerWidth - segmentWidth)

            let visualIndex = layoutDirection == .rightToLeft
                ? (count - 1 - selectedIndex)
                : selectedIndex
            let restingX = CGFloat(visualIndex) * segmentWidth

            let lensX: CGFloat = {
                guard let dragX else { return restingX }
                let centered = dragX - inset - segmentWidth * 0.5
                if centered < 0 { return dampedOverdrag(centered) }
                if centered > maxOffset { return maxOffset + dampedOverdrag(centered - maxOffset) }
                return centered
            }()

            ZStack(alignment: .leading) {
                // Quiet recessed channel — stays out of the way on black.
                Capsule(style: .continuous)
                    .fill(isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.045))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(
                                (isDark ? Color.white : Color.black).opacity(0.07),
                                lineWidth: 0.5
                            )
                    }

                // Pure Liquid Glass lens + subtle bottom accent hairline.
                Capsule(style: .continuous)
                    .fill(.clear)
                    .appGlassEffect(.regular.interactive(), in: .capsule)
                    .overlay(alignment: .bottom) {
                        Capsule()
                            .fill((coverTint ?? (isDark ? Color.white : Color.black)).opacity(isDragging ? 0.85 : 0.45))
                            .frame(width: isDragging ? 20 : 14, height: 2.5)
                            .padding(.bottom, 3.5)
                    }
                    .frame(width: segmentWidth, height: barHeight - inset * 2)
                    .scaleEffect(
                        isDragging && !reduceMotion ? CGSize(width: 1.03, height: 1.05) : CGSize(width: 1, height: 1)
                    )
                    .offset(x: inset + lensX)
                    .allowsHitTesting(false)

                // Segment labels
                HStack(spacing: 0) {
                    ForEach(options, id: \.self) { option in
                        let isSelected = selection == option
                        Button {
                            withAnimation(lensSpring) { selection = option }
                        } label: {
                            Text(label(option))
                                .font(Typography.subheadline)
                                .fontWeight(isSelected ? .semibold : .regular)
                                .foregroundStyle(
                                    isSelected
                                        ? AnyShapeStyle(.primary)
                                        : AnyShapeStyle(.primary.opacity(0.48))
                                )
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(.capsule)
                        }
                        .buttonStyle(AppPlainButtonStyle())
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .padding(inset)
            }
            .contentShape(.capsule)
            .highPriorityGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        guard abs(value.translation.width) >= abs(value.translation.height) * 0.8 else { return }
                        if !isDragging {
                            withAnimation(reduceMotion ? nil : .spring(duration: 0.2, bounce: 0.15)) {
                                isDragging = true
                            }
                        }
                        dragX = value.location.x

                        let localX = min(max(value.location.x - inset, 0), innerWidth - 0.01)
                        let rawIdx = min(max(Int(localX / segmentWidth), 0), count - 1)
                        let logicalIdx = layoutDirection == .rightToLeft ? (count - 1 - rawIdx) : rawIdx
                        if options.indices.contains(logicalIdx), options[logicalIdx] != selection {
                            selection = options[logicalIdx]
                        }
                    }
                    .onEnded { _ in
                        withAnimation(lensSpring) {
                            isDragging = false
                            dragX = nil
                        }
                    }
            )
            .animation(isDragging ? .interactiveSpring(response: 0.14, dampingFraction: 0.88) : lensSpring, value: lensX)
            .animation(lensSpring, value: selection)
        }
        .frame(height: barHeight)
    }

    // MARK: - Accessibility Vertical Fallback

    private var accessibilityStack: some View {
        VStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection == option
                Button {
                    withAnimation(lensSpring) { selection = option }
                } label: {
                    Text(label(option))
                        .font(Typography.body)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(
                            isSelected
                                ? AnyShapeStyle(.primary)
                                : AnyShapeStyle(.primary.opacity(0.5))
                        )
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background {
                            if isSelected {
                                Capsule(style: .continuous)
                                    .fill(.clear)
                                    .appGlassEffect(.regular.interactive(), in: .capsule)
                                    .matchedGeometryEffect(id: "selection", in: indicator)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(AppPlainButtonStyle())
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.045))
        )
        .animation(lensSpring, value: selection)
    }

    private func dampedOverdrag(_ excess: CGFloat) -> CGFloat {
        let sign: CGFloat = excess < 0 ? -1 : 1
        let magnitude = abs(excess)
        return sign * (4.0 * magnitude / (magnitude + 36.0))
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

    static let navigationTitle: Font = .system(.title2, design: .serif, weight: .bold)

    /// Row / card heading — 17pt semibold.
    static let headline: Font = .headline

    /// Body text — 15pt regular.
    static let body: Font = .subheadline

    /// Interactive controls — the same 15pt face as `body`, named for the
    /// UI-sans role it plays in the classic (non-glass) surface system.
    static let subheadline: Font = .subheadline

    /// Captions and metadata — 13pt medium.
    static let caption: Font = .footnote.weight(.medium)

    /// Smallest text — 11pt regular.
    static let small: Font = .caption2
}

extension View {
    /// Keeps native navigation behavior while styling the screen's actual bar
    /// and navigation item, rather than an appearance proxy SwiftUI can override.
    func appNavigationTitle(_ title: Text, onTitleVerticalSwipe: (() -> Void)? = nil) -> some View {
        #if os(iOS)
        self
            .scrollContentBackground(.hidden)
            .appBackdrop()
            .accentColor(AppTheme.accent)
            .navigationTitle(title)
            .preference(key: AppScreenTitleKey.self, value: title)
            .environment(\.appScreenTitle, title)
            .modifier(AppTitleSwipePreference(action: onTitleVerticalSwipe))
            .appNavigationChrome()
            .background {
                NavigationTitleFontBridge(onTitleVerticalSwipe: onTitleVerticalSwipe)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        #else
        self
            .scrollContentBackground(.hidden)
            .appBackdrop()
            .accentColor(AppTheme.accent)
            .navigationTitle(title)
        #endif
    }

    func appNavigationTitle(_ title: LocalizedStringKey, onTitleVerticalSwipe: (() -> Void)? = nil) -> some View {
        appNavigationTitle(Text(title), onTitleVerticalSwipe: onTitleVerticalSwipe)
    }

    @_disfavoredOverload
    func appNavigationTitle<S: StringProtocol>(_ title: S, onTitleVerticalSwipe: (() -> Void)? = nil) -> some View {
        appNavigationTitle(Text(title), onTitleVerticalSwipe: onTitleVerticalSwipe)
    }
}

#if os(iOS)
private struct NavigationTitleFontBridge: UIViewControllerRepresentable {
    var onTitleVerticalSwipe: (() -> Void)?

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.onTitleVerticalSwipe = onTitleVerticalSwipe
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onTitleVerticalSwipe = onTitleVerticalSwipe
        controller.refresh()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.removeTitleSwipe()
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var onTitleVerticalSwipe: (() -> Void)?
        private weak var swipeBar: UINavigationBar?
        private weak var swipeHost: UIView?
        private var titlePan: UIPanGestureRecognizer?
        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
                (controller: Controller, _: UITraitCollection) in
                controller.refresh()
            }
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            refresh()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            refresh()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyFonts()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            removeTitleSwipe()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            applyFonts()
        }

        func refresh() {
            applyFonts()
            // SwiftUI may configure the navigation item later in this update.
            DispatchQueue.main.async { [weak self] in self?.applyFonts() }
        }

        private func applyFonts() {
            guard let navigationController else { return }
            var owner: UIViewController = self
            while let parent = owner.parent, parent !== navigationController {
                owner = parent
            }
            // An outgoing or offscreen screen must not restyle the current bar.
            guard navigationController.topViewController === owner else { return }

            let large = serifFont(size: 34, weight: .bold, style: .largeTitle)
            let inline = serifFont(size: 17, weight: .semibold, style: .headline)
            let bar = navigationController.navigationBar
            let item = owner.navigationItem
            updateTitleSwipe(on: bar)

            func update(
                _ appearance: UINavigationBarAppearance?,
                set: (UINavigationBarAppearance) -> Void
            ) {
                guard let appearance else { return }
                let hasLargeFont = (appearance.largeTitleTextAttributes[.font] as? UIFont)?.isEqual(large) == true
                let hasInlineFont = (appearance.titleTextAttributes[.font] as? UIFont)?.isEqual(inline) == true
                guard !hasLargeFont || !hasInlineFont else { return }
                let copy = appearance.copy()
                copy.largeTitleTextAttributes[.font] = large
                copy.titleTextAttributes[.font] = inline
                set(copy)
            }

            // Preserve nil states and their native transparent/compact fallbacks.
            // Item appearances take precedence over the bar's entire appearance.
            update(bar.standardAppearance) { bar.standardAppearance = $0 }
            update(bar.scrollEdgeAppearance) { bar.scrollEdgeAppearance = $0 }
            update(bar.compactAppearance) { bar.compactAppearance = $0 }
            update(bar.compactScrollEdgeAppearance) { bar.compactScrollEdgeAppearance = $0 }
            update(item.standardAppearance) { item.standardAppearance = $0 }
            update(item.scrollEdgeAppearance) { item.scrollEdgeAppearance = $0 }
            update(item.compactAppearance) { item.compactAppearance = $0 }
            update(item.compactScrollEdgeAppearance) { item.compactScrollEdgeAppearance = $0 }
        }

        private func updateTitleSwipe(on bar: UINavigationBar) {
            guard onTitleVerticalSwipe != nil else {
                removeTitleSwipe()
                return
            }
            guard let host = bar.window else { return }
            guard swipeBar !== bar || swipeHost !== host || titlePan == nil else { return }
            removeTitleSwipe()
            let pan = UIPanGestureRecognizer(target: self, action: #selector(titleSwiped(_:)))
            pan.maximumNumberOfTouches = 1
            // The touch that starts on the title is aimed at the mode, not at
            // the list behind the glass: take it, do not share it.
            pan.cancelsTouchesInView = true
            pan.delegate = self
            // Glass chrome can hit-test through the bar. Observe from its window,
            // but accept only touches on the visible title below.
            host.addGestureRecognizer(pan)
            swipeHost = host
            swipeBar = bar
            titlePan = pan
        }

        func removeTitleSwipe() {
            if let titlePan { swipeHost?.removeGestureRecognizer(titlePan) }
            releaseScrolls()
            titlePan = nil
            swipeBar = nil
            swipeHost = nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let bar = swipeBar else { return false }
            // Restrict the recognizer to the visible large-title text, not the
            // toolbar buttons or the scroll view beneath the navigation bar.
            func titleFrame(in view: UIView) -> CGRect? {
                guard !view.isHidden, view.alpha > 0.01 else { return nil }
                if let label = view as? UILabel,
                   label.text?.isEmpty == false,
                   label.font.pointSize >= 24 {
                    let frame = label.convert(label.bounds, to: bar)
                    if frame.intersects(bar.bounds) { return frame }
                }
                for child in view.subviews {
                    if let frame = titleFrame(in: child) { return frame }
                }
                return nil
            }
            if let frame = titleFrame(in: bar) {
                return frame.insetBy(dx: -8, dy: -6).contains(touch.location(in: bar))
            }
            // iOS can host the large title in a private SwiftUI-backed view,
            // not a UILabel. Use that title container's bounds as a fallback.
            func largeTitleFrame(in view: UIView) -> CGRect? {
                guard !view.isHidden, view.alpha > 0.01 else { return nil }
                if String(describing: type(of: view)).contains("LargeTitle"),
                   view.bounds.width > 0, view.bounds.height > 0 {
                    return view.convert(view.bounds, to: bar)
                }
                for child in view.subviews {
                    if let frame = largeTitleFrame(in: child) { return frame }
                }
                return nil
            }
            guard let frame = largeTitleFrame(in: bar) else { return false }
            return frame.intersection(bar.bounds).contains(touch.location(in: bar))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: swipeBar)
            return abs(velocity.y) > abs(velocity.x) * 1.5
        }

        @objc private func titleSwiped(_ pan: UIPanGestureRecognizer) {
            switch pan.state {
            case .began:
                stallScrolls(under: pan)
            case .ended:
                releaseScrolls()
                let translation = pan.translation(in: swipeBar)
                guard LibrarySwipeInteraction.isTitleSwipe(horizontal: translation.x, vertical: translation.y) else { return }
                onTitleVerticalSwipe?()
            case .cancelled, .failed:
                releaseScrolls()
            default:
                break
            }
        }

        /// Scroll views under the title, and the offset each had before the
        /// drag. A swipe on the title switches library mode; the same touch
        /// also reaches the list behind the glass bar, and a mode switch that
        /// scrolls the library on its way out reads as two things at once.
        private var stalledScrolls: [(scroll: UIScrollView, offset: CGPoint)] = []

        private func stallScrolls(under pan: UIPanGestureRecognizer) {
            guard let host = swipeHost else { return }
            releaseScrolls()
            let point = pan.location(in: host)
            stalledScrolls = scrollViews(in: host, containing: point).map { (scroll: $0, offset: $0.contentOffset) }
            for entry in stalledScrolls {
                entry.scroll.panGestureRecognizer.isEnabled = false
                // The drag had already moved the list before the pan began.
                entry.scroll.setContentOffset(entry.offset, animated: false)
            }
        }

        private func releaseScrolls() {
            for entry in stalledScrolls { entry.scroll.panGestureRecognizer.isEnabled = true }
            stalledScrolls = []
        }

        private func scrollViews(in host: UIView, containing point: CGPoint) -> [UIScrollView] {
            var found: [UIScrollView] = []
            func walk(_ view: UIView) {
                guard !view.isHidden, view.alpha > 0.01 else { return }
                if let scroll = view as? UIScrollView,
                   scroll.convert(scroll.bounds, to: host).contains(point) {
                    found.append(scroll)
                }
                view.subviews.forEach(walk)
            }
            walk(host)
            return found
        }

        private func serifFont(size: CGFloat, weight: UIFont.Weight, style: UIFont.TextStyle) -> UIFont {
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            let descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
            return UIFontMetrics(forTextStyle: style).scaledFont(
                for: UIFont(descriptor: descriptor, size: size),
                compatibleWith: traitCollection
            )
        }
    }
}
#endif

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
            .appGlassButtonStyle(prominent: true)
            .tint(AppTheme.primaryFill)
            .foregroundStyle(AppTheme.onPrimaryFill)
    }

    /// Chrome shared by every settings screen: a large sentence-case title, a
    /// clear scroll surface and the app's light field behind it.
    func settingsScreen(_ title: String) -> some View {
        self
            .appNavigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
    }
}
