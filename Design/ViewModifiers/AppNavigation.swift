import SwiftUI
import UIKit

// The system stack is a routing engine only in classic mode. None of its bars,
// back buttons, toolbar backgrounds or search chrome are displayed.
struct AppNavigationStack<Root: View>: View {
    private let makeStack: () -> NavigationStack<NavigationPath, Root>
    @State private var navigation = ClassicNavigationState()

    init(@ViewBuilder root: @escaping () -> Root) {
        makeStack = { NavigationStack { root() } }
    }
    init(path: Binding<NavigationPath>, @ViewBuilder root: @escaping () -> Root) {
        makeStack = { NavigationStack(path: path) { root() } }
    }
    var body: some View {
        makeStack()
            .environment(\.classicNavigation, navigation)
    }
}

struct AppPathNavigationStack<Data: MutableCollection & RandomAccessCollection & RangeReplaceableCollection, Root: View>: View where Data.Element: Hashable {
    @Binding var path: Data
    @ViewBuilder var root: () -> Root
    @State private var navigation = ClassicNavigationState()
    var body: some View {
        NavigationStack(path: $path) { root() }
            .environment(\.classicNavigation, navigation)
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
    var canGoBack = false
    var back: (() -> Void)?
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

private struct AppPushedScreen: ViewModifier {
    @Environment(\.appNavigationDepth) private var depth
    func body(content: Content) -> some View {
        content
            .environment(\.classicChromeHosted, false)
            .environment(\.appFormRow, false)
            .environment(\.appPressFeedbackHosted, false)
            .environment(\.appNavigationDepth, depth + 1)
    }
}

/// Captures the destination's own dismiss action. Reading `dismiss` from the
/// chrome modifier resolved to the root's action, so the back button did nothing.
private struct BackActionReader: View {
    @Environment(\.dismiss) private var dismiss
    let onReady: (@escaping () -> Void) -> Void
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { onReady { dismiss() } }
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
    @Environment(\.appSheetClose) private var sheetClose
    @Environment(\.appScreenTitle) private var environmentTitle
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appNavigationDepth) private var depth
    let navigation: ClassicNavigationState
    let isHost: Bool
    let items: Items
    @State private var title: Text?
    @State private var titleSwipe: AppTitleSwipeAction?
    @State private var headerScrolled = false
    @State private var backAction: (() -> Void)?

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
            .background {
                ZStack {
                    if enabled {
                        // Native interactive pop still needs UIKit's controller.
                        NavigationDepthBridge(navigation: navigation)
                            .frame(width: 0, height: 0)
                            .allowsHitTesting(false)
                    }
                    if enabled, isPushed {
                        BackActionReader { backAction = $0 }
                            .allowsHitTesting(false)
                        // Window-level edge swipe: independent of whether UIKit's
                        // pop gesture is available under a hidden nav bar.
                        EdgeSwipeDismiss(edges: [.left]) { goBack() }
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
        if let native = navigation.back {
            native()
        } else if let backAction {
            backAction()
        } else {
            dismiss()
        }
    }

    private var header: some View {
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
    private func isProminent(_ configuration: Configuration) -> Bool { prominent || configuration.role == .close }
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.body.weight(.semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 44, minHeight: 44)
            .padding(.horizontal, 12)
            .foregroundStyle(
                isProminent(configuration) ? Color.white :
                (configuration.role == .destructive ? AppTheme.destructive : AppTheme.accent)
            )
            .background {
                if isProminent(configuration) {
                    RoundedRectangle(cornerRadius: 15).fill(AppTheme.confirmation)
                } else { FrostedSurface(shape: RoundedRectangle(cornerRadius: 15)) }
            }
            .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.35)
            .contentShape(.rect)
            .appPressFeedback(configuration.isPressed)
    }
}

/// Enables UIKit's native interactive pop gesture when the navigation bar is
/// hidden. Depth for the back button comes from SwiftUI's destination wrappers,
/// not from this bridge: a SwiftUI stack reports a single view controller.
private struct NavigationDepthBridge: UIViewControllerRepresentable {
    let navigation: ClassicNavigationState
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.navigation = navigation
        controller.refresh()
    }
    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var navigation: ClassicNavigationState?
        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            refresh()
        }
        override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); refresh() }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); refresh() }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); refresh() }
        func refresh() {
            guard let nav = navigationController else { return }
            let pushed = nav.viewControllers.count > 1
            if let navigation {
                // Only offer the UIKit pop when the stack really has a screen
                // to pop; otherwise the SwiftUI dismiss action is the fallback.
                navigation.back = pushed
                    ? { [weak nav] in nav?.popViewController(animated: true) }
                    : nil
            }

            // Restore native 1:1 interactive swipe-back when the nav bar is hidden
            if let popGesture = nav.interactivePopGestureRecognizer {
                popGesture.isEnabled = pushed
                if popGesture.delegate !== self {
                    popGesture.delegate = self
                }
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let nav = navigationController else { return false }
            return nav.viewControllers.count > 1
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer is UIScreenEdgePanGestureRecognizer
        }
    }
}
