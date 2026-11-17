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
            .modifier(ClassicStackChrome(navigation: navigation))
    }
}

struct AppPathNavigationStack<Data: MutableCollection & RandomAccessCollection & RangeReplaceableCollection, Root: View>: View where Data.Element: Hashable {
    @Binding var path: Data
    @ViewBuilder var root: () -> Root
    @State private var navigation = ClassicNavigationState()
    var body: some View {
        NavigationStack(path: $path) { root() }
            .environment(\.classicNavigation, navigation)
            .modifier(ClassicStackChrome(navigation: navigation))
    }
}

@Observable final class ClassicNavigationState {
    var canGoBack = false
    var back: () -> Void = {}
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
private struct AppToolbarKey: PreferenceKey {
    static let defaultValue: [ClassicToolbarElement] = []
    static func reduce(value: inout [ClassicToolbarElement], nextValue: () -> [ClassicToolbarElement]) { value += nextValue() }
}
private struct AppToolbarPresenceKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
private struct ClassicToolbarElement: Identifiable {
    let id: UUID
    let placement: AppToolbarPlacement
    let content: AnyView
}

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
    var leading: Bool { self == .topBarLeading || self == .cancellationAction }
}

protocol AppToolbarContent {
    associatedtype Native: ToolbarContent
    associatedtype Classic: View
    @ToolbarContentBuilder var native: Native { get }
    @ViewBuilder var classic: Classic { get }
}

struct AppToolbarItem<Content: View>: AppToolbarContent {
    var placement: AppToolbarPlacement = .automatic
    @ViewBuilder var content: () -> Content
    var native: some ToolbarContent { ToolbarItem(placement: placement, content: content) }
    var classic: some View { ClassicToolbarEmitter(placement: placement, content: content) }
}
struct AppToolbarItemGroup<Content: View>: AppToolbarContent {
    var placement: AppToolbarPlacement = .automatic
    @ViewBuilder var content: () -> Content
    var native: some ToolbarContent { ToolbarItemGroup(placement: placement, content: content) }
    var classic: some View { ClassicToolbarEmitter(placement: placement) { HStack(spacing: 8, content: content) } }
}
private struct ClassicToolbarEmitter<Content: View>: View {
    @State private var id = UUID()
    let placement: AppToolbarPlacement
    @ViewBuilder var content: () -> Content
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .preference(key: AppToolbarKey.self, value: [.init(id: id, placement: placement, content: AnyView(content()))])
            .preference(key: AppToolbarPresenceKey.self, value: true)
    }
}
struct AppToolbarPair<A: AppToolbarContent, B: AppToolbarContent>: AppToolbarContent {
    let first: A
    let second: B
    var native: some ToolbarContent { first.native; second.native }
    var classic: some View { first.classic; second.classic }
}
struct AppToolbarOptional<T: AppToolbarContent>: AppToolbarContent {
    let value: T?
    var native: some ToolbarContent { if let value { value.native } }
    var classic: some View { if let value { value.classic } }
}
struct AppToolbarEither<A: AppToolbarContent, B: AppToolbarContent>: AppToolbarContent {
    let first: A?
    let second: B?
    var native: some ToolbarContent { if let first { first.native } else if let second { second.native } }
    var classic: some View { if let first { first.classic } else if let second { second.classic } }
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
            .background { if enabled { items.classic } }
            .appNavigationChrome()
    }
}

struct AppNavigationChrome: ViewModifier {
    @Environment(\.noLiquidGlass) private var enabled
    @Environment(\.classicNavigation) private var navigation
    @Environment(\.dismiss) private var dismiss
    func body(content: Content) -> some View {
        content
            .toolbarVisibility(enabled ? .hidden : .automatic, for: .navigationBar)
            .toolbarVisibility(enabled ? .hidden : .automatic, for: .bottomBar)
            .background {
                if enabled, let navigation {
                    NavigationDepthBridge(navigation: navigation, back: { dismiss() })
                        .frame(width: 0, height: 0).allowsHitTesting(false)
                }
            }
    }
}

private struct ClassicStackChrome: ViewModifier {
    @Environment(\.noLiquidGlass) private var enabled
    let navigation: ClassicNavigationState
    @State private var hasTitle = false
    @State private var hasToolbar = false
    private var showsHeader: Bool { enabled && (hasTitle || hasToolbar || navigation.canGoBack) }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if showsHeader { Color.clear.frame(height: 62).accessibilityHidden(true) }
            }
            .overlayPreferenceValue(AppToolbarKey.self) { items in
                if enabled {
                    GeometryReader { _ in
                        VStack(spacing: 0) {
                            if showsHeader {
                                header(items)
                                    .appReveal(edge: .top)
                            }
                            Spacer(minLength: 0)
                            let bottom = items.filter { $0.placement == .bottomBar }
                            if !bottom.isEmpty {
                                HStack(spacing: 8) { ForEach(bottom) { $0.content } }
                                    .buttonStyle(ClassicChromeButtonStyle())
                                    .padding(8)
                                    .background { FrostedSurface(shape: RoundedRectangle(cornerRadius: 24)) }
                                    .padding(.horizontal, 16).padding(.bottom, 8)
                                    .appReveal()
                            }
                        }
                    }
                }
            }
            .onPreferenceChange(AppScreenTitleKey.self) { hasTitle = $0 != nil }
            .onPreferenceChange(AppToolbarPresenceKey.self) { hasToolbar = $0 }
    }

    private func header(_ items: [ClassicToolbarElement]) -> some View {
        HStack(spacing: 8) {
            if navigation.canGoBack {
                Button { Haptics.shared.selection(); navigation.back() } label: {
                    AppIcon(systemName: "chevron.left", size: 17)
                }
                .accessibilityLabel("Back")
            }
            ForEach(items.filter { $0.placement.leading }) { $0.content }
            Color.clear.overlayPreferenceValue(AppScreenTitleKey.self) { title in
                title?.font(Typography.headline).lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            ForEach(items.filter { !$0.placement.leading && $0.placement != .bottomBar }) { $0.content }
        }
        .buttonStyle(ClassicChromeButtonStyle())
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: 62)
        .background {
            Rectangle().fill(.ultraThinMaterial)
                .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea(edges: .top).allowsHitTesting(false)
        }
    }
}

struct ClassicChromeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.body.weight(.semibold))
            .frame(minWidth: 44, minHeight: 44)
            .padding(.horizontal, 2)
            .background { FrostedSurface(shape: RoundedRectangle(cornerRadius: 16)) }
            .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.35)
            .contentShape(.rect)
    }
}

/// Reads routing depth only. No private subviews, delegates or bar appearance.
private struct NavigationDepthBridge: UIViewControllerRepresentable {
    let navigation: ClassicNavigationState
    let back: () -> Void
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.state = navigation
        controller.back = back
        controller.refresh()
    }
    final class Controller: UIViewController {
        var state: ClassicNavigationState?
        var back: () -> Void = {}
        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); refresh() }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); refresh() }
        func refresh() {
            guard let nav = navigationController else { return }
            var owner: UIViewController = self
            while let parent = owner.parent, parent !== nav { owner = parent }
            guard nav.topViewController === owner else { return }
            let canGoBack = nav.viewControllers.count > 1
            DispatchQueue.main.async { [weak self] in
                guard let self, let state = self.state else { return }
                if state.canGoBack != canGoBack { state.canGoBack = canGoBack }
                state.back = self.back
            }
        }
    }
}
