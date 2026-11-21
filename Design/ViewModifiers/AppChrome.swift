import SwiftUI
import UIKit

/// Scoped to ContentView, deliberately not the onboarding host or UIAppearance.
enum ChromeAppearance {
    static let noLiquidGlassKey = "appearance.noLiquidGlass"
    static let systemFormsKey = "appearance.systemForms"
    static let classicTabBarHeight: CGFloat = 64
}

private struct AppPressFeedbackHostedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var appPressFeedbackHosted: Bool {
        get { self[AppPressFeedbackHostedKey.self] }
        set { self[AppPressFeedbackHostedKey.self] = newValue }
    }
}

private struct AppPressFeedback: ViewModifier {
    @Environment(\.noLiquidGlass) private var classic
    @Environment(\.appFormRow) private var formRow
    @Environment(\.appPressFeedbackHosted) private var hosted
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    let pressed: Bool
    let always: Bool

    private var active: Bool { pressed && enabled && !reduceMotion && !hosted && (always || classic || formRow) }
    func body(content: Content) -> some View {
        content
            .scaleEffect(active ? 0.97 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82), value: active)
    }
}

extension View {
    func appPressFeedback(_ pressed: Bool, always: Bool = false) -> some View {
        modifier(AppPressFeedback(pressed: pressed, always: always))
    }
}

/// Press feedback uses the native `ButtonStyle.isPressed` value. Attaching a
/// gesture recognizer to observe a touch competes with the enclosing
/// ScrollView's pan and makes rows unscrollable, so no custom gesture is used.
struct AppAutomaticButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .appPressFeedback(configuration.isPressed)
    }
}
struct AppPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .appPressFeedback(configuration.isPressed)
    }
}
struct AppBorderlessButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .appPressFeedback(configuration.isPressed)
    }
}

/// Applied below ContentView's `noLiquidGlass` environment so glass mode keeps
/// its native automatic button appearance; only classic rows get the adapter.
struct AppRootButtonStyle: ViewModifier {
    @Environment(\.noLiquidGlass) private var classic
    func body(content: Content) -> some View {
        if classic { content.buttonStyle(AppAutomaticButtonStyle()) }
        else { content }
    }
}

private struct NoLiquidGlassKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var noLiquidGlass: Bool {
        get { self[NoLiquidGlassKey.self] }
        set { self[NoLiquidGlassKey.self] = newValue }
    }
}

struct FrostedBackdrop: View {
    var dense = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        Rectangle()
            .fill(reduceTransparency ? AnyShapeStyle(AppTheme.surface) : AnyShapeStyle(dense ? Material.thin : Material.ultraThin))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Classic, non-refracting material. Decorations never intercept the control.
struct FrostedSurface<S: Shape>: View {
    let shape: S
    var tint: Color? = nil
    var dense = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        shape
            .fill(reduceTransparency ? AnyShapeStyle(AppTheme.surface) : AnyShapeStyle(dense ? Material.thin : Material.ultraThin))
            .overlay { shape.fill(tint ?? .clear) }
            .overlay {
                shape.strokeBorderFallback(
                    AppTheme.hairline.opacity(contrast == .increased ? 1 : 0.65),
                    lineWidth: contrast == .increased ? 1 : 0.5
                )
            }
            .shadow(color: .black.opacity(dense ? 0.14 : 0.10), radius: dense ? 18 : 8, x: 0, y: 4)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private extension Shape {
    func strokeBorderFallback<S: ShapeStyle>(_ style: S, lineWidth: CGFloat) -> some View {
        stroke(style, lineWidth: lineWidth).clipShape(self)
    }
}

// MARK: - Classic Elevation & Surface System

/// Material ladder for the non-Liquid-Glass surfaces. On OLED black a drop
/// shadow disappears, so depth is carried by material density and a crisp
/// 0.5pt hairline instead.
enum ClassicElevation {
    /// Scrolled nav bars, tab bar, bottom toolbars.
    case chromeBar
    /// Sheets and in-popups.
    case sheet
    /// Floating anchored popovers & context menus.
    case popover
    /// Flat nested card inside a sheet (avoids double-material muddiness).
    case card

    var material: Material {
        switch self {
        case .chromeBar: .thinMaterial
        case .sheet: .thickMaterial
        case .popover: .regularMaterial
        case .card: .ultraThinMaterial
        }
    }
}

struct ClassicSurface<S: Shape>: View {
    let shape: S
    var elevation: ClassicElevation = .card
    var tint: Color? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        Group {
            if elevation == .card {
                shape.fill(isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.045))
            } else if reduceTransparency {
                shape.fill(AppTheme.surface)
            } else {
                shape.fill(elevation.material)
            }
        }
        .overlay {
            if let tint { shape.fill(tint) }
        }
        .overlay {
            shape.strokeBorderFallback(
                (isDark ? Color.white : Color.black).opacity(
                    contrast == .increased ? 0.35 : (elevation == .popover ? 0.14 : 0.09)
                ),
                lineWidth: contrast == .increased ? 1 : 0.5
            )
        }
        .shadow(
            color: .black.opacity(elevation == .popover ? (isDark ? 0.32 : 0.12) : 0),
            radius: elevation == .popover ? 18 : 0,
            x: 0,
            y: elevation == .popover ? 8 : 0
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Unified Spring + Unblur Motion

enum ClassicMotion {
    static func micro(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.14) : .spring(duration: 0.24, bounce: 0.12)
    }

    static func reveal(reduceMotion: Bool, delay: Double = 0) -> Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .spring(duration: 0.32, bounce: 0.10).delay(delay)
    }

    static func sheetContent(reduceMotion: Bool, delay: Double = 0) -> Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .spring(duration: 0.36, bounce: 0.08).delay(delay)
    }
}

private struct ClassicUnblurAppear: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let scale: CGFloat
    let offsetY: CGFloat
    let blurRadius: CGFloat
    let delay: Double
    let isSheet: Bool
    @State private var appeared = false

    func body(content: Content) -> some View {
        let animation = isSheet
            ? ClassicMotion.sheetContent(reduceMotion: reduceMotion, delay: delay)
            : ClassicMotion.reveal(reduceMotion: reduceMotion, delay: delay)

        content
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared || reduceMotion ? 1 : scale)
            .offset(y: appeared || reduceMotion ? 0 : offsetY)
            .blur(radius: appeared || reduceMotion ? 0 : blurRadius)
            .onAppear {
                withAnimation(animation) { appeared = true }
            }
    }
}

extension View {
    /// Spring + unblur entrance for popovers, menus, and inline chrome.
    func classicReveal(scale: CGFloat = 0.96, offsetY: CGFloat = -4, blur: CGFloat = 6, delay: Double = 0) -> some View {
        modifier(ClassicUnblurAppear(scale: scale, offsetY: offsetY, blurRadius: blur, delay: delay, isSheet: false))
    }

    /// Spring + unblur entrance for sheet/popup content blocks.
    func classicSheetReveal(offsetY: CGFloat = 8, blur: CGFloat = 6, delay: Double = 0) -> some View {
        modifier(ClassicUnblurAppear(scale: 0.99, offsetY: offsetY, blurRadius: blur, delay: delay, isSheet: true))
    }
}

private struct AppGlassModifier<S: Shape>: ViewModifier {
    @Environment(\.noLiquidGlass) private var classic
    let glass: Glass
    let shape: S
    let tint: Color?

    @ViewBuilder func body(content: Content) -> some View {
        if classic {
            content.background { FrostedSurface(shape: shape, tint: tint) }
        } else {
            content.glassEffect(glass, in: shape)
        }
    }
}

extension View {
    func appGlassEffect<S: Shape>(_ glass: Glass = .regular, in shape: S, frostTint: Color? = nil) -> some View {
        modifier(AppGlassModifier(glass: glass, shape: shape, tint: frostTint))
    }

    func appGlassButtonStyle(prominent: Bool = false) -> some View {
        modifier(AppGlassButtonModifier(prominent: prominent))
    }

    func appNavigationChrome() -> some View {
        modifier(AppNavigationChrome())
    }

}

private struct AppGlassButtonModifier: ViewModifier {
    @Environment(\.noLiquidGlass) private var classic
    let prominent: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if classic {
            content.buttonStyle(FrostedButtonStyle(prominent: prominent))
        } else if prominent {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.glass)
        }
    }
}

struct FrostedButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, controlSize == .large ? 22 : 16)
            .padding(.vertical, controlSize == .large ? 14 : 10)
            .frame(minHeight: 44)
            .background {
                if prominent {
                    Capsule().fill(configuration.role == .destructive ? AppTheme.destructive : AppTheme.primaryFill)
                } else {
                    FrostedSurface(shape: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            .foregroundStyle(prominent ? (configuration.role == .destructive ? Color.white : AppTheme.onPrimaryFill) : (configuration.role == .destructive ? AppTheme.destructive : AppTheme.accent))
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.4)
            .appPressFeedback(configuration.isPressed, always: true)
    }
}

/// Material controls must not be collected into a Liquid Glass rendering group.
struct AppGlassEffectContainer<Content: View>: View {
    @Environment(\.noLiquidGlass) private var classic
    var spacing: CGFloat? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group {
            if classic { content() }
            else { GlassEffectContainer(spacing: spacing, content: content) }
        }
    }
}

struct ClassicTabBar: View {
    let selected: AppTab
    let select: (AppTab) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    Haptics.shared.selection()
                    select(tab)
                } label: {
                    VStack(spacing: 5) {
                        AppIcon(systemName: tab.icon, size: 21)
                            .frame(height: 24)
                        if !dynamicTypeSize.isAccessibilitySize {
                            Text(tab.title).font(Typography.small.weight(.semibold))
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                    }
                    .foregroundStyle(.primary.opacity(selected == tab ? 1 : 0.55))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 50)
                    .padding(.vertical, 3)
                    .contentShape(.rect)
                }
                .buttonStyle(AppPlainButtonStyle())
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected == tab ? .isSelected : [])
            }
        }
        .padding(.horizontal, 10)
        .frame(height: ChromeAppearance.classicTabBarHeight)
        .background {
            FrostedBackdrop(dense: true).ignoresSafeArea(edges: .bottom)
        }
        .animation(AppMotion.tabSwitch(reduceMotion: reduceMotion), value: selected)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab bar")
    }
}

struct ClassicTabBarHiddenKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

private struct ClassicTabBarHeightKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues {
    var classicTabBarHeight: CGFloat {
        get { self[ClassicTabBarHeightKey.self] }
        set { self[ClassicTabBarHeightKey.self] = newValue }
    }
}

struct AppTabChrome: ViewModifier {
    @Environment(\.noLiquidGlass) private var classic
    func body(content: Content) -> some View {
        content
            .toolbarVisibility(classic ? .hidden : .automatic, for: .tabBar)
            .environment(\.classicTabBarHeight, classic ? ChromeAppearance.classicTabBarHeight : 0)
    }
}

// MARK: - Progressive top blur

/// The bottom edge, in global coordinates, of the header content scrolls
/// under: the kind slider on Browse and the Library. Rows compare their own
/// global frame against it, so a default of 0 keeps every row sharp on
/// screens that pin nothing above their content.
private struct ProgressiveBlurBandKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var progressiveBlurBand: CGFloat {
        get { self[ProgressiveBlurBandKey.self] }
        set { self[ProgressiveBlurBandKey.self] = newValue }
    }
}

/// Rows blur out progressively as they scroll up under a pinned header, the
/// same fade the Minimal library's rows use under their title
/// (`MinimalLibraryRow.fade`). The work happens in `visualEffect`, so
/// scrolling never re-evaluates the row's body.
private struct ProgressiveTopBlur: ViewModifier {
    /// How far into the header band a row must climb before the blur is total.
    nonisolated private static let span: CGFloat = 56

    @Environment(\.progressiveBlurBand) private var bandBottom

    func body(content: Content) -> some View {
        // Copied to a local so the `visualEffect` closure, which is not on the
        // main actor, never reads the isolated property.
        let band = bandBottom
        return content.visualEffect { view, proxy in
            let fade = max(0, min(1, (band - proxy.frame(in: .global).minY) / Self.span))
            return view
                .blur(radius: fade * 8)
                .opacity(1 - fade * 0.45)
        }
    }
}

extension View {
    /// Blurs the view out as it scrolls up under the header named by
    /// ``EnvironmentValues/progressiveBlurBand``. Apply it per row or cell,
    /// not to a whole list: the fade comes from each view's own frame.
    func progressiveTopBlur() -> some View {
        modifier(ProgressiveTopBlur())
    }
}
