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
            Tab(value: .library) {
                LibraryView(openedEntry: $openedEntry) {
                    selectedTab = .browse
                }
            } label: {
                AppTabLabel(title: AppTab.library.title, systemName: AppTab.library.icon)
            }

            Tab(value: .updates) {
                UpdatesView()
            } label: {
                AppTabLabel(title: AppTab.updates.title, systemName: AppTab.updates.icon)
            }

            Tab(value: .history) {
                HistoryView(resumeTrigger: historyResume)
            } label: {
                AppTabLabel(title: AppTab.history.title, systemName: AppTab.history.icon)
            }

            Tab(value: .browse) {
                BrowseView()
            } label: {
                AppTabLabel(title: AppTab.browse.title, systemName: AppTab.browse.icon)
            }

            Tab(value: .more) {
                MoreView()
            } label: {
                AppTabLabel(title: AppTab.more.title, systemName: AppTab.more.icon)
            }
        }
        .id(ObjectIdentifier(modelContext))
        .overlay(alignment: .top) {
            SyncProgressToast()
                .padding(.horizontal, 16)
                .padding(.top, 8)
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
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
                .transition(.move(edge: .top))
            }
        }
        .animation(AppMotion.gentle(reduceMotion: reduceMotion), value: syncManager.progress?.id)
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
