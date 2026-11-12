// ContentView.swift
// Root view with Liquid Glass tab bar navigation.

import SwiftData
import SwiftUI

/// The root view containing the main tab navigation.
/// Tab bar automatically adopts Liquid Glass when compiled with Xcode 26.
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(SyncManager.self) private var syncManager
    @Environment(SourceManager.self) private var sourceManager
    @Environment(\.modelContext) private var modelContext
    @AppStorage("general.autoUpdateOnLaunch") private var autoUpdateOnLaunch = false
    @State private var selectedTab: AppTab = .library
    @State private var readerRouter = ReaderRouter()
    /// Bumped when the History tab is tapped while already showing; resumes the top entry.
    @State private var historyResume = 0
    /// An entry a link asked for. The library pushes it; see `EntryLink`.
    @State private var openedEntry: SourceEntry?

    var body: some View {
        TabView(selection: Binding(
            get: { selectedTab },
            set: { tab in
                if tab == .history, selectedTab == .history { historyResume += 1 }
                selectedTab = tab
            }
        )) {
            Tab(AppTab.library.title, systemImage: AppTab.library.icon, value: .library) {
                LibraryView(openedEntry: $openedEntry)
            }

            Tab(AppTab.updates.title, systemImage: AppTab.updates.icon, value: .updates) {
                UpdatesView()
            }

            Tab(AppTab.history.title, systemImage: AppTab.history.icon, value: .history) {
                HistoryView(resumeTrigger: historyResume)
            }

            Tab(AppTab.browse.title, systemImage: AppTab.browse.icon, value: .browse) {
                BrowseView()
            }

            Tab(AppTab.more.title, systemImage: AppTab.more.icon, value: .more) {
                MoreView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .modifier(UpdateBannerHost(isActive: libraryManager.updateProgress != nil || BackupManager.shared.progress != nil))
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
                chapterName: request.chapterName
            )
            .environment(readerRouter)
        }
        .task {
            await syncManager.loadSession()
            // The server is the source of truth, so catch up with it before
            // anything can push over it. Best effort: a launch on a dead network
            // must not surface an error or hold up the library.
            await syncManager.pull(into: modelContext, quiet: true)
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
    }
}

/// Puts the library update banner where the system provides a slot for it: the
/// tab bar accessory on iOS 26.1+, a bottom inset before that.
private struct UpdateBannerHost: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: isActive) { LibraryUpdateBanner() }
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                if isActive { LibraryUpdateBanner().background(.bar) }
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
