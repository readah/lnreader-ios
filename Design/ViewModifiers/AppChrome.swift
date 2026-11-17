import SwiftUI
import UIKit

/// Scoped to ContentView, deliberately not the onboarding host or UIAppearance.
enum ChromeAppearance {
    static let noLiquidGlassKey = "appearance.noLiquidGlass"
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
    func strokeBorderFallback(_ color: Color, lineWidth: CGFloat) -> some View {
        stroke(color, lineWidth: lineWidth).clipShape(self)
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
