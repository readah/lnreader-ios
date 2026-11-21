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

/// Opaque under Reduce Transparency, the sheet's thick material otherwise,
/// with the cover tint washed over it. The sheet's own glass never shows
/// through because this is the presentation background.
private struct AppSheetBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.coverTint) private var coverTint
    @Environment(\.coverTintStrength) private var strength

    var body: some View {
        ZStack {
            Rectangle()
                .fill(reduceTransparency ? AnyShapeStyle(AppTheme.surface) : AnyShapeStyle(Material.thickMaterial))
            if let coverTint, strength > 0 {
                coverTint.opacity(strength * 0.16)
            }
        }
        .ignoresSafeArea()
    }
}

/// Automatically sizes short informational/alert sheets to their content height.
private struct FitContentDetent: ViewModifier {
    @State private var measuredHeight: CGFloat = 220

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if height > 0 { measuredHeight = height }
            }
            .presentationDetents([.height(min(measuredHeight, 560)), .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(18) // Crisp iOS 18 sheet radius
    }
}

extension View {
    func appCompactSheetDetent() -> some View {
        modifier(FitContentDetent())
    }
}

// MARK: - Sheet Header

/// Mathematically centered sheet header with borderless iOS 18 actions. The
/// title sits in a ZStack, so it stays dead-center even when the leading and
/// trailing slots differ in width.
struct ClassicSheetHeader<Leading: View, Trailing: View>: View {
    let title: Text
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    init(
        title: Text,
        @ViewBuilder leading: @escaping () -> Leading = { EmptyView() },
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        ZStack {
            // Always dead-center; horizontal padding reserves room for side actions.
            title
                .font(Typography.navigationTitle)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 56)

            HStack {
                leading()
                Spacer(minLength: 0)
                trailing()
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.hairline.opacity(0.45))
                .frame(height: 0.5)
        }
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
        let isPushed = appNavigationDepth > 0
        let close = appSheetClose
        return AppDismissAction {
            if isPushed { native() }
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
/// Text is monochrome except for the one reserved destructive role.
struct ClassicPopupButtonStyle: PrimitiveButtonStyle {
    @Environment(\.appPopupDismiss) private var close
    @Environment(\.appPopupAction) private var performAfterDismissal
    @Environment(\.appCompactRow) private var compact
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let isDestructive = configuration.role == .destructive
        let isCancel = configuration.role == .cancel
        // Exact concentric match with `AppPopupMenuSurface`: 14pt container
        // radius minus its 4pt row gutter. A square-ish highlight inside a
        // rounded card is what reads as misaligned.
        let radius: CGFloat = AppPopupMenuMetrics.rowCornerRadius

        Button {
            Haptics.shared.selection()
            if let performAfterDismissal, !compact {
                performAfterDismissal { configuration.trigger() }
            } else {
                close?()
                configuration.trigger()
            }
        } label: {
            HStack(spacing: 10) {
                configuration.label
                    .font(compact ? Typography.subheadline : Typography.body.weight(isCancel ? .regular : .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
            }
            .foregroundStyle(
                isDestructive ? AppTheme.destructive :
                (isCancel ? .secondary : .primary)
            )
            .padding(.horizontal, compact ? 12 : 14)
            .padding(.vertical, compact ? 9 : 13)
            .frame(maxWidth: .infinity, minHeight: compact ? 38 : 48, alignment: .leading)
            .background {
                if !compact {
                    ClassicSurface(
                        shape: RoundedRectangle(cornerRadius: radius, style: .continuous),
                        elevation: .card,
                        tint: isDestructive ? AppTheme.destructive.opacity(0.10) : nil
                    )
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .buttonStyle(ClassicPopupPressStyle(compact: compact, radius: radius))
        .opacity(enabled ? 1 : 0.38)
    }
}

private struct ClassicPopupPressStyle: ButtonStyle {
    let compact: Bool
    let radius: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if compact, configuration.isPressed {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill((colorScheme == .dark ? Color.white : Color.black).opacity(0.08))
                }
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(ClassicMotion.micro(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

struct ClassicPopup<Content: View>: View {
    @Environment(\.appDismiss) private var dismiss
    var title: Text? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                ClassicSheetHeader(title: title) {
                    EmptyView()
                } trailing: {
                    Button {
                        Haptics.shared.selection()
                        dismiss()
                    } label: {
                        AppIcon(systemName: "xmark", size: 16)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                            .contentShape(.rect)
                    }
                    .buttonStyle(AppPlainButtonStyle())
                    .accessibilityLabel("Close")
                }
                .classicSheetReveal(offsetY: 4, blur: 4, delay: 0)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8, content: content)
                    .buttonStyle(ClassicPopupButtonStyle())
                    .environment(\.appPopupDismiss, { dismiss() })
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .classicSheetReveal(offsetY: 8, blur: 6, delay: 0.025)
        }
        .appCompactSheetDetent()
    }
}
