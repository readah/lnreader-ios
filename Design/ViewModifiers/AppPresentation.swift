import SwiftUI

/// Our detents are plain values; no system sheet is created in classic mode.
enum AppPresentationDetent: Hashable {
    case medium, large, height(CGFloat), fraction(CGFloat)
    var native: PresentationDetent {
        switch self {
        case .medium: .medium
        case .large: .large
        case .height(let height): .height(height)
        case .fraction(let fraction): .fraction(fraction)
        }
    }
    func height(in available: CGFloat) -> CGFloat {
        switch self {
        case .medium: available * 0.52
        case .large: available * 0.94
        case .height(let height): min(height, available * 0.94)
        case .fraction(let fraction): available * min(max(fraction, 0.2), 0.94)
        }
    }
}
private struct AppDetentsKey: PreferenceKey {
    static let defaultValue: Set<AppPresentationDetent> = [.large]
    static func reduce(value: inout Set<AppPresentationDetent>, nextValue: () -> Set<AppPresentationDetent>) { value = nextValue() }
}

extension View {
    func appSheet<Sheet: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Sheet) -> some View {
        modifier(AppSheetModifier(isPresented: isPresented, onDismiss: onDismiss, sheet: content))
    }
    func appSheet<Item: Identifiable, Sheet: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping (Item) -> Sheet) -> some View {
        appSheet(isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }), onDismiss: onDismiss) {
            if let value = item.wrappedValue { content(value).id(value.id) }
        }
    }
    func appPopover<Popup: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Popup) -> some View {
        modifier(AppPopoverModifier(isPresented: isPresented, popup: content))
    }
    func appPresentationDetents(_ detents: Set<AppPresentationDetent>) -> some View {
        modifier(AppDetentsModifier(detents: detents))
    }
    func appPresentationCornerRadius(_ radius: CGFloat?) -> some View {
        modifier(AppCornerModifier(radius: radius))
    }
}
private struct AppDetentsModifier: ViewModifier {
    @Environment(\.noLiquidGlass) private var classic
    let detents: Set<AppPresentationDetent>
    @ViewBuilder func body(content: Content) -> some View {
        if classic { content.preference(key: AppDetentsKey.self, value: detents) }
        else { content.presentationDetents(Set(detents.map(\.native))) }
    }
}
private struct AppCornerModifier: ViewModifier {
    @Environment(\.noLiquidGlass) private var classic
    let radius: CGFloat?
    @ViewBuilder func body(content: Content) -> some View {
        if classic { content }
        else { content.presentationCornerRadius(radius) }
    }
}
private final class DeferredPopupAction { var action: (() -> Void)? }

private struct AppSheetModifier<Sheet: View>: ViewModifier {
    @Environment(\.noLiquidGlass) private var classic
    @Binding var isPresented: Bool
    var onDismiss: (() -> Void)?
    @ViewBuilder var sheet: () -> Sheet
    @State private var deferredAction = DeferredPopupAction()
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: classic ? .constant(false) : $isPresented, onDismiss: finished) {
                            sheet().appReveal()
                        }
            // A fullscreen transparent host supplies only a presentation context
            // and native dismiss environment. There is no UIKit sheet surface.
            .fullScreenCover(isPresented: classic ? $isPresented : .constant(false), onDismiss: finished) {
                ClassicSheet { sheet().appNavigationScreen() }
                    .environment(\.classicTabBarHeight, 0)
                    .environment(\.classicNavigation, nil)
                    .environment(\.appPopupAction, { action in
                        deferredAction.action = action
                        isPresented = false
                    })
                    .presentationBackground(.clear)
            }
    }
    private func finished() {
        let action = deferredAction.action
        deferredAction.action = nil
        action?()
        onDismiss?()
    }
}
private struct AppPopoverModifier<Popup: View>: ViewModifier {
    @Environment(\.noLiquidGlass) private var classic
    @Binding var isPresented: Bool
    @ViewBuilder var popup: () -> Popup
    func body(content: Content) -> some View {
        content
            .popover(isPresented: classic ? .constant(false) : $isPresented, content: popup)
            .appSheet(isPresented: classic ? $isPresented : .constant(false)) {
                popup().appPresentationDetents([.medium])
            }
    }
}

private struct ClassicSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var detents: Set<AppPresentationDetent> = [.large]
    @State private var selectedHeight: CGFloat?
    @State private var drag: CGFloat = 0
    @State private var appeared = false
    @State private var dismissDisabled = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            let available = geometry.size.height
            let heights = detents.map { $0.height(in: available) }.sorted()
            let height = min(selectedHeight ?? heights.first ?? available * 0.94, available * 0.94)
            ZStack(alignment: .bottom) {
                Color.black.opacity(appeared ? 0.4 : 0)
                    .ignoresSafeArea()
                    .onTapGesture { if !dismissDisabled { dismiss() } }
                    .accessibilityLabel("Dismiss sheet")
                    .accessibilityAddTraits(.isButton)
                VStack(spacing: 0) {
                    Capsule().fill(AppTheme.hairline)
                        .frame(width: 34, height: 4)
                        .frame(maxWidth: .infinity).frame(height: 22)
                        .contentShape(.rect)
                        .gesture(DragGesture().onChanged { drag = $0.translation.height }.onEnded { value in
                            let target = height - value.predictedEndTranslation.height
                            if target < (heights.first ?? height) * 0.6, !dismissDisabled { dismiss(); return }
                            withAnimation(AppMotion.reveal(reduceMotion: reduceMotion)) {
                                selectedHeight = heights.min(by: { abs($0 - target) < abs($1 - target) })
                                drag = 0
                            }
                        })
                        .accessibilityLabel("Sheet size")
                        .accessibilityAdjustableAction { direction in
                            let index = heights.firstIndex(where: { $0 >= height - 1 }) ?? 0
                            let next = direction == .increment ? min(index + 1, heights.count - 1) : max(index - 1, 0)
                            if heights.indices.contains(next) { selectedHeight = heights[next] }
                        }
                    content()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .appReveal()
                }
                .frame(height: max(160, height - max(-40, drag)))
                .padding(.bottom, geometry.safeAreaInsets.bottom)
                .background { FrostedSurface(shape: UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30), dense: true) }
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30))
                .offset(y: max(0, drag))
                .offset(y: appeared || reduceMotion ? 0 : 24)
                .ignoresSafeArea(edges: .bottom)
                .onPreferenceChange(AppDetentsKey.self) { detents = $0; selectedHeight = nil }
                .onPreferenceChange(AppDismissDisabledKey.self) { dismissDisabled = $0 }
            }
            .onAppear { withAnimation(AppMotion.reveal(reduceMotion: reduceMotion)) { appeared = true } }
        }
        .accessibilityAction(.escape) { if !dismissDisabled { dismiss() } }
    }
}

private struct PopupActionKey: EnvironmentKey {
    static let defaultValue: ((@escaping () -> Void) -> Void)? = nil
}
private struct PopupDismissKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}
extension EnvironmentValues {
    var appPopupAction: ((@escaping () -> Void) -> Void)? {
        get { self[PopupActionKey.self] }
        set { self[PopupActionKey.self] = newValue }
    }
    var appPopupDismiss: (() -> Void)? {
        get { self[PopupDismissKey.self] }
        set { self[PopupDismissKey.self] = newValue }
    }
}

/// Popup actions keep their native Button semantics, roles and disabled state,
/// but their activation and rendering are ours, including automatic dismissal.
struct ClassicPopupButtonStyle: PrimitiveButtonStyle {
    @Environment(\.appPopupDismiss) private var close
    @Environment(\.appPopupAction) private var performAfterDismissal
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role) {
            // Finish this presentation before an action opens another sheet or
            // changes navigation; otherwise UIKit drops competing presentations.
            if let performAfterDismissal {
                performAfterDismissal { configuration.trigger() }
            } else {
                configuration.trigger()
                close?()
            }
        } label: {
            configuration.label
                .font(Typography.body)
                .foregroundStyle(configuration.role == .destructive ? AppTheme.destructive : AppTheme.accent)
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                .padding(.horizontal, 14)
                .background(AppTheme.surface.opacity(0.4), in: .rect(cornerRadius: 16))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

struct ClassicPopup<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    var title: Text? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                title?.font(Typography.headline)
                Spacer()
                Button { dismiss() } label: { AppIcon(systemName: "xmark", size: 15) }
                    .buttonStyle(ClassicChromeButtonStyle())
                    .accessibilityLabel("Close")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8, content: content)
                    .buttonStyle(ClassicPopupButtonStyle())
                    .environment(\.appPopupDismiss, { dismiss() })
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(16)
        .appPresentationDetents([.medium, .large])
    }
}
