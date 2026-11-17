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
    let detents: Set<AppPresentationDetent>
    func body(content: Content) -> some View {
        content.presentationDetents(Set(detents.map(\.native)))
    }
}
private struct AppCornerModifier: ViewModifier {
    let radius: CGFloat?
    func body(content: Content) -> some View {
        content.presentationCornerRadius(radius)
    }
}
private final class DeferredPopupAction { var action: (() -> Void)? }

/// Opaque under Reduce Transparency, ultra-thin otherwise. The sheet's own
/// glass never shows through because this is the presentation background.
private struct AppSheetBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        Rectangle()
            .fill(reduceTransparency ? AnyShapeStyle(AppTheme.surface) : AnyShapeStyle(Material.thick))
            .ignoresSafeArea()
    }
}

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

/// Sheets are native iOS presentations in both modes. Only the surface is
/// ours: an ultra-thin background instead of system glass, non-interactive
/// dismissal, and our own serif title, buttons and content. Deferred popup
/// actions still run only after the sheet is gone.
private struct AppSheetModifier<Sheet: View>: ViewModifier {
    @Binding var isPresented: Bool
    var onDismiss: (() -> Void)?
    @ViewBuilder var sheet: () -> Sheet
    @State private var deferredAction = DeferredPopupAction()

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, onDismiss: finished) {
                SheetHost(deferred: deferredAction) { sheet() }
            }
    }

    private func finished() {
        isPresented = false
        let action = deferredAction.action
        deferredAction.action = nil
        onDismiss?()
        action?()
    }
}

private struct SheetHost<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let deferred: DeferredPopupAction
    @ViewBuilder var content: () -> Content
    @State private var dismissDisabled = false

    var body: some View {
        content()
            .environment(\.appPressFeedbackHosted, false)
            .environment(\.classicTabBarHeight, 0)
            .environment(\.classicNavigation, nil)
            .environment(\.appNavigationDepth, 0)
            .environment(\.appSheetClose, { dismiss() })
            .environment(\.appPopupAction, { action in
                deferred.action = action
                dismiss()
            })
            .appNavigationScreen()
            .interactiveDismissDisabled(dismissDisabled)
            .presentationBackground { AppSheetBackground() }
            .onPreferenceChange(AppDismissDisabledKey.self) { dismissDisabled = $0 }
    }
}
private struct AppPopoverModifier<Popup: View>: ViewModifier {
    @Environment(\.noLiquidGlass) private var classic
    @Binding var isPresented: Bool
    @ViewBuilder var popup: () -> Popup
    func body(content: Content) -> some View {
        content
            .popover(isPresented: $isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: nil) {
                popup()
                    .environment(\.appPressFeedbackHosted, false)
                    .appRevealQuick(edge: .top)
                    #if os(iOS)
                    .presentationCompactAdaptation(.popover)
                    #endif
            }
    }
}

struct SheetCloseKey: EnvironmentKey {
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
    var appSheetClose: (() -> Void)? {
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
    @Environment(\.appCompactRow) private var compact
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
                .frame(maxWidth: .infinity, minHeight: compact ? 44 : 46, alignment: .leading)
                .padding(.horizontal, compact ? 10 : 14)
                .background {
                    if !compact {
                        AppTheme.surface.opacity(0.4).clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
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
        VStack(alignment: .leading, spacing: 16) {
            if let title {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    title.font(Typography.navigationTitle)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button { dismiss() } label: { AppIcon(systemName: "xmark", size: 15) }
                        .buttonStyle(ClassicChromeButtonStyle())
                        .accessibilityLabel("Close")
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8, content: content)
                    .buttonStyle(ClassicPopupButtonStyle())
                    .environment(\.appPopupDismiss, { dismiss() })
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .appPresentationDetents([.medium, .large])
    }
}
