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
        modifier(AppItemSheetModifier(item: item, onDismiss: onDismiss, sheet: content))
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

private struct AppItemSheetModifier<Item: Identifiable, Sheet: View>: ViewModifier {
    @Binding var item: Item?
    var onDismiss: (() -> Void)?
    @ViewBuilder var sheet: (Item) -> Sheet
    @State private var retainedItem: Item?

    func body(content: Content) -> some View {
        content.appSheet(isPresented: Binding(get: { item != nil }, set: { if !$0 { item = nil } }), onDismiss: {
            retainedItem = nil
            onDismiss?()
        }) {
            if let value = item ?? retainedItem { sheet(value).id(value.id) }
        }
        .onChange(of: item?.id, initial: true) { _, _ in
            if let item { retainedItem = item }
        }
    }
}

private struct AppSheetModifier<Sheet: View>: ViewModifier {
    @Environment(\.noLiquidGlass) private var classic
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isPresented: Bool
    var onDismiss: (() -> Void)?
    @ViewBuilder var sheet: () -> Sheet
    @State private var deferredAction = DeferredPopupAction()
    @State private var hostPresented = false
    @State private var visible = false
    @State private var closing = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: classic ? .constant(false) : $isPresented, onDismiss: finished) {
                sheet()
                    .environment(\.appPressFeedbackHosted, false)
            }
            // UIKit supplies the presentation context only; its transition is
            // disabled so the panel has exactly one arrival and departure.
            .fullScreenCover(isPresented: $hostPresented, onDismiss: finished) {
                ClassicSheet(visible: visible, close: close) { sheet().appNavigationScreen() }
                    .environment(\.appPressFeedbackHosted, false)
                    .environment(\.classicTabBarHeight, 0)
                    .environment(\.classicNavigation, nil)
                    .environment(\.appSheetClose, close)
                    .environment(\.appPopupAction, { action in
                        deferredAction.action = action
                        close()
                    })
                    .presentationBackground(.clear)
                    .task {
                        do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                        guard !closing else { return }
                        withAnimation(AppMotion.reveal(reduceMotion: reduceMotion)) { visible = true }
                    }
            }
            .onChange(of: isPresented, initial: true) { _, presented in
                guard classic else { return }
                if presented {
                    guard !hostPresented else { return }
                    closing = false
                    visible = false
                    setHost(true)
                } else if hostPresented { close() }
            }
    }

    private func setHost(_ presented: Bool) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { hostPresented = presented }
    }

    private func close() {
        guard hostPresented, !closing else { return }
        closing = true
        withAnimation(AppMotion.reveal(reduceMotion: reduceMotion), completionCriteria: .removed) {
            visible = false
        } completion: {
            setHost(false)
        }
    }

    private func finished() {
        isPresented = false
        visible = false
        closing = false
        let action = deferredAction.action
        deferredAction.action = nil
        onDismiss?()
        action?()
    }
}
private struct AppPopoverModifier<Popup: View>: ViewModifier {
    @Environment(\.noLiquidGlass) private var classic
    @Binding var isPresented: Bool
    @ViewBuilder var popup: () -> Popup
    func body(content: Content) -> some View {
        content
            .popover(isPresented: classic ? .constant(false) : $isPresented) {
                            popup().environment(\.appPressFeedbackHosted, false)
                        }
            .appSheet(isPresented: classic ? $isPresented : .constant(false)) {
                popup().appPresentationDetents([.medium])
            }
    }
}

private struct ClassicSheet<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.springUnblurMotion) private var springUnblurMotion
    let visible: Bool
    let close: () -> Void
    @State private var detents: Set<AppPresentationDetent> = [.large]
    @State private var selectedDetent: AppPresentationDetent?
    @GestureState private var drag: CGFloat = 0
    @State private var dismissalOffset: CGFloat = 24
    @State private var dismissDisabled = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            let available = geometry.size.height
            let ordered = detents.sorted { $0.height(in: available) < $1.height(in: available) }
            let selected = selectedDetent.flatMap { detents.contains($0) ? $0 : nil } ?? ordered.first ?? .large
            let height = max(160, selected.height(in: available))
            ZStack(alignment: .bottom) {
                Color.black.opacity(visible ? 0.4 : 0)
                    .ignoresSafeArea()
                    .onTapGesture { if !dismissDisabled { close() } }
                    .accessibilityLabel("Dismiss sheet")
                    .accessibilityAddTraits(.isButton)
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        Capsule().fill(AppTheme.hairline)
                        .frame(width: 34, height: 4)
                        .frame(maxWidth: .infinity).frame(height: 22)
                        .contentShape(.rect)
                        .accessibilityLabel("Sheet size")
                        .accessibilityAdjustableAction { direction in
                            let index = ordered.firstIndex(of: selected) ?? 0
                            let next = direction == .increment ? min(index + 1, ordered.count - 1) : max(index - 1, 0)
                            if ordered.indices.contains(next) {
                                withAnimation(AppMotion.reveal(reduceMotion: reduceMotion)) { selectedDetent = ordered[next] }
                            }
                        }
                    }
                .frame(height: height)
                .padding(.bottom, geometry.safeAreaInsets.bottom)
                .background { OnboardingBackdrop() }
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30))
                .blur(radius: springUnblurMotion && !reduceMotion && !visible ? 10 : 0)
                .scaleEffect(springUnblurMotion && !reduceMotion && !visible ? 0.94 : 1, anchor: .bottom)
                .opacity(visible ? 1 : 0)
                .offset(y: visible ? max(0, drag) : (reduceMotion ? 0 : dismissalOffset))
                .simultaneousGesture(DragGesture(minimumDistance: 12, coordinateSpace: .named("sheetPanel"))
                    .updating($drag) { value, drag, _ in
                        guard value.startLocation.y < 82, abs(value.translation.height) > abs(value.translation.width) else { return }
                        drag = max(-30, value.translation.height)
                    }
                    .onEnded { value in
                        guard value.startLocation.y < 82, abs(value.translation.height) > abs(value.translation.width) else { return }
                        let decision = SheetDragDecision.resolve(translation: value.translation.height,
                                                                 predicted: value.predictedEndTranslation.height,
                                                                 canDismiss: !dismissDisabled)
                        withAnimation(AppMotion.reveal(reduceMotion: reduceMotion)) {
                            switch decision {
                            case .dismiss:
                                dismissalOffset = max(24, value.translation.height + 24)
                                close()
                            case .expand: selectedDetent = ordered.last
                            case .restore: break
                            }
                        }
                    })
                .coordinateSpace(name: "sheetPanel")
                .animation(AppMotion.reveal(reduceMotion: reduceMotion), value: drag == 0)
                .ignoresSafeArea(edges: .bottom)
                .onPreferenceChange(AppDetentsKey.self) { if !$0.isEmpty { detents = $0 } }
                .onPreferenceChange(AppDismissDisabledKey.self) { dismissDisabled = $0 }
            }
            .allowsHitTesting(visible)
        }
        .accessibilityAction(.escape) { if !dismissDisabled { close() } }
    }
}

private struct SheetCloseKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

struct AppDismissAction {
    let perform: () -> Void
    func callAsFunction() { perform() }
}

private struct PopupActionKey: EnvironmentKey {
    static let defaultValue: ((@escaping () -> Void) -> Void)? = nil
}
private struct PopupDismissKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}
extension EnvironmentValues {
    fileprivate var appSheetClose: (() -> Void)? {
        get { self[SheetCloseKey.self] }
        set { self[SheetCloseKey.self] = newValue }
    }

    /// Pushed screens still pop; only a sheet's root uses the animated exit.
    var appDismiss: AppDismissAction {
        let native = dismiss
        let navigation = classicNavigation
        let close = appSheetClose
        return AppDismissAction {
            if navigation?.canGoBack == true { native() }
            else if let close { close() }
            else { native() }
        }
    }

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
        .buttonStyle(AppPlainButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

struct ClassicPopup<Content: View>: View {
    @Environment(\.appDismiss) private var dismiss
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
