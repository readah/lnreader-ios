import SwiftUI
import UIKit

/// Scoped to ContentView, deliberately not the onboarding host or UIAppearance.
enum ChromeAppearance {
    static let noLiquidGlassKey = "appearance.noLiquidGlass"
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            .foregroundStyle(configuration.role == .destructive ? AppTheme.destructive : (prominent ? AppTheme.onPrimaryFill : AppTheme.accent))
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(AppMotion.gentle(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

/// Material controls must not be collected into a Liquid Glass rendering group.
struct AppGlassEffectContainer<Content: View>: View {
    @Environment(\.noLiquidGlass) private var classic
    var spacing: CGFloat? = nil
    @ViewBuilder var content: () -> Content

    @ViewBuilder var body: some View {
        if classic { content() }
        else { GlassEffectContainer(spacing: spacing, content: content) }
    }
}

struct ClassicTabBar: View {
    let selected: AppTab
    let select: (AppTab) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Namespace private var selection

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
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 50)
                    .padding(.vertical, 3)
                    .background {
                        if selected == tab {
                            RoundedRectangle(cornerRadius: 21, style: .continuous)
                                .fill(.primary.opacity(0.10))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 21, style: .continuous)
                                        .strokeBorder(AppTheme.hairline, lineWidth: 0.5)
                                }
                                .matchedGeometryEffect(id: "tab", in: selection)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected == tab ? .isSelected : [])
            }
        }
        .padding(6)
        .background { FrostedSurface(shape: RoundedRectangle(cornerRadius: 28, style: .continuous), dense: true) }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .animation(AppMotion.tabSwitch(reduceMotion: reduceMotion), value: selected)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab bar")
    }
}

struct ClassicTabBarHiddenKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

struct AppTabChrome: ViewModifier {
    @Environment(\.noLiquidGlass) private var classic
    func body(content: Content) -> some View {
        content.toolbarVisibility(classic ? .hidden : .automatic, for: .tabBar)
    }
}
