// MinimalModePages.swift
// Minimal Mode is a vertical pager: Library, History and Updates in a cycle.
//
// An upward drag lifts the whole pager off its resting spot against friction and
// the page is exchanged at the top of that lift: the page that left drifts
// further left and clears, while the arriving page springs in from the right and
// unblurs. The lift leaves the drag at the speed the finger was moving, so the
// drag and the settle are one motion rather than a stop followed by an
// animation. Under Reduce Motion nothing moves: the two pages crossfade in
// place. Why upward only, and the thresholds, live in `MinimalPageSwipe`.
//
// The bar is the container's, not a page's, so a swipe never swaps the chrome
// for something else, and it is the pager's only handle. The pages share the
// ambient wash drawn once here by the container; each draws its own scrims, so
// its title is never dimmed by them. Every page is a dark reader-style surface
// like the library shelf.

import SwiftData
import SwiftUI

// MARK: - Pager

@Observable
@MainActor
final class MinimalPager {
    /// The cycle, in the order an upward swipe visits them. Library is first:
    /// it is where the app opens and what the resume chip is for.
    enum Page: Int, CaseIterable, Identifiable {
        case library, history, updates

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .updates: "Updates"
            case .library: "Library"
            case .history: "History"
            }
        }

        /// The page one swipe up reveals. The pager wraps, so there is no end.
        var next: Page { Page(rawValue: (rawValue + 1) % Page.allCases.count) ?? .library }
    }

    private(set) var page: Page = .library
    /// The page drifting out to the left. It stays mounted, and clear of the
    /// hit testing and VoiceOver tree, until the reveal completes; only then is
    /// it silently restaged on the right for its next entrance.
    private(set) var leavingPage: Page?
    /// How far the pages are lifted off their resting place. Never negative:
    /// only an upward drag lifts them, and they always come back down.
    private(set) var lift: CGFloat = 0
    /// Pages whose content has been built at least once.
    private(set) var built: Set<Page> = [.library]

    /// How deep each page's navigation stack is. The bar belongs to the
    /// container, so it has to know when a page has pushed a screen: otherwise
    /// it would float over the detail it pushed.
    private(set) var pushDepth: [Page: Int] = [:]

    func report(depth: Int, for page: Page) {
        guard pushDepth[page] != depth else { return }
        pushDepth[page] = depth
    }

    /// Whether the page in view is showing a pushed screen rather than itself.
    var isPagePushed: Bool { pushDepth[page, default: 0] > 0 }

    /// The most recently read book's cover colour. The library page owns the
    /// query that finds it; the container owns the background that wears it.
    var ambientTint: Color?

    /// A commit is in flight. Drags that start mid-commit are ignored, so one
    /// swipe can never change the page twice.
    private var isSnapping = false
    /// Whether the current drag has reached the commit threshold, for one
    /// detent haptic per crossing.
    private var crossedDetent = false
    /// How fast the finger is moving the pages, in points per second. The lift
    /// leaves the drag at this speed, so a flick is not braked the moment it is
    /// released.
    private var dragSpeed: Double = 0
    private var lastSample: (y: CGFloat, at: Date)?

    func dragChanged(horizontal: CGFloat, vertical: CGFloat, time: Date) {
        guard !isSnapping else { return }
        sampleSpeed(vertical: vertical, at: time)
        guard MinimalPageSwipe.isVertical(horizontal: Double(horizontal), vertical: Double(vertical)) else {
            lift = 0
            return
        }
        lift = CGFloat(MinimalPageSwipe.lift(translation: Double(vertical)))
        // Built on the first frame that lifts, not on release: the page that
        // reveals in has the whole drag to get its query and list ready.
        if lift > 0, !built.contains(page.next) { built.insert(page.next) }
        // One click at the point where the swipe would commit.
        let crossed = max(0, -Double(vertical)) >= MinimalPageSwipe.commitDistance
        if crossed != crossedDetent {
            crossedDetent = crossed
            if crossed { Haptics.shared.selection() }
        }
    }

    /// Smoothed across samples: one frame of jitter must not decide how the
    /// lift settles. The first sample of a drag seeds it rather than easing up
    /// from zero.
    private func sampleSpeed(vertical: CGFloat, at time: Date) {
        defer { lastSample = (y: vertical, at: time) }
        guard let last = lastSample else {
            dragSpeed = 0
            return
        }
        let dt = time.timeIntervalSince(last.at)
        guard dt > 0 else { return }
        let sample = Double(vertical - last.y) / dt
        dragSpeed = dragSpeed == 0 ? sample : dragSpeed * 0.55 + sample * 0.45
    }

    func dragEnded(horizontal: CGFloat, vertical: CGFloat, predicted: CGFloat, reduceMotion: Bool) {
        let hadDetent = crossedDetent
        let speed = dragSpeed
        crossedDetent = false
        dragSpeed = 0
        lastSample = nil
        guard !isSnapping else { return }
        guard MinimalPageSwipe.isVertical(horizontal: Double(horizontal), vertical: Double(vertical)),
              MinimalPageSwipe.commits(translation: Double(vertical), predicted: Double(predicted))
        else {
            // Back to the spot it was lifted from, still at the finger's speed.
            withAnimation(AppMotion.pageSticky(speed: speed, distance: Double(lift), reduceMotion: reduceMotion)) {
                lift = 0
            }
            return
        }
        // A drag that already clicked at the detent does not click again on
        // release. A flick that never reached it needs the click to say the
        // page changed anyway.
        advance(speed: speed, reduceMotion: reduceMotion, announce: !hadDetent)
    }

    /// A menu pick has no lift to fall from, so the reveal is the whole motion.
    func select(_ target: Page, reduceMotion: Bool = false) {
        guard target != page, !isSnapping else { return }
        Haptics.shared.selection()
        let wasBuilt = built.contains(target)
        built.insert(target)
        isSnapping = true
        // A page picked for the first time has to mount in its waiting slot
        // before it can change to active, or it would appear already in place
        // instead of springing in.
        if wasBuilt {
            performSwap(to: target, speed: 0, reduceMotion: reduceMotion)
        } else {
            Task { @MainActor in
                self.performSwap(to: target, speed: 0, reduceMotion: reduceMotion)
            }
        }
    }

    private func advance(speed: Double, reduceMotion: Bool, announce: Bool) {
        if announce { Haptics.shared.selection() }
        let next = page.next
        let wasBuilt = built.contains(next)
        built.insert(next)
        isSnapping = true
        if wasBuilt {
            performSwap(to: next, speed: speed, reduceMotion: reduceMotion)
        } else {
            Task { @MainActor in
                self.performSwap(to: next, speed: speed, reduceMotion: reduceMotion)
            }
        }
    }

    /// The switch itself: the lift comes home at the finger's speed while the
    /// pages exchange. The outgoing page drifts left and clears; the incoming
    /// one springs in from the right and unblurs. The pager stays locked until
    /// that reveal has logically finished, then the now-invisible outgoing page
    /// is restaged on the right with no animation.
    private func performSwap(to next: Page, speed: Double, reduceMotion: Bool) {
        let outgoing = page

        withAnimation(AppMotion.pageSticky(speed: speed, distance: Double(lift), reduceMotion: reduceMotion)) {
            lift = 0
        }

        withAnimation(AppMotion.pageReveal(reduceMotion: reduceMotion), completionCriteria: .logicallyComplete) {
            leavingPage = outgoing
            page = next
        } completion: {
            self.leavingPage = nil
            self.isSnapping = false
        }
    }
}

// MARK: - Container

/// The window's height, which on iPhone is the screen's. A last resort for the
/// page height: neither geometry reading is guaranteed to see past the safe
/// area, and a page a few points short of the screen leaves the home-indicator
/// band unpainted behind the bar.
@MainActor
private enum MinimalWindow {
    static var height: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.bounds.height ?? 0
    }
}

/// The Minimal Mode root: the ambient field, the three pages in one place on
/// top of it, and the swipe that lifts them. Replaces `MinimalLibraryView` as
/// what `ContentView` shows when Minimal Mode is on.
struct MinimalModeView: View {
    /// An entry a `lnreader://entry` link asked for; the library page pushes it.
    @Binding var openedEntry: SourceEntry?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @Environment(SourceManager.self) private var sourceManager
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(ReaderRouter.self) private var readerRouter

    @State private var pager = MinimalPager()
    /// Search belongs to the bar and the bar belongs to this container, so the
    /// state the library page's field reads lives here.
    @State private var showSearch = false
    @State private var searchText = ""
    /// The full screen height, measured off the layer that ignores the safe
    /// area. A page is one screen tall — measured to the safe area instead, the
    /// page stops short of the home-indicator band and the lift shows it.
    @State private var screenHeight: CGFloat = 0

    /// The book the resume chip offers: the one read most recently.
    @Query private var recent: [Entry]

    init(openedEntry: Binding<SourceEntry?>) {
        _openedEntry = openedEntry
        _recent = Query(MinimalResumeFeed.descriptor)
    }

    var body: some View {
        GeometryReader { screenGeo in
            // The screen, however the reader is laid out. Three readings of the
            // same number — the proxy's size plus its insets, the wash's
            // measured height, and the window — and the largest wins: a page
            // that is a few points short of the screen leaves the next page
            // showing through the home-indicator band.
            let insets = screenGeo.safeAreaInsets
            let height = max(
                screenGeo.size.height + insets.top + insets.bottom,
                max(screenHeight, MinimalWindow.height)
            )
            // Where the safe area starts and ends inside that screen, so each
            // page can keep its chrome out of the status bar and off the home
            // indicator.
            let totalInset = max(0, height - screenGeo.size.height)
            let measuredTop = insets.top > 0 ? insets.top : screenGeo.frame(in: .global).minY
            let safeTop = min(max(0, measuredTop), totalInset)
            let safeBottom = max(0, totalInset - safeTop)

            ZStack(alignment: .top) {
                ambientBackground
                    .ignoresSafeArea()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { screenHeight = $0 }
                    .animation(.easeInOut(duration: 0.55), value: pager.ambientTint)

                // The pages are handed to the stack once. A drag frame then
                // moves one offset and rebuilds nothing: recreating three page
                // views — a binding and a `@Query` each — sixty times a second
                // is what made the movement choppy.
                MinimalPageStack {
                    // Only the pages that have been visited exist. Building all
                    // three on the way into Minimal Mode cost a list and a
                    // fetch each, for screens the user may never open.
                    page(.library) {
                        MinimalLibraryView(
                            openedEntry: $openedEntry,
                            screenHeight: height,
                            safeTop: safeTop,
                            searchText: $searchText,
                            showSearch: $showSearch,
                            onRefresh: refreshLibrary
                        )
                    }
                    page(.history) {
                        MinimalHistoryPage(safeTop: safeTop, safeBottom: safeBottom)
                    }
                    page(.updates) {
                        MinimalUpdatesPage(safeTop: safeTop, safeBottom: safeBottom)
                    }
                }
                .frame(width: screenGeo.size.width, height: height)
                // The stack is a full screen tall inside a reader that is inset
                // by the status bar: lift it so page 0 starts at the screen top.
                // Only the stack moves — the wash behind it stays put.
                .offset(y: -safeTop)

                // The bar and the toast sit above the stack and never move, so
                // a swipe changes the page behind them. A pushed book covers
                // the page it came from, so the chrome steps out of its way.
                if !pager.isPagePushed {
                    VStack(spacing: 10) {
                        Spacer(minLength: 0)
                        if let tone = updateToast {
                            MinimalUpdateToast(tone: tone) {
                                libraryManager.dismissUpdateSummary()
                            }
                            .appReveal(edge: .bottom)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                        MinimalLibraryBar(
                            resumeCoverURL: resumeEntry?.displayThumbnailURL,
                            canResume: resumeEntry != nil,
                            isSearching: showSearch,
                            isUpdating: libraryManager.isUpdating,
                            onSearch: toggleSearch,
                            onResume: resumeReading,
                            onRefresh: refreshLibrary
                        )
                    }
                    .padding(.bottom, 14 + safeBottom)
                    .offset(y: -safeTop)
                    .transition(.opacity)
                }
            }
            .animation(AppMotion.gentle(reduceMotion: reduceMotion), value: updateToast)
            .animation(AppMotion.gentle(reduceMotion: reduceMotion), value: pager.isPagePushed)
        }
        .environment(pager)
        .task(id: resumeEntry?.persistentModelID) {
            guard let url = resumeEntry?.displayThumbnailURL else {
                pager.ambientTint = nil
                return
            }
            pager.ambientTint = await CoverTint.color(for: url)
        }
        .toolbar(.hidden, for: .navigationBar)
        // The detail screens follow the dark surface, so the zoom transition
        // does not flip colour scheme mid-flight.
        .preferredColorScheme(.dark)
    }

    /// One slot in the pager. Every page sits in the same place; the reveal is
    /// its own offset (see `MinimalPager.performSwap`):
    ///
    /// - active: centered and crisp;
    /// - leaving: drifts left and clears;
    /// - waiting: staged just to the right and held invisible, so its entrance
    ///   never has to pop into place.
    ///
    /// An unvisited page is a transparent, untouchable placeholder rather than
    /// a missing child, so inserting it later cannot disturb its neighbours.
    @ViewBuilder
    private func page<Content: View>(
        _ page: MinimalPager.Page,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if pager.built.contains(page) {
            let isActive = page == pager.page
            let isLeaving = page == pager.leavingPage
            let xOffset: CGFloat = reduceMotion ? 0 : (isActive ? 0 : (isLeaving ? -8 : 10))
            let blurRadius: CGFloat = reduceMotion ? 0 : (isActive ? 0 : (isLeaving ? 3 : 4))

            content()
                .offset(x: xOffset)
                .blur(radius: blurRadius)
                .opacity(isActive ? 1 : 0)
                .allowsHitTesting(isActive)
                .accessibilityHidden(!isActive)
                // The incoming page rides above the one that is leaving.
                .zIndex(isActive ? 1 : 0)
        } else {
            Color.clear.allowsHitTesting(false)
        }
    }

    // MARK: - Chrome

    /// The book the resume chip offers.
    private var resumeEntry: Entry? { recent.first }

    /// Only a finished run says anything, and only when there is something to
    /// say. A toast with a count, not a card with a list: the chapters
    /// themselves live on the Updates page, one swipe away.
    private var updateToast: MinimalUpdateToast.Tone? {
        guard let progress = libraryManager.updateProgress, progress.isFinished else { return nil }
        if progress.newChapters > 0 { return .chapters(progress.newChapters) }
        if !progress.failures.isEmpty { return .trouble(progress.failures.count) }
        return nil
    }

    /// The bar is on every page, so searching from Updates or History goes to
    /// the shelf first — otherwise the field would open out of sight.
    private func toggleSearch() {
        Haptics.shared.selection()
        if !showSearch, pager.page != .library { pager.select(.library, reduceMotion: reduceMotion) }
        withAnimation(AppMotion.gentle(reduceMotion: reduceMotion)) {
            showSearch.toggle()
        }
    }

    /// Opens the last chapter read in a library book, where the reader left it.
    /// One small fetch on tap, not a `@Query` this screen keeps alive.
    private func resumeReading() {
        var descriptor = FetchDescriptor<History>(sortBy: [SortDescriptor(\.lastRead, order: .reverse)])
        descriptor.fetchLimit = 25
        let history = (try? modelContext.fetch(descriptor)) ?? []
        guard let chapter = history.lazy.compactMap(\.chapter).first(where: { $0.entry?.inLibrary == true }),
              let entry = chapter.entry else {
            // Nothing to resume: the shelf is the closest thing to it.
            pager.select(.library, reduceMotion: reduceMotion)
            return
        }
        Haptics.shared.impact(.light)
        readerRouter.open(
            sourceKey: entry.sourceKey,
            entryURL: entry.url,
            kind: entry.kind,
            chapterURL: chapter.url,
            chapterName: chapter.name
        )
    }

    private func refreshLibrary() {
        Haptics.shared.impact(.light)
        let context = modelContext, sources = sourceManager
        Task {
            await libraryManager.updateLibrary(context: context, sourceManager: sources)
        }
    }

    /// The most recently read book's colour, washed over near-black. Neutral
    /// until `CoverTint` has an answer.
    private var ambientBackground: some View {
        let tint = pager.ambientTint ?? Color(white: 0.08)
        return ZStack {
            Color(white: 0.03)
            tint.opacity(0.25)
            RadialGradient(
                colors: [tint.opacity(0.38), Color.black.opacity(0.9)],
                center: UnitPoint(x: 0.25, y: 0.22),
                startRadius: 20,
                endRadius: 520
            )
            LinearGradient(
                colors: [
                    Color.black.opacity(0.15),
                    Color.black.opacity(0.45),
                    Color.black.opacity(0.75)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

/// The resume chip's book: the library entry read most recently, fetched as one
/// row rather than by walking the library.
enum MinimalResumeFeed {
    static let descriptor: FetchDescriptor<Entry> = {
        var descriptor = FetchDescriptor<Entry>(
            predicate: #Predicate<Entry> { $0.inLibrary && $0.lastReadAt != nil },
            sortBy: [SortDescriptor(\.lastReadAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return descriptor
    }()
}

// MARK: - Page stack

/// The coordinate space a page's content measures itself in. A page starts at
/// the screen top, so at rest this is the same as `.global`; while the stack is
/// being dragged it is not, which is the point — the shelf's rows must not blur
/// just because the whole page is moving.
enum MinimalPageSpace {
    static let name = "minimalPage"
}

/// Lifts the whole pager off its resting place. It exists so that the only
/// thing a drag frame touches is one offset: the pages arrive as content built
/// by the container, which does not read the lift and so is never rebuilt
/// mid-swipe.
private struct MinimalPageStack<Content: View>: View {
    let content: Content

    @Environment(MinimalPager.self) private var pager

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        // The stack owns the lift only. Each page's horizontal reveal is its
        // own offset, applied in `MinimalModeView.page`.
        ZStack(alignment: .top) {
            content
        }
        .offset(y: -pager.lift)
    }
}

// MARK: - Row cascade

extension View {
    /// A page's rows trail the page's own reveal: each one arrives from the
    /// right a beat after the one above it, and drifts left when the page
    /// leaves. Only the first eight rows animate; a long list stays finished.
    func minimalPageItem(index: Int, page: MinimalPager.Page) -> some View {
        modifier(MinimalPageItemMotion(index: index, page: page))
    }
}

private struct MinimalPageItemMotion: ViewModifier {
    let index: Int
    let page: MinimalPager.Page

    @Environment(MinimalPager.self) private var pager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let isActive = pager.page == page
        let isLeaving = pager.leavingPage == page
        // Reduce Motion keeps the rows in place and lets the page fade.
        let cascades = !reduceMotion && index < 8
        let delay = cascades && isActive ? Double(index) * 0.022 : 0
        let xOffset: CGFloat = cascades ? (isActive ? 0 : (isLeaving ? -8 : 16)) : 0
        let blurRadius: CGFloat = cascades ? (isActive ? 0 : (isLeaving ? 3 : 5)) : 0

        content
            .offset(x: xOffset)
            .blur(radius: blurRadius)
            // Restaging the leaving page (clearing `leavingPage` after the
            // swap) is not driven by `isActive`, so it lands silently while
            // the rows are already invisible.
            .animation(
                isActive
                    ? AppMotion.pageReveal(reduceMotion: reduceMotion).delay(delay)
                    : (isLeaving ? AppMotion.pageExit(reduceMotion: reduceMotion) : nil),
                value: isActive
            )
    }
}

// MARK: - Page handles

extension View {
    /// Makes this view a Minimal Mode page handle: an upward drag on it moves
    /// to the next page, and VoiceOver gets the pages as named actions because
    /// a drag is not something it can perform. Taps on buttons inside still
    /// work — the drag needs 12pt of mostly-vertical travel before it takes
    /// over, and one swipe can only ever change one page.
    func minimalPageHandle() -> some View {
        modifier(MinimalPageHandle())
    }
}

private struct MinimalPageHandle: ViewModifier {
    @Environment(MinimalPager.self) private var pager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            // High priority, not simultaneous: a drag that has travelled 12pt
            // owns the touch, so paging can never also fire the button under
            // the finger. A tap never travels, so the drag never starts and the
            // button keeps its tap.
            .highPriorityGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        pager.dragChanged(
                            horizontal: value.translation.width,
                            vertical: value.translation.height,
                            time: value.time
                        )
                    }
                    .onEnded { value in
                        pager.dragEnded(
                            horizontal: value.translation.width,
                            vertical: value.translation.height,
                            predicted: value.predictedEndTranslation.height,
                            reduceMotion: reduceMotion
                        )
                    }
            )
            .accessibilityAction(named: "Show Library") { pager.select(.library, reduceMotion: reduceMotion) }
            .accessibilityAction(named: "Show History") { pager.select(.history, reduceMotion: reduceMotion) }
            .accessibilityAction(named: "Show Updates") { pager.select(.updates, reduceMotion: reduceMotion) }
    }
}

// MARK: - Header and page menu

/// The floating serif title every minimal page wears, with the page menu beside
/// it. Paging is the bar's, not the title's: a drag up here fought the shelf's
/// own scroll feel and read as lag. The title is the mode switch instead — a
/// vertical swipe on it leaves Minimal Mode, the mirror of the same swipe on the
/// library's title, which enters it.
struct MinimalPageHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    @AppStorage(MinimalMode.enabledKey) private var minimalMode = false

    init(title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(.largeTitle, design: .serif, weight: .bold))
                .foregroundStyle(.white)
                .contentShape(.rect)
                // The same predicate the library's title uses, so both ends of
                // the switch read a drag the same way. High priority: the shelf
                // scrolls under this title, and a swipe that starts on the
                // title is aimed at the mode, not the list.
                .highPriorityGesture(
                    DragGesture(minimumDistance: 12).onEnded { value in
                        guard LibrarySwipeInteraction.isTitleSwipe(
                            horizontal: value.translation.width,
                            vertical: value.translation.height
                        ) else { return }
                        Haptics.shared.selection()
                        minimalMode = false
                    }
                )
                .accessibilityAction(named: "Leave Minimal Mode") {
                    Haptics.shared.selection()
                    minimalMode = false
                }
            MinimalPageMenu()

            Spacer(minLength: 0)

            trailing
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }
}

extension MinimalPageHeader where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// Three page markers that are also the way to jump. Tapping opens the three
/// pages with the current one checked; holding and gliding picks one on
/// release, the way any iOS menu works.
///
/// Each marker has its own fixed slot, so the row never changes width when the
/// page does — that was the jitter.
struct MinimalPageMenu: View {
    @Environment(MinimalPager.self) private var pager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AppMenu {
            // A picker, not three buttons: the system puts the tick on the
            // trailing edge and keeps every title where it was. A hand-drawn
            // checkmark ends up leading, which moves the entry you picked.
            Picker("Page", selection: Binding(get: { pager.page }, set: { pager.select($0, reduceMotion: reduceMotion) })) {
                ForEach(MinimalPager.Page.allCases) { page in
                    Text(page.title).tag(page)
                }
            }
            .pickerStyle(.inline)
        } label: {
            markers
        }
        .accessibilityLabel("Page, \(pager.page.title)")
        .accessibilityHint("Choose Library, History or Updates")
    }

    private var markers: some View {
        HStack(spacing: 0) {
            ForEach(MinimalPager.Page.allCases) { page in
                Capsule()
                    .fill(.white.opacity(page == pager.page ? 0.92 : 0.3))
                    .frame(width: page == pager.page ? 14 : 5, height: 5)
                    .frame(width: 18, height: 5)
            }
        }
        .frame(height: 44)
        .contentShape(.rect)
        .animation(AppMotion.gentle(reduceMotion: reduceMotion), value: pager.page)
    }
}

// MARK: - Feed pages

/// The shape the Updates and History pages share: the stack, the floating
/// title, the clearance the bar needs, and the pushed book with the
/// migrate-replacement swap. A page supplies its own body — its empty state,
/// its list and its rows.
private struct MinimalFeedPage<Body: View, Trailing: View>: View {
    let page: MinimalPager.Page
    let title: String
    let safeTop: CGFloat
    let safeBottom: CGFloat
    @Binding var path: NavigationPath
    let trailing: Trailing
    @ViewBuilder var content: () -> Body

    @Environment(MinimalPager.self) private var pager

    var body: some View {
        AppNavigationStack(path: $path) {
            VStack(spacing: 0) {
                MinimalPageHeader(title: title) { trailing }
                content()
            }
            .padding(.top, safeTop)
            // The bar floats over every page, so the list stops above it.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: 76 + safeBottom)
            }
            .appNavigationDestination(for: Entry.self) { entry in
                // A migrated entry takes the place of the one that left.
                EntryDetailView(entry: entry) { replacement in
                    if !path.isEmpty { path.removeLast() }
                    path.append(replacement)
                }
                .id(entry.persistentModelID)
            }
            .onChange(of: path.count, initial: true) { _, depth in
                pager.report(depth: depth, for: page)
            }
        }
    }
}

/// Day sections, newest first: the shape both feeds list by. Each page says how
/// its own items become rows — chapters stay as they are, history collapses
/// into runs. Items whose date is missing trail the rest under "Unknown".
private enum MinimalDaySections {
    static func of<Item, Row>(
        _ items: [Item],
        date: (Item) -> Date?,
        rows: ([Item]) -> [Row]
    ) -> [(key: String, items: [Row])] {
        let calendar = Calendar.current
        var buckets: [Date: [Item]] = [:]
        var undated: [Item] = []
        for item in items {
            guard let day = date(item) else {
                undated.append(item)
                continue
            }
            buckets[calendar.startOfDay(for: day), default: []].append(item)
        }
        var sections: [(key: String, items: [Row])] = buckets.keys.sorted(by: >).map { day in
            (key: day.daySectionTitle, items: rows(buckets[day] ?? []))
        }
        // An item with no date is still an item: the full Updates tab lists it
        // under "Unknown" at the bottom rather than losing it, and so does this.
        if !undated.isEmpty {
            sections.append((key: "Unknown", items: rows(undated)))
        }
        return sections
    }
}

// MARK: - Updates page

/// The unread new chapters, on the dark surface. The toast on the library page
/// says how many arrived; what they are belongs here.
struct MinimalUpdatesPage: View {
    /// The safe-area band the page's chrome has to stay inside: the page itself
    /// is full screen so the pages tile, but nothing should sit under the
    /// status bar or the home indicator.
    let safeTop: CGFloat
    let safeBottom: CGFloat

    @Environment(\.isReaderPresented) private var isReaderPresented
    @Environment(\.modelContext) private var modelContext
    @Environment(SourceManager.self) private var sourceManager
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(ReaderRouter.self) private var readerRouter

    @Query private var allChapters: [Chapter]
    @State private var path = NavigationPath()
    /// The last feed shown. The page stays mounted under the reader and the
    /// query re-runs on each progress save: hold the list (the `UpdatesView`
    /// rule).
    @State private var held = MinimalHeld<Chapter>()

    init(safeTop: CGFloat, safeBottom: CGFloat) {
        self.safeTop = safeTop
        self.safeBottom = safeBottom
        _allChapters = Query(MinimalUpdateFeed.descriptor)
    }

    private var chapters: [Chapter] {
        if isReaderPresented, let items = held.items { return items }
        let result = allChapters.filter { $0.entry?.inLibrary == true }
        held.items = result
        return result
    }

    var body: some View {
        MinimalFeedPage(
            page: .updates,
            title: "Updates",
            safeTop: safeTop,
            safeBottom: safeBottom,
            path: $path,
            trailing: refreshButton
        ) {
            if chapters.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(groupedChapters, id: \.key) { date, dayChapters in
                        Section(date) {
                            ForEach(Array(dayChapters.enumerated()), id: \.element.id) { index, chapter in
                                UpdateRow(
                                    chapter: chapter,
                                    onOpenEntry: {
                                        if let entry = chapter.entry { path.append(entry) }
                                    },
                                    onOpenChapter: { open(chapter) }
                                )
                                .minimalPageItem(index: index, page: .updates)
                                .listRowBackground(Color.clear)
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .appRefreshable("Refresh updates", enabled: !libraryManager.isUpdating) { startUpdate() }
            }
        }
    }

    private var emptyState: some View {
        ScrollView {
            EmptyStateView(
                icon: "bell.badge",
                title: "No Updates",
                subtitle: "New chapters from your library will appear here."
            )
            .frame(maxWidth: .infinity, minHeight: 300)
        }
        .appRefreshable("Refresh updates", enabled: !libraryManager.isUpdating) { startUpdate() }
        .frame(maxHeight: .infinity)
    }

    private var refreshButton: some View {
        Button(action: {
            Haptics.shared.impact(.light)
            startUpdate()
        }) {
            Group {
                if libraryManager.isUpdating {
                    ProgressView().tint(.white)
                } else {
                    AppIcon(systemName: "arrow.clockwise", size: 17, relativeTo: .body)
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 40, height: 40)
            .contentShape(.circle)
            .appGlassEffect(.clear.interactive(), in: .circle)
        }
        .buttonStyle(AppPlainButtonStyle())
        .disabled(libraryManager.isUpdating)
        .accessibilityLabel(libraryManager.isUpdating ? "Updating library" : "Check for updates")
    }

    /// The update outlives the pull; the toast owns the outcome.
    private func startUpdate() {
        let context = modelContext, sources = sourceManager
        Task {
            await libraryManager.updateLibrary(context: context, sourceManager: sources)
        }
    }

    private func open(_ chapter: Chapter) {
        guard let entry = chapter.entry else { return }
        Haptics.shared.impact(.light)
        readerRouter.open(
            sourceKey: entry.sourceKey,
            entryURL: entry.url,
            kind: entry.kind,
            chapterURL: chapter.url,
            chapterName: chapter.name
        )
    }

    /// Day sections, newest first.
    private var groupedChapters: [(key: String, items: [Chapter])] {
        MinimalDaySections.of(chapters, date: \.dateFetch, rows: { $0 })
    }
}

enum MinimalUpdateFeed {
    /// Built once: a page's `init` runs whenever its container rebuilds, and
    /// building a `#Predicate` on every pass is not free.
    static let descriptor: FetchDescriptor<Chapter> = {
        var descriptor = FetchDescriptor<Chapter>(
            predicate: #Predicate<Chapter> {
                $0.dateFetch != nil && !$0.hidden && !$0.read
            },
            sortBy: [SortDescriptor(\Chapter.dateFetch, order: .reverse)])
        descriptor.fetchLimit = 300
        return descriptor
    }()
}

/// The same cap for History: the newest 200 reads.
enum MinimalHistoryFeed {
    static let descriptor: FetchDescriptor<History> = {
        var descriptor = FetchDescriptor<History>(
            sortBy: [SortDescriptor(\History.lastRead, order: .reverse)])
        descriptor.fetchLimit = 200
        return descriptor
    }()
}

// MARK: - History page

/// Recently read chapters, on the dark surface. The same day-sectioned,
/// run-collapsed shape the full History tab uses.
struct MinimalHistoryPage: View {
    let safeTop: CGFloat
    let safeBottom: CGFloat

    @Environment(\.isReaderPresented) private var isReaderPresented
    @Environment(ReaderRouter.self) private var readerRouter

    @Query private var history: [History]
    @State private var path = NavigationPath()
    /// Held while the reader is open: the page stays mounted and every
    /// progress save re-runs the query (the `HistoryView` rule).
    @State private var held = MinimalHeld<History>()

    init(safeTop: CGFloat, safeBottom: CGFloat) {
        self.safeTop = safeTop
        self.safeBottom = safeBottom
        _history = Query(MinimalHistoryFeed.descriptor)
    }

    private var items: [History] {
        if isReaderPresented, let held = held.items { return held }
        let result = history.filter { $0.chapter != nil }
        self.held.items = result
        return result
    }

    var body: some View {
        MinimalFeedPage(
            page: .history,
            title: "History",
            safeTop: safeTop,
            safeBottom: safeBottom,
            path: $path,
            trailing: EmptyView()
        ) {
            if items.isEmpty {
                ScrollView {
                    EmptyStateView(
                        icon: "clock",
                        title: "No Reading History",
                        subtitle: "Chapters you read will appear here."
                    )
                    .frame(maxWidth: .infinity, minHeight: 300)
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(groupedRuns, id: \.key) { date, runs in
                        Section(date) {
                            ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                                row(run)
                                    .minimalPageItem(index: index, page: .history)
                                    .listRowBackground(Color.clear)
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func row(_ run: HistoryRun) -> some View {
        let head = run.head
        return HStack(spacing: 12) {
            RowCoverButton(entry: head.chapter?.entry) {
                if let entry = head.chapter?.entry { path.append(entry) }
            }

            VStack(alignment: .leading, spacing: 3) {
                if let entry = head.chapter?.entry {
                    Text(entry.displayTitle)
                        .font(Typography.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }

                Text(head.chapter?.name ?? "Unknown chapter")
                    .font(Typography.body)
                    .foregroundStyle(.white)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(head.lastRead, format: .dateTime.hour().minute())
                    if run.items.count > 1 {
                        Text("· \(run.items.count) chapters")
                    }
                }
                .font(Typography.small)
                .foregroundStyle(.white.opacity(0.45))
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .onTapGesture { open(head) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the chapter")
    }

    private func open(_ item: History) {
        guard let chapter = item.chapter else { return }
        Haptics.shared.impact(.light)
        readerRouter.open(
            sourceKey: chapter.entry?.sourceKey ?? "",
            entryURL: chapter.entry?.url,
            kind: chapter.entry?.kind ?? .novel,
            chapterURL: chapter.url,
            chapterName: chapter.name
        )
    }

    private var groupedRuns: [(key: String, items: [HistoryRun])] {
        MinimalDaySections.of(items, date: \.lastRead, rows: { HistoryRun.runs(of: $0) })
    }
}

// MARK: - Bar

/// The Liquid Glass bar: search on the left, continue reading in a recessed
/// centre chip with the book's cover, refresh on the right.
///
/// It stays put while the pages move behind it — a swipe changes what is above
/// the bar, never the bar. It is also the pager's handle, a drag up on it moves
/// the stack, and the only place the page actions are reachable from VoiceOver.
private struct MinimalLibraryBar: View {
    let resumeCoverURL: String?
    let canResume: Bool
    let isSearching: Bool
    let isUpdating: Bool
    let onSearch: () -> Void
    let onResume: () -> Void
    let onRefresh: () -> Void

    @Environment(\.noLiquidGlass) private var classic

    private let pillWidth: CGFloat = 236
    private let pillHeight: CGFloat = 62
    private let innerPillWidth: CGFloat = 120
    private let innerPillHeight: CGFloat = 46
    private let ink = Color.white

    /// The room the centre chip leaves on either side, for one round button.
    private var sideButtonWidth: CGFloat { (pillWidth - innerPillWidth) / 2 }

    var body: some View {
        HStack(spacing: 0) {
            sideButton(systemName: isSearching ? "xmark" : "magnifyingglass", action: onSearch)
                .accessibilityLabel(isSearching ? "Close search" : "Search library")

            Spacer().frame(width: innerPillWidth)

            Group {
                if isUpdating {
                    ProgressView()
                        .tint(ink)
                        .frame(width: sideButtonWidth, height: pillHeight)
                } else {
                    sideButton(systemName: "arrow.triangle.2.circlepath", action: onRefresh)
                }
            }
            .accessibilityLabel(isUpdating ? "Updating library" : "Refresh library")
        }
        .frame(width: pillWidth, height: pillHeight)
        // The bar's own interactive material, over the whole pill. The chip is
        // an overlay above it rather than a child inside it: glass nested in a
        // glass ancestor sinks below it, and this keeps the bar itself live.
        .appGlassEffect(.clear.interactive(), in: .capsule)
        .overlay { resumeChip }
        .contentShape(.capsule)
        .minimalPageHandle()
        .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 8)
        .accessibilityHint("Swipe up to switch between Library, History and Updates.")
    }

    /// "Resume" with the book's cover. The chip does not name the page being
    /// pulled in: it would have to take the name back the moment the page
    /// lands, and a label that appears and leaves inside one swipe is only a
    /// blip. The pages and the indicator beside the title say where you are.
    private var resumeChip: some View {
        Button(action: onResume) {
            HStack(spacing: 9) {
                EntryCoverView(url: resumeCoverURL, aspectRatio: 2 / 3, cornerRadius: 3)
                    .frame(width: 22)
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                Text("Resume")
                    .font(.system(.subheadline, design: .serif, weight: .semibold))
                    .foregroundStyle(ink)
                    .lineLimit(1)
            }
            .frame(width: innerPillWidth, height: innerPillHeight)
            .modifier(ResumeChipSkin(classic: classic, ink: ink))
            .contentShape(.capsule)
        }
        .buttonStyle(AppPlainButtonStyle())
        .disabled(!canResume)
        .opacity(canResume ? 1 : 0.5)
        .accessibilityLabel("Continue reading")
    }

    private func sideButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            AppIcon(systemName: systemName, size: 19)
                .foregroundStyle(ink)
                .frame(width: sideButtonWidth, height: pillHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(AppPlainButtonStyle())
    }
}

/// Classic has no glass-in-glass: the chip is a tinted fill on the frosted
/// bar, the treatment the app's classic selectors use. Glass mode gives the
/// chip its own interactive glass, applied to the button's label so the
/// highlight follows the press.
private struct ResumeChipSkin: ViewModifier {
    let classic: Bool
    let ink: Color

    func body(content: Content) -> some View {
        if classic {
            content
                .background {
                    Capsule()
                        .fill(ink.opacity(0.16))
                        .overlay { Capsule().strokeBorder(ink.opacity(0.12), lineWidth: 0.5) }
                }
                .clipShape(.capsule)
        } else {
            content.appGlassEffect(.clear.interactive(), in: .capsule)
        }
    }
}

// MARK: - Update toast

/// The only thing Minimal Mode says about an update: a count, in a colour, for
/// a moment. It appears when a run finishes — never while it is running, the
/// bar's spinner owns that — and tapping or flicking it sideways clears it.
private struct MinimalUpdateToast: View {
    enum Tone: Equatable {
        case chapters(Int)
        case trouble(Int)

        var text: String {
            switch self {
            case .chapters(let count): "\(count) new \(count == 1 ? "chapter" : "chapters")"
            case .trouble(let count): "\(count) \(count == 1 ? "title" : "titles") failed"
            }
        }

        var symbol: String {
            switch self {
            case .chapters: "sparkles"
            case .trouble: "exclamationmark.triangle"
            }
        }

        var tint: Color {
            switch self {
            case .chapters: AppTheme.accent
            case .trouble: AppTheme.warning
            }
        }
    }

    let tone: Tone
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var dragX: CGFloat = 0

    var body: some View {
        HStack(spacing: 8) {
            AppIcon(systemName: tone.symbol, size: 14)
                .foregroundStyle(tone.tint)
            Text(tone.text)
                .font(Typography.caption.weight(.semibold))
                .foregroundStyle(.white)
            AppIcon(systemName: "xmark", size: 9)
                .foregroundStyle(.white.opacity(0.4))
                .padding(.leading, 2)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .appGlassEffect(.regular.tint(tone.tint.opacity(0.28)).interactive(), in: .capsule)
        .contentShape(.capsule)
        // A sideways flick carries it off; a shorter one springs back. Vertical
        // movement is the pager's, never the toast's.
        .offset(x: dragX)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: dragX)
        .gesture(
            DragGesture(minimumDistance: 12)
                .updating($dragX) { value, current, _ in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    current = value.translation.width
                }
                .onEnded { value in
                    guard abs(value.translation.width) > 60,
                          abs(value.translation.width) > abs(value.translation.height) else { return }
                    dismiss()
                }
        )
        .onTapGesture(perform: dismiss)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tone.text)
        .accessibilityHint("Double tap to dismiss")
    }

    private func dismiss() {
        Haptics.shared.selection()
        onDismiss()
    }
}

// MARK: - Hold box

/// A reference box: writing to it while `body` runs does not invalidate the
/// view.
private final class MinimalHeld<Item> {
    var items: [Item]?
}
