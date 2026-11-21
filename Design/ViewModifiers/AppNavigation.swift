import SwiftUI
import UIKit

// The system stack is a routing engine only in classic mode. None of its bars,
// back buttons, toolbar backgrounds or search chrome are displayed.
struct AppNavigationStack<Root: View>: View {
    @Environment(\.noLiquidGlass) private var classic
    private let path: Binding<NavigationPath>?
    private let root: () -> Root
    @State private var navigation = ClassicNavigationState()

    init(@ViewBuilder root: @escaping () -> Root) {
        path = nil
        self.root = root
    }
    init(path: Binding<NavigationPath>, @ViewBuilder root: @escaping () -> Root) {
        self.path = path
        self.root = root
    }

    var body: some View {
        // One bridge per stack, sitting in the root's background: it outlives
        // every push, so the interactive pop delegate is never left dangling by
        // a screen that popped and deallocated.
        let stackRoot = root().background {
            ClassicInteractivePopBridge(enabled: classic)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }

        Group {
            if let path {
                NavigationStack(path: path) { stackRoot }
            } else {
                NavigationStack { stackRoot }
            }
        }
        .environment(\.classicNavigation, navigation)
        .onAppear { syncPop() }
    }

    private func syncPop() {
        guard let path else { navigation.pop = nil; return }
        navigation.pop = {
            guard !path.wrappedValue.isEmpty else { return false }
            path.wrappedValue.removeLast()
            return true
        }
    }
}

struct AppPathNavigationStack<Data: MutableCollection & RandomAccessCollection & RangeReplaceableCollection, Root: View>: View where Data.Element: Hashable {
    @Environment(\.noLiquidGlass) private var classic
    @Binding var path: Data
    @ViewBuilder var root: () -> Root
    @State private var navigation = ClassicNavigationState()

    var body: some View {
        NavigationStack(path: $path) {
            root().background {
                ClassicInteractivePopBridge(enabled: classic)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
        }
        .environment(\.classicNavigation, navigation)
        .onAppear {
            navigation.pop = {
                guard !path.isEmpty else { return false }
                path.removeLast()
                return true
            }
        }
    }
}

struct AppNavigationLink<Destination: View, Label: View>: View {
    @Environment(\.appFormRow) private var formRow
    @ViewBuilder var destination: () -> Destination
    @ViewBuilder var label: () -> Label
    var body: some View {
        NavigationLink { destination().appPushedScreen() } label: {
            HStack(spacing: 12) {
                label()
                if formRow {
                    Spacer(minLength: 8)
                    AppIcon(systemName: "chevron.right", size: 13)
                        .accessibilityHidden(true)
                }
            }
        }
    }
    init(@ViewBuilder destination: @escaping () -> Destination, @ViewBuilder label: @escaping () -> Label) {
        self.destination = destination; self.label = label
    }
    init(destination: Destination, @ViewBuilder label: @escaping () -> Label) {
        self.destination = { destination }; self.label = label
    }
}
extension AppNavigationLink where Label == Text {
    init(_ title: String, @ViewBuilder destination: @escaping () -> Destination) {
        self.destination = destination; self.label = { Text(title) }
    }
}

@Observable final class ClassicNavigationState {
    /// Fallback pop for path-backed stacks, used only when a destination was not
    /// wrapped in `appPushedScreen()` and so has no dismiss action of its own.
    var pop: (() -> Bool)?
}
private struct ClassicNavigationKey: EnvironmentKey {
    static let defaultValue: ClassicNavigationState? = nil
}
extension EnvironmentValues {
    var classicNavigation: ClassicNavigationState? {
        get { self[ClassicNavigationKey.self] }
        set { self[ClassicNavigationKey.self] = newValue }
    }
}

struct AppScreenTitleKey: PreferenceKey {
    static let defaultValue: Text? = nil
    static func reduce(value: inout Text?, nextValue: () -> Text?) {
        if let next = nextValue() { value = next }
    }
}
struct AppScreenTitleEnvironmentKey: EnvironmentKey {
    static let defaultValue: Text? = nil
}
extension EnvironmentValues {
    var appScreenTitle: Text? {
        get { self[AppScreenTitleEnvironmentKey.self] }
        set { self[AppScreenTitleEnvironmentKey.self] = newValue }
    }
}
struct AppTitleSwipeAction: Equatable {
    let id: UUID
    let perform: () -> Void
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}
struct AppTitleSwipeKey: PreferenceKey {
    static let defaultValue: AppTitleSwipeAction? = nil
    static func reduce(value: inout AppTitleSwipeAction?, nextValue: () -> AppTitleSwipeAction?) {
        if let next = nextValue() { value = next }
    }
}
struct AppTitleSwipePreference: ViewModifier {
    @State private var id = UUID()
    let action: (() -> Void)?
    func body(content: Content) -> some View {
        content.preference(key: AppTitleSwipeKey.self, value: action.map { .init(id: id, perform: $0) })
    }
}

enum AppToolbarRegion: Hashable { case leading, trailing, bottom }

enum AppToolbarPlacement {
    case automatic, primaryAction, topBarLeading, topBarTrailing, cancellationAction, confirmationAction, bottomBar
    var native: ToolbarItemPlacement {
        switch self {
        case .automatic: .automatic
        case .primaryAction: .primaryAction
        case .topBarLeading: .topBarLeading
        case .topBarTrailing: .topBarTrailing
        case .cancellationAction: .cancellationAction
        case .confirmationAction: .confirmationAction
        case .bottomBar: .bottomBar
        }
    }
    var region: AppToolbarRegion {
        if self == .bottomBar { return .bottom }
        return self == .topBarLeading || self == .cancellationAction ? .leading : .trailing
    }
}

protocol AppToolbarContent {
    associatedtype Native: ToolbarContent
    associatedtype Classic: View
    @ToolbarContentBuilder var native: Native { get }
    @ViewBuilder func classic(in region: AppToolbarRegion) -> Classic
    var regions: Set<AppToolbarRegion> { get }
}
struct AppToolbarItem<Content: View>: AppToolbarContent {
    var placement: AppToolbarPlacement = .automatic
    @ViewBuilder var content: () -> Content
    var native: some ToolbarContent { ToolbarItem(placement: placement.native, content: content) }
    var regions: Set<AppToolbarRegion> { [placement.region] }
    @ViewBuilder func classic(in region: AppToolbarRegion) -> some View {
        if placement.region == region {
            content().labelStyle(.iconOnly)
                .buttonStyle(ClassicChromeButtonStyle(prominent: placement == .confirmationAction))
        }
    }
}
struct AppToolbarItemGroup<Content: View>: AppToolbarContent {
    var placement: AppToolbarPlacement = .automatic
    @ViewBuilder var content: () -> Content
    var native: some ToolbarContent { ToolbarItemGroup(placement: placement.native, content: content) }
    var regions: Set<AppToolbarRegion> { [placement.region] }
    @ViewBuilder func classic(in region: AppToolbarRegion) -> some View {
        if placement.region == region {
            HStack(spacing: 8, content: content).labelStyle(.iconOnly)
                .buttonStyle(ClassicChromeButtonStyle(prominent: placement == .confirmationAction))
        }
    }
}
struct AppToolbarPair<A: AppToolbarContent, B: AppToolbarContent>: AppToolbarContent {
    let first: A
    let second: B
    var native: some ToolbarContent { first.native; second.native }
    var regions: Set<AppToolbarRegion> { first.regions.union(second.regions) }
    func classic(in region: AppToolbarRegion) -> some View { Group { first.classic(in: region); second.classic(in: region) } }
}
struct AppToolbarOptional<T: AppToolbarContent>: AppToolbarContent {
    let value: T?
    var native: some ToolbarContent { if let value { value.native } }
    var regions: Set<AppToolbarRegion> { value?.regions ?? [] }
    @ViewBuilder func classic(in region: AppToolbarRegion) -> some View { if let value { value.classic(in: region) } }
}
struct AppToolbarEither<A: AppToolbarContent, B: AppToolbarContent>: AppToolbarContent {
    let first: A?
    let second: B?
    var native: some ToolbarContent { if let first { first.native } else if let second { second.native } }
    var regions: Set<AppToolbarRegion> { first?.regions ?? second?.regions ?? [] }
    @ViewBuilder func classic(in region: AppToolbarRegion) -> some View { if let first { first.classic(in: region) } else if let second { second.classic(in: region) } }
}
private struct EmptyAppToolbar: AppToolbarContent {
    var native: some ToolbarContent { ToolbarItem { EmptyView() } }
    var regions: Set<AppToolbarRegion> { [] }
    func classic(in region: AppToolbarRegion) -> some View { EmptyView() }
}
@resultBuilder enum AppToolbarBuilder {
    static func buildExpression<T: AppToolbarContent>(_ value: T) -> T { value }
    static func buildPartialBlock<T: AppToolbarContent>(first: T) -> T { first }
    static func buildPartialBlock<A: AppToolbarContent, B: AppToolbarContent>(accumulated: A, next: B) -> AppToolbarPair<A, B> { .init(first: accumulated, second: next) }
    static func buildOptional<T: AppToolbarContent>(_ value: T?) -> AppToolbarOptional<T> { .init(value: value) }
    static func buildEither<A: AppToolbarContent, B: AppToolbarContent>(first: A) -> AppToolbarEither<A, B> { .init(first: first, second: nil) }
    static func buildEither<A: AppToolbarContent, B: AppToolbarContent>(second: B) -> AppToolbarEither<A, B> { .init(first: nil, second: second) }
}
extension View {
    func appNavigationScreen() -> some View {
        environment(\.classicChromeHosted, false)
            .environment(\.appFormRow, false)
            .environment(\.appPressFeedbackHosted, false)
    }

    /// A screen reached by a push. Adds one to the routing depth so its chrome
    /// can show a back button; sheets keep `appNavigationScreen()` and depth 0.
    func appPushedScreen() -> some View {
        modifier(AppPushedScreen())
    }

    func appNavigationDestination<Value: Hashable, Destination: View>(for type: Value.Type, @ViewBuilder destination: @escaping (Value) -> Destination) -> some View {
        navigationDestination(for: type) { destination($0).appPushedScreen() }
    }
    func appNavigationDestination<Destination: View>(isPresented: Binding<Bool>, @ViewBuilder destination: @escaping () -> Destination) -> some View {
        navigationDestination(isPresented: isPresented) { destination().appPushedScreen() }
    }
    func appNavigationDestination<Item: Hashable, Destination: View>(item: Binding<Item?>, @ViewBuilder destination: @escaping (Item) -> Destination) -> some View {
        navigationDestination(item: item) { destination($0).appPushedScreen() }
    }

    func appToolbar<T: AppToolbarContent>(@AppToolbarBuilder content: () -> T) -> some View {
        modifier(AppToolbarModifier(items: content()))
    }
}
private struct AppToolbarModifier<T: AppToolbarContent>: ViewModifier {
    @Environment(\.noLiquidGlass) private var enabled
    let items: T
    func body(content: Content) -> some View {
        content
            .toolbar { if !enabled { items.native } }
            .modifier(AdaptiveNavigationChrome(items: items))
    }
}

private struct ClassicChromeHostedKey: EnvironmentKey { static let defaultValue = false }
private extension EnvironmentValues {
    var classicChromeHosted: Bool {
        get { self[ClassicChromeHostedKey.self] }
        set { self[ClassicChromeHostedKey.self] = newValue }
    }
}

private struct AppNavigationDepthKey: EnvironmentKey { static let defaultValue = 0 }
extension EnvironmentValues {
    /// SwiftUI routing depth. Incremented by each destination wrapper, so a
    /// screen knows it was pushed without asking UIKit (whose SwiftUI stack
    /// reports a single view controller).
    var appNavigationDepth: Int {
        get { self[AppNavigationDepthKey.self] }
        set { self[AppNavigationDepthKey.self] = newValue }
    }
}

private struct ClassicPopActionKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}
private extension EnvironmentValues {
    /// The dismiss action of the push this screen belongs to, captured where
    /// SwiftUI hands it out. Works for links, paths, `isPresented` and `item`
    /// destinations, and never asks UIKit to pop.
    var classicPopAction: (() -> Void)? {
        get { self[ClassicPopActionKey.self] }
        set { self[ClassicPopActionKey.self] = newValue }
    }
}

private struct AppPushedScreen: ViewModifier {
    @Environment(\.appNavigationDepth) private var depth
    @Environment(\.dismiss) private var dismiss
    func body(content: Content) -> some View {
        content
            .environment(\.classicChromeHosted, false)
            .environment(\.appFormRow, false)
            .environment(\.appPressFeedbackHosted, false)
            .environment(\.appNavigationDepth, depth + 1)
            .environment(\.classicPopAction, { dismiss() })
    }
}

struct AppNavigationChrome: ViewModifier {
    func body(content: Content) -> some View {
        content.modifier(AdaptiveNavigationChrome(items: EmptyAppToolbar()))
    }
}
private struct AdaptiveNavigationChrome<Items: AppToolbarContent>: ViewModifier {
    @Environment(\.noLiquidGlass) private var enabled
    @Environment(\.classicNavigation) private var navigation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.classicChromeHosted) private var hosted
    @State private var fallbackNavigation = ClassicNavigationState()
    let items: Items
    func body(content: Content) -> some View {
        content
            .environment(\.classicChromeHosted, enabled || hosted)
            .modifier(ClassicScreenChrome(navigation: navigation ?? fallbackNavigation,
                                          isHost: !hosted && navigation != nil, items: items))
            .toolbarVisibility(enabled ? .hidden : .automatic, for: .navigationBar)
            .toolbarVisibility(enabled ? .hidden : .automatic, for: .bottomBar)
    }
}

private struct ClassicScreenChrome<Items: AppToolbarContent>: ViewModifier {
    @Environment(\.noLiquidGlass) private var classic
    @Environment(\.classicTabBarHeight) private var tabBarHeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appScreenTitle) private var environmentTitle
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appNavigationDepth) private var depth
    @Environment(\.classicPopAction) private var popAction
    @Environment(\.appSheetClose) private var sheetClose
    let navigation: ClassicNavigationState
    let isHost: Bool
    let items: Items
    @State private var title: Text?
    @State private var titleSwipe: AppTitleSwipeAction?
    @State private var headerScrolled = false

    private var isPushed: Bool { depth > 0 }
    private var resolvedTitle: Text? { environmentTitle ?? title }
    private var enabled: Bool { classic && isHost }
    private var showsHeader: Bool { enabled && (resolvedTitle != nil || !items.regions.isEmpty || isPushed) }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if showsHeader { header }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if enabled {
                    VStack(spacing: 0) {
                        if items.regions.contains(.bottom) {
                            HStack(spacing: 8) { items.classic(in: .bottom) }
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .background { FrostedBackdrop() }
                        }
                        if tabBarHeight > 0 { Color.clear.frame(height: tabBarHeight).accessibilityHidden(true) }
                    }
                }
            }
            .onPreferenceChange(AppScreenTitleKey.self) { newTitle in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    title = newTitle
                }
            }
            .onPreferenceChange(AppTitleSwipeKey.self) { titleSwipe = $0 }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 8
            } action: { _, scrolled in
                if enabled { headerScrolled = scrolled }
            }
    }

    private func goBack() {
        // The destination's own dismiss is the only pop SwiftUI will not revert:
        // it goes through the presentation that actually owns the screen, for
        // links, paths, `isPresented` and `item` alike. The path binding is the
        // fallback for a destination pushed without `appPushedScreen()`.
        if let popAction {
            popAction()
            return
        }
        if navigation.pop?() == true { return }
        dismiss()
    }

    private var isSheetRoot: Bool { sheetClose != nil && !isPushed }

    @ViewBuilder
    private var header: some View {
        if isSheetRoot { sheetRootHeader } else { barHeader }
    }

    /// Dead-center title and borderless iOS 18 actions for a sheet's root.
    /// The ZStack keeps the title mathematically centered no matter how wide
    /// the leading/trailing slots grow.
    private var sheetRootHeader: some View {
        ClassicSheetHeader(title: resolvedTitle ?? Text(verbatim: "")) {
            if items.regions.contains(.leading) {
                HStack(spacing: 8) { items.classic(in: .leading) }
                    .fixedSize(horizontal: true, vertical: false)
            }
        } trailing: {
            if items.regions.contains(.trailing) {
                HStack(spacing: 8) { items.classic(in: .trailing) }
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .background {
            FrostedBackdrop()
                .opacity(headerScrolled ? 1 : 0)
                .animation(AppMotion.gentle(reduceMotion: reduceMotion), value: headerScrolled)
                .ignoresSafeArea(edges: .top)
        }
    }

    private var barHeader: some View {
        HStack(spacing: 10) {
            if isPushed {
                Button {
                    Haptics.shared.selection()
                    goBack()
                } label: {
                    AppIcon(systemName: "chevron.left", size: 17)
                }
                .buttonStyle(ClassicChromeButtonStyle())
                .accessibilityLabel("Back")
            }
            if items.regions.contains(.leading) {
                HStack(spacing: 8) { items.classic(in: .leading) }
                    .fixedSize(horizontal: true, vertical: false)
            }
            if let title = resolvedTitle {
                title.font(Typography.navigationTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(.rect)
                    .gesture(
                        DragGesture(minimumDistance: 12).onEnded { value in
                            guard LibrarySwipeInteraction.isTitleSwipe(
                                horizontal: value.translation.width,
                                vertical: value.translation.height
                            ) else { return }
                            titleSwipe?.perform()
                        },
                        including: titleSwipe == nil ? .none : .all
                    )
                    .accessibilityActions {
                        if let titleSwipe {
                            Button("Switch library mode", action: titleSwipe.perform)
                        }
                    }
            } else {
                Spacer(minLength: 0)
            }
            if items.regions.contains(.trailing) {
                HStack(spacing: 8) { items.classic(in: .trailing) }
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(minHeight: 60)
        .background {
            FrostedBackdrop()
                .opacity(headerScrolled ? 1 : 0)
                .animation(AppMotion.gentle(reduceMotion: reduceMotion), value: headerScrolled)
                .ignoresSafeArea(edges: .top)
        }
    }
}

struct ClassicChromeButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func isProminent(_ configuration: Configuration) -> Bool {
        prominent || configuration.role == .close
    }

    func makeBody(configuration: Configuration) -> some View {
        let prominentStyle = isProminent(configuration)
        let isDestructive = configuration.role == .destructive
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        configuration.label
            .font(Typography.body.weight(prominentStyle ? .semibold : .medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 36, minHeight: 36)
            .padding(.horizontal, prominentStyle ? 14 : 6)
            .foregroundStyle(
                prominentStyle
                    ? (colorScheme == .dark ? Color.black : Color.white)
                    : (isDestructive ? AppTheme.destructive : .primary)
            )
            .background {
                if prominentStyle {
                    shape.fill(colorScheme == .dark ? Color.white : Color.black)
                }
            }
            .opacity(enabled ? (configuration.isPressed ? 0.55 : 1) : 0.35)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(ClassicMotion.micro(reduceMotion: reduceMotion), value: configuration.isPressed)
            .contentShape(shape)
    }
}

/// Installed once at each NavigationStack root, so it lives as long as the
/// stack does. Enables UIKit's native 1:1 interactive pop gesture while the
/// navigation bar is hidden in classic mode — the system delegate is saved on
/// first sight and put back when Liquid Glass returns, instead of being
/// clobbered by every screen that pushes and then leaked by the one that pops.
private struct ClassicInteractivePopBridge: UIViewControllerRepresentable {
    let enabled: Bool

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.apply(enabled: enabled)
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private var popEnabled = false
        private weak var originalDelegate: (any UIGestureRecognizerDelegate)?
        private weak var configuredNav: UINavigationController?

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            apply(enabled: popEnabled)
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            apply(enabled: popEnabled)
        }

        func apply(enabled: Bool) {
            popEnabled = enabled
            guard let nav = navigationController,
                  let pop = nav.interactivePopGestureRecognizer else { return }

            if configuredNav !== nav {
                originalDelegate = pop.delegate
                configuredNav = nav
            }

            if enabled {
                pop.isEnabled = true
                if pop.delegate !== self { pop.delegate = self }
            } else if pop.delegate === self {
                pop.delegate = originalDelegate
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard popEnabled, let nav = navigationController else { return false }
            return nav.viewControllers.count > 1 && nav.transitionCoordinator == nil
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Prevent horizontal ScrollViews near the left edge from stealing back swipes.
            gestureRecognizer === navigationController?.interactivePopGestureRecognizer
        }
    }
}
