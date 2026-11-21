// ContentView.swift
// Root view with Liquid Glass tab bar navigation.

import SwiftData
import SwiftUI

/// The root view containing the main tab navigation.
/// Tab bar automatically adopts Liquid Glass when compiled with Xcode 26.
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.springUnblurMotion) private var springUnblurMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(SyncManager.self) private var syncManager
    @Environment(SourceManager.self) private var sourceManager
    @Environment(\.modelContext) private var modelContext
    @AppStorage("general.autoUpdateOnLaunch") private var autoUpdateOnLaunch = false
    @AppStorage(MinimalMode.enabledKey) private var minimalMode = false
    @AppStorage(ChromeAppearance.noLiquidGlassKey) private var noLiquidGlass = false
    @AppStorage(AppearanceTint.enabledKey) private var tintDetails = false
    @AppStorage(AppearanceTint.strengthKey) private var tintStrength = AppearanceTint.defaultStrength
    @State private var classicTabBarHidden = false
    @State private var selectedTab: AppTab = .library
    @State private var readerRouter = ReaderRouter()
    /// Bumped when the History tab is tapped while already showing; resumes the top entry.
    @State private var historyResume = 0
    /// An entry a link asked for. The library pushes it; see `EntryLink`.
    @State private var openedEntry: SourceEntry?

    var body: some View {
        // Minimal Mode is the library alone: no tab bar, no other sections. A
        // vertical swipe on the library's title goes in, and the same swipe on
        // the title inside comes back out. Its three pages — Library, History,
        // Updates — are one vertical pager, so the library can be swapped for
        // either neighbour with a swipe.
        //
        // A crossfade, not the spring-unblur: that transition blurs the whole
        // subtree, and the subtree on the way out of Minimal Mode is the entire
        // library. Blurring hundreds of covers on every frame is what made the
        // switch crawl.
        ZStack {
            if minimalMode {
                MinimalModeView(openedEntry: $openedEntry)
                    .transition(.opacity)
            } else {
                tabRoot
                    .transition(.opacity)
            }
        }
        .animation(springUnblurMotion ? AppMotion.reveal(reduceMotion: reduceMotion) : AppMotion.tabSwitch(reduceMotion: reduceMotion), value: minimalMode)
        .id(ObjectIdentifier(modelContext))
        .overlay(alignment: .top) {
            SyncProgressToast()
                .padding(.horizontal, 16)
                .padding(.top, 8)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                libraryManager.flushProgress(context: modelContext)
                LibraryMaintenance.schedule()
                LibraryMaintenance.scheduleDownloads()
            } else if phase == .active {
                ChapterDownloadManager.shared.resume()
            }
        }
        .environment(readerRouter)
        .environment(\.isReaderPresented, readerRouter.request != nil)
        // A `lnreader://entry` link (see `EntryLink`) opens in the library stack,
        // so Back lands there. The reader is closed first, or the entry would be
        // pushed behind its cover.
        .onOpenURL { url in
            guard let link = EntryLink.parse(url) else { return }
            readerRouter.close()
            selectedTab = .library
            openedEntry = link.sourceEntry
        }
        // The reader is its own window: anything that opens a chapter goes
        // through the router, and this is the single place it is presented.
        .fullScreenCover(
            item: Binding(
                get: { readerRouter.request },
                set: { readerRouter.request = $0 }
            )
        ) { request in
            ChapterReader(
                sourceKey: request.sourceKey,
                entryURL: request.entryURL,
                kind: request.kind,
                chapterURL: request.chapterURL,
                chapterName: request.chapterName,
                highlightParagraph: request.paragraphIndex
            )
            .environment(readerRouter)
        }
        .onChange(of: ObjectIdentifier(modelContext)) { _, _ in
            readerRouter.close()
            ChapterDownloadManager.shared.configure(context: modelContext, sources: sourceManager)
        }
        .task {
            await syncManager.loadSession()
            // Sources are registered in `SourceManager.init`: a link can open an
            // entry before this task gets here.
            ChapterDownloadManager.shared.configure(context: modelContext, sources: sourceManager)
            LibraryMaintenance.schedule()
            // The HTTP stack gets its Cloudflare solver before any source is browsed.
            await CloudflareSolveGate.shared.install(WebKitCloudflareSolver())
            if autoUpdateOnLaunch {
                // A library update is two requests per book plus a merge pass on
                // the main actor. Starting it inside the launch task means the
                // first scroll of the session competes with it. Give the first
                // frame and the first tap a clear run.
                try? await Task.sleep(for: .seconds(2))
                await libraryManager.updateLibrary(context: modelContext, sourceManager: sourceManager, automatic: true)
            }
        }
        // The adapter reads `noLiquidGlass`, so the environment has to be
        // outside it; applied the other way round it always saw the default.
        .modifier(AppRootButtonStyle())
        .environment(\.noLiquidGlass, noLiquidGlass)
        // One slider, one source of truth: every sheet, card and control reads
        // this instead of hard-coding its own tint opacity.
        .environment(\.coverTintStrength, tintDetails ? tintStrength : 0)
    }

    /// The full app: five tabs on Liquid Glass. The tab-only chrome lives here
    /// so it disappears with the tabs in Minimal Mode.
    private var tabRoot: some View {
        TabView(selection: Binding(
            get: { selectedTab },
            set: { tab in
                if tab == .history, selectedTab == .history { historyResume += 1 }
                selectedTab = tab
            }
        )) {
            Tab(value: .library) {
                LibraryView(openedEntry: $openedEntry) {
                    selectedTab = .browse
                }
                .appBackdrop()
                .modifier(AppTabChrome())
            } label: {
                AppTabLabel(title: AppTab.library.title, systemName: AppTab.library.icon)
            }

            Tab(value: .updates) {
                UpdatesView()
                    .appBackdrop()
                .modifier(AppTabChrome())
            } label: {
                AppTabLabel(title: AppTab.updates.title, systemName: AppTab.updates.icon)
            }

            Tab(value: .history) {
                HistoryView(resumeTrigger: historyResume)
                    .appBackdrop()
                .modifier(AppTabChrome())
            } label: {
                AppTabLabel(title: AppTab.history.title, systemName: AppTab.history.icon)
            }

            Tab(value: .browse) {
                BrowseView()
                    .appBackdrop()
                .modifier(AppTabChrome())
            } label: {
                AppTabLabel(title: AppTab.browse.title, systemName: AppTab.browse.icon)
            }

            Tab(value: .more) {
                MoreView()
                    .appBackdrop()
                .modifier(AppTabChrome())
            } label: {
                AppTabLabel(title: AppTab.more.title, systemName: AppTab.more.icon)
            }
        }
        .tabBarMinimizeBehavior(noLiquidGlass ? .never : .onScrollDown)
        // Lists and forms stay clear so each screen's `appBackdrop` reaches the
        // edges instead of sitting around an opaque card.
        .scrollContentBackground(.hidden)
        .modifier(UpdateBannerHost(isActive: libraryManager.updateProgress != nil || BackupManager.shared.progress != nil))
        .overlay(alignment: .bottom) {
            if noLiquidGlass && !classicTabBarHidden {
                ClassicTabBar(selected: selectedTab) { tab in
                    if tab == .history, selectedTab == .history { historyResume += 1 }
                    selectedTab = tab
                }
            }
        }
        .onPreferenceChange(ClassicTabBarHiddenKey.self) { classicTabBarHidden = $0 }
    }
}

private struct SyncProgressToast: View {
    @Environment(SyncManager.self) private var syncManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack {
            if let progress = syncManager.progress {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        AppIcon(systemName: progress.failed ? "exclamationmark.triangle" : (progress.isFinished ? "checkmark.circle" : "arrow.triangle.2.circlepath"), size: 20)
                            .foregroundStyle(progress.failed ? AppTheme.destructive : .primary)
                        Text(progress.failed ? "Sync failed" : (progress.isFinished ? "Sync complete" : progress.title))
                            .font(Typography.headline)
                        Spacer(minLength: 0)
                        if progress.isFinished {
                            Button {
                                Haptics.shared.selection()
                                syncManager.dismissProgress()
                            } label: {
                                AppIcon(systemName: "xmark", size: 15)
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Dismiss sync notification")
                        } else {
                            Text(progress.fraction, format: .percent.precision(.fractionLength(0)))
                                .font(Typography.caption)
                                .monospacedDigit()
                        }
                    }
                    Text(progress.detail)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(progress.failed ? 4 : 2)
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .tint(progress.failed ? AppTheme.destructive : .primary)
                        .accessibilityLabel("Sync progress")
                }
                .padding(16)
                .frame(maxWidth: 420)
                .appGlassEffect(.regular, in: .rect(cornerRadius: 24))
                .appReveal(edge: .top)
                .transition(.move(edge: .top))
            }
        }
        .animation(AppMotion.gentle(reduceMotion: reduceMotion), value: syncManager.progress?.id)
    }
}

/// Puts the library update banner where the system provides a slot for it: the
/// tab bar accessory on iOS 26.1+, a bottom inset before that.
private struct UpdateBannerHost: ViewModifier {
    @Environment(\.noLiquidGlass) private var classic
    let isActive: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content
                .tabViewBottomAccessory(isEnabled: isActive && !classic) { LibraryUpdateBanner() }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if isActive && classic {
                        LibraryUpdateBanner()
                            .background(.thinMaterial, in: .rect(cornerRadius: 22))
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                            .offset(y: -ChromeAppearance.classicTabBarHeight)
                    }
                }
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                if isActive {
                    LibraryUpdateBanner().background(.bar)
                        .padding(.bottom, classic ? 12 : 0)
                        .offset(y: classic ? -ChromeAppearance.classicTabBarHeight : 0)
                }
            }
        }
    }
}

// MARK: - Tab Definition

/// All available tabs in the main navigation
enum AppTab: String, CaseIterable, Identifiable {
    case library
    case updates
    case history
    case browse
    case more

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: "Library"
        case .updates: "Updates"
        case .history: "History"
        case .browse: "Browse"
        case .more: "More"
        }
    }

    var icon: String {
        switch self {
        case .library: "books.vertical"
        case .updates: "bell"
        case .history: "clock"
        case .browse: "safari"
        case .more: "ellipsis"
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Entry.self, Chapter.self, History.self], inMemory: true)
}
