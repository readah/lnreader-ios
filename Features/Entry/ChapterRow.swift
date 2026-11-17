// ChapterRow.swift
// Single chapter row with unread indicator, release time, and status icons.

import SwiftData
import SwiftUI

struct ChapterRow: View {
    @Environment(ReaderRouter.self) private var readerRouter
    @Namespace private var chapterTransition
    @ObservedObject private var audioLibrary = TTSOfflineLibrary.shared
    @State private var showAudioDownloads = false
    /// A hold ends with a lift that the button also reads as a tap; without this
    /// the tap would toggle the row the hold just selected straight back off.
    /// Cleared on the next press-start (see `ChapterRowButtonStyle`), so a long
    /// hold whose lift comes late still suppresses that lift's tap.
    @State private var suppressTap = false
    let chapter: ChapterDisplay
    let entry: Entry?
    let sourceKey: String
    /// Hold-to-select state shared with the list that owns this row. `nil`
    /// where selecting makes no sense (a browse result has no stored chapters).
    var selection: ChapterSelection? = nil
    /// The list's current order, read only when a long press needs a range.
    var orderedPaths: () -> [String] = { [] }
    /// Whether the neighbouring rows are selected too. A run of selected rows is
    /// drawn as one rounded block instead of a fill per row.
    var joinsAbove = false
    var joinsBelow = false
    /// Novel chapter titles rarely carry their number, so the row prints its
    /// position. Off where the caller already shows one (the directory sheet).
    var showsNumber = false
    private var isSelecting: Bool { selection?.isActive == true }
    private var isSelected: Bool { selection?.paths.contains(chapter.path) == true }
    /// Whether the metadata line under the title has anything to show. A row
    /// with no scanlator, date or progress is just the title, so it gets extra
    /// vertical padding to keep the same height as a row that has the line.
    private var hasMetadata: Bool {
        if let scanlator = chapter.scanlator, !scanlator.isEmpty { return true }
        if chapter.releaseDate != nil { return true }
        if chapter.unread, let progress = chapter.progress, progress > 0, progress < 100 { return true }
        return false
    }
    private var bookPath: String { entry?.url ?? chapter.entryURL ?? chapter.path }
    private var bookID: String { TTSBookIdentity.make(pluginId: sourceKey, novelPath: bookPath) }
    private var audioCount: Int { audioLibrary.downloads(bookId: bookID, chapterId: chapter.path).filter(\.isAvailable).count }

    /// The selection circle, shown only while picking. Unread is carried by the
    /// title colour alone, so there is no slot to reserve the rest of the time.
    @ViewBuilder private var leadingIndicator: some View {
        if isSelecting {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .frame(width: 22)
                .accessibilityHidden(true)
        }
    }

    /// Download is offered for stored chapters of titles in the library; local
    /// books are already on disk and a browse result has nothing stored.
    private var showsDownload: Bool { entry?.inLibrary == true && entry?.isLocal == false }

    var body: some View {
        HStack(spacing: 0) {
            mainButton
            if let entry, showsDownload {
                ChapterDownloadControl(entry: entry, chapter: chapter)
                    .padding(.trailing, 8)
                    .opacity(isSelecting ? 0 : 1)
                    .allowsHitTesting(!isSelecting)
            }
        }
        .background { selectionBackground }
    }

    @ViewBuilder private var selectionBackground: some View {
        if isSelected {
            UnevenRoundedRectangle(
                topLeadingRadius: joinsAbove ? 0 : 14, bottomLeadingRadius: joinsBelow ? 0 : 14,
                bottomTrailingRadius: joinsBelow ? 0 : 14, topTrailingRadius: joinsAbove ? 0 : 14,
                style: .continuous)
                .fill(.tint.opacity(0.16))
                .padding(.horizontal, 6)
                .padding(.top, joinsAbove ? 0 : 3)
                .padding(.bottom, joinsBelow ? 0 : 3)
        }
    }

    private var mainButton: some View {
        // One hash and one scan for the row: `audioCount` used to be a computed
        // property read three times in this body, each a SHA256 plus a walk of
        // every download record.
        let audio = audioCount
        return Button {
            if suppressTap {
                suppressTap = false
                return
            }
            if let selection, selection.isActive {
                selection.toggle(chapter.path)
                return
            }
            readerRouter.open(
                chapter,
                sourceKey: sourceKey,
                entryURL: entry?.url ?? chapter.entryURL,
                kind: entry?.kind ?? chapter.kind
            )
        } label: {
            HStack(spacing: 12) {
                leadingIndicator

                if showsNumber {
                    Text(String(chapter.position + 1))
                        .font(Typography.small.monospacedDigit())
                        .foregroundStyle(chapter.unread ? .secondary : .tertiary)
                        .frame(minWidth: 28, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(chapter.name)
                        .font(Typography.body)
                        .foregroundStyle(chapter.unread ? .primary : .secondary)
                        .lineLimit(2)

                    if hasMetadata {
                        HStack(spacing: 8) {
                            if let scanlator = chapter.scanlator, !scanlator.isEmpty {
                                Text(scanlator.prefix(1).uppercased() + scanlator.dropFirst())
                                    .font(Typography.small)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }

                            if let releaseTime = chapter.releaseTime {
                                Text(releaseTime)
                                    .font(Typography.small)
                                    .foregroundStyle(.tertiary)
                            }

                            if chapter.unread, let progress = chapter.progress, progress > 0, progress < 100 {
                                Text("\(progress)%")
                                    .font(Typography.small)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Spacer()

                // Status icons
                HStack(spacing: 8) {
                    if audio > 0 {
                        AppLabel("\(audio)", systemName: "headphones", size: 11, relativeTo: .caption2).font(Typography.small).foregroundStyle(.secondary)
                            .accessibilityLabel("\(audio) voices available offline")
                    }
                    if chapter.bookmarked {
                        AppIcon(systemName: "bookmark.fill", size: 13, relativeTo: .footnote)
                            .foregroundStyle(.primary)
                            .font(Typography.caption)
                    }
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, showsDownload ? 4 : 16)
            .padding(.vertical, hasMetadata ? 10 : 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .bookTransitionSource(chapter.path, in: chapterTransition)
        }
        .buttonStyle(ChapterRowButtonStyle { suppressTap = false })
        // Hold to start selecting; hold another row while selecting to take
        // everything between. Per-chapter actions (download, audio) live in the
        // selection bar, so there is no context menu competing for the hold.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                guard let selection else { return }
                Haptics.shared.impact(.medium)
                suppressTap = true
                if selection.isActive {
                    selection.extend(to: chapter.path, in: orderedPaths())
                } else {
                    selection.begin(chapter.path)
                }
            }
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(chapter.unread ? "Unread" : "Read")
    }
}

// MARK: - Download control

/// A plain button style that reports the start of each press. The row uses it
/// to clear `suppressTap` on a fresh touch, so the lift-tap of a hold (the same
/// touch) stays suppressed while the next real tap is not — no timer involved.
private struct ChapterRowButtonStyle: ButtonStyle {
    let onPressStart: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { onPressStart() }
            }
    }
}

/// The download button at the end of a chapter row. One tap downloads; once a
/// download exists the same spot opens a menu for what can be done to it.
struct ChapterDownloadControl: View {
    let entry: Entry
    let chapter: ChapterDisplay
    private let downloads = ChapterDownloadManager.shared

    private var status: ChapterDownloadStatus {
        downloads.status(sourceKey: entry.sourceKey, entryURL: entry.url,
                         chapterURL: chapter.path, downloaded: entry.isLocal)
    }
    private var item: DownloadItem? { downloads.storedItem(chapter.path, in: entry) }

    var body: some View {
        Group {
            if status == .none {
                Button {
                    Haptics.shared.impact(.light)
                    downloads.download(chapter.path, in: entry)
                } label: { icon }
            } else {
                Menu { menuItems } label: { icon }
            }
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .accessibilityLabel(label)
    }

    @ViewBuilder private var menuItems: some View {
        switch status {
        case .queued:
            Button("Download next", systemImage: "arrow.up.to.line") { if let item { downloads.moveToTop(item) } }
            Button("Cancel download", systemImage: "xmark", role: .destructive) { if let item { downloads.remove(item) } }
        case .downloading:
            Button("Pause", systemImage: "pause") { if let item { downloads.pause(item) } }
            Button("Cancel download", systemImage: "xmark", role: .destructive) { if let item { downloads.remove(item) } }
        case .paused:
            Button("Resume", systemImage: "play") { if let item { downloads.retry(item) } }
            Button("Cancel download", systemImage: "xmark", role: .destructive) { if let item { downloads.remove(item) } }
        case .failed:
            Button("Retry", systemImage: "arrow.clockwise") { if let item { downloads.retry(item) } }
            Button("Remove", systemImage: "xmark", role: .destructive) { if let item { downloads.remove(item) } }
        case .downloaded:
            Button("Delete download", systemImage: "trash", role: .destructive) { if let item { downloads.remove(item) } }
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder private var icon: some View {
        switch status {
        case .none:
            AppIcon(systemName: "arrow.down.circle", size: 25, relativeTo: .body).font(.system(size: 25, weight: .light)).foregroundStyle(.primary)
        case .queued:
            AppIcon(systemName: "ellipsis.circle", size: 25, relativeTo: .body).font(.system(size: 25, weight: .light)).foregroundStyle(.primary)
        case .paused:
            AppIcon(systemName: "pause.circle", size: 25, relativeTo: .body).font(.system(size: 25, weight: .light)).foregroundStyle(.primary)
        case .failed:
            AppIcon(systemName: "exclamationmark.circle", size: 25, relativeTo: .body).font(.system(size: 25, weight: .light)).foregroundStyle(AppTheme.warning)
        case .downloaded:
            AppIcon(systemName: "checkmark.circle.fill", size: 25, relativeTo: .body).font(.system(size: 25)).foregroundStyle(.primary)
        case .downloading(let progress):
            DownloadProgressRing(progress: progress).frame(width: 25, height: 25)
        }
    }

    private var label: String {
        switch status {
        case .none: "Download chapter"
        case .queued: "Download queued"
        case .downloading(let progress): "Downloading, \(Int(progress * 100)) percent"
        case .paused: "Download paused"
        case .failed: "Download failed"
        case .downloaded: "Downloaded"
        }
    }
}

/// A ring that fills as pages arrive; a spinner while nothing has (novels have
/// no page count to report).
struct DownloadProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2.5)
            if progress > 0 {
                Circle()
                    .trim(from: 0, to: min(progress, 1))
                    .stroke(.primary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                AppIcon(systemName: "stop.fill", size: 8, relativeTo: .body).font(.system(size: 8)).foregroundStyle(.primary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}

// MARK: - Selection

/// Which chapters are picked in a chapter list. Owned by the screen that shows
/// the list so its action bar can pin to the screen rather than scroll away.
@Observable
final class ChapterSelection {
    private(set) var isActive = false
    private(set) var paths: Set<String> = []
    /// The row selection grows from: the last one tapped or held.
    private(set) var anchor: String?

    func begin(_ path: String) {
        isActive = true
        paths = [path]
        anchor = path
    }

    func toggle(_ path: String) {
        if paths.contains(path) { paths.remove(path) } else { paths.insert(path); anchor = path }
    }

    /// Add every chapter between the anchor and `path`, inclusive.
    func extend(to path: String, in order: [String]) {
        guard let from = anchor.flatMap({ order.firstIndex(of: $0) }),
              let to = order.firstIndex(of: path) else { paths.insert(path); anchor = path; return }
        paths.formUnion(order[min(from, to)...max(from, to)])
        anchor = path
    }

    /// Everything from the anchor (or the first pick) down to the end of the list.
    func selectBelow(in order: [String]) {
        let start = anchor.flatMap { order.firstIndex(of: $0) }
            ?? order.firstIndex(where: paths.contains) ?? 0
        paths.formUnion(order[start...])
    }

    func selectAll(in order: [String]) { paths = Set(order) }

    func invert(in order: [String]) { paths = Set(order).subtracting(paths) }

    func end() { isActive = false; paths = []; anchor = nil }

    /// Whether the rows around `index` are selected, for drawing runs as one block.
    func neighbours(at index: Int, in order: [ChapterDisplay]) -> (above: Bool, below: Bool) {
        (index > 0 && paths.contains(order[index - 1].path),
         index + 1 < order.count && paths.contains(order[index + 1].path))
    }
}

extension Notification.Name {
    /// Posted after the selection toolbar changes a chapter's read state.
    ///
    /// The detail screen holds its chapter list as `ChapterDisplay` value
    /// snapshots, so writing `Chapter.read` and saving re-renders nothing on its
    /// own. Marking chapters read looked like it did nothing at all.
    static let lnreaderChapterReadChanged = Notification.Name("LNReaderChapterReadChanged")
}

/// Selection actions as a floating glass bar pinned to the bottom of the host:
/// cancel, read state, download and a menu for the rest. Apply with
/// `chapterSelectionToolbar`, so the host's own bottom items stay untouched
/// while nothing is selected. The bar is a `AppGlassEffectContainer`, so entering
/// and leaving selection morphs the controls with the system glass animation.
struct ChapterSelectionToolbar: ViewModifier {    @Environment(\.modelContext) private var modelContext
    @Environment(TrackingManager.self) private var tracking
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Passed on to the audio sheet by hand. The sheet is attached here, below
    /// the detail screen's `.environment(\.coverTint,…)`, so whether it inherits
    /// depends on modifier order — reading it here makes that independent.
    @Environment(\.coverTint) private var coverTint
    let selection: ChapterSelection
    let entry: Entry?
    /// The list the selection was made in, in display order.
    let ordered: [ChapterDisplay]
    /// Every chapter of the book, for "mark previous as read".
    let allChapters: [ChapterDisplay]
    let sourceKey: String
    @State private var showAudio = false

    private var picked: [Chapter] {
        entry?.chapters.filter { selection.paths.contains($0.url) } ?? []
    }
    private var orderedPaths: [String] { ordered.map(\.path) }
    private var canDownload: Bool { entry?.isLocal == false }
    private var bookPath: String { entry?.url ?? "" }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                // Kept mounted and faded like the reader toolbar, so the glass
                // container persists and its controls morph with the system
                // glass animation instead of being rebuilt on every selection.
                ChapterSelectionBar(
                    selection: selection,
                    onMarkRead: { setRead(true) },
                    onMarkUnread: { setRead(false) },
                    moreMenu: { moreMenuItems }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .opacity(selection.isActive ? 1 : 0)
                .allowsHitTesting(selection.isActive)
                .animation(AppMotion.gentle(reduceMotion: reduceMotion), value: selection.isActive)
            }
            .toolbarVisibility(selection.isActive ? .hidden : .automatic, for: .tabBar)
            .preference(key: ClassicTabBarHiddenKey.self, value: selection.isActive)
            .sheet(isPresented: $showAudio) { audioSheet }
    }

    @ViewBuilder private var moreMenuItems: some View {
        Button("Select all below", systemImage: "arrow.down.to.line") { selection.selectBelow(in: orderedPaths) }
        Button("Select all", systemImage: "checklist") { selection.selectAll(in: orderedPaths) }
        Button("Invert selection", systemImage: "arrow.left.arrow.right") { selection.invert(in: orderedPaths) }
        if canDownload {
            Divider()
            Button("Download", systemImage: "arrow.down.circle") { download() }
        }
        Divider()
        Button("Mark previous as read", systemImage: "eye") { markPreviousRead() }
        Button(allBookmarked ? "Remove bookmark" : "Bookmark", systemImage: "bookmark") { toggleBookmark() }
        if selection.paths.count == 1, (entry?.kind ?? .novel) == .novel {
            Button("Chapter audio", systemImage: "headphones") { showAudio = true }
        }
        if canDownload {
            Divider()
            Button("Delete download", systemImage: "trash", role: .destructive) { deleteDownloads() }
        }
    }

    @ViewBuilder private var audioSheet: some View {
        if let chapter = ordered.first(where: { selection.paths.contains($0.path) }) {
            BookAudioDownloadsView(
                bookId: TTSBookIdentity.make(pluginId: sourceKey, novelPath: bookPath),
                bookTitle: entry?.displayTitle ?? chapter.name, sourceKey: sourceKey, entryURL: bookPath,
                chapters: [TTSChapterChoice(chapter)], coverURL: entry?.displayThumbnailURL, initialChapter: chapter.path)
                .environment(\.coverTint, coverTint)
        }
    }

    private var allBookmarked: Bool { !picked.isEmpty && picked.allSatisfy(\.bookmark) }

    // MARK: Actions

    private func finish() {
        try? modelContext.save()
        if let entry { tracking.readStateChanged(entry: entry) }
        LibraryChapterCounts.shared.invalidate(entry.map { [$0.persistentModelID] } ?? [])
        NotificationCenter.default.post(name: .lnreaderChapterReadChanged, object: entry)
        selection.end()
    }

    private func setRead(_ read: Bool) {
        let twins = entry.map(ChapterTwins.hasTwins) ?? false
        for chapter in picked { apply(read: read, to: chapter, twins: twins) }
        if read { ChapterDownloadManager.shared.chaptersMarkedRead(picked) }
        finish()
    }

    private func apply(read: Bool, to chapter: Chapter, twins: Bool) {
        guard chapter.read != read || chapter.progress != (read ? 100 : 0) else { return }
        chapter.read = read
        chapter.progress = read ? 100 : 0
        chapter.paragraphIndex = read ? 0 : nil
        chapter.lastPageRead = 0
        chapter.pagesLeft = 0
        if twins { ChapterTwins.fanOut(from: chapter, read: read, entryHasTwins: true) }
    }

    /// Every chapter numbered below the lowest one picked.
    private func markPreviousRead() {
        guard let floor = allChapters.filter({ selection.paths.contains($0.path) }).map(\.sortNumber).min() else { return }
        let earlier = Set(allChapters.filter { $0.sortNumber < floor }.map(\.path))
        let marked = (entry?.chapters ?? []).filter { earlier.contains($0.url) }
        let twins = entry.map(ChapterTwins.hasTwins) ?? false
        for chapter in marked { apply(read: true, to: chapter, twins: twins) }
        ChapterDownloadManager.shared.chaptersMarkedRead(marked)
        finish()
    }

    private func toggleBookmark() {
        let target = !allBookmarked
        for chapter in picked { chapter.bookmark = target }
        finish()
    }

    private func download() {
        ChapterDownloadManager.shared.enqueue(picked.filter { !$0.isDownloaded })
        selection.end()
    }

    private func deleteDownloads() {
        for item in picked.compactMap(\.downloadItem) { ChapterDownloadManager.shared.remove(item) }
        selection.end()
    }
}

/// The floating selection bar. One glass container of the same interactive
/// glass the reader toolbar uses, so the controls morph in and out together
/// with the system glass animation: a red cancel capsule, the read/unread pair
/// merged into one capsule beside it, and a same-sized menu pushed to the right.
private struct ChapterSelectionBar<MenuItems: View>: View {
    let selection: ChapterSelection
    let onMarkRead: () -> Void
    let onMarkUnread: () -> Void
    @ViewBuilder let moreMenu: () -> MenuItems
    @Namespace private var glass

    var body: some View {
        AppGlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                cancelButton
                    .glassEffectID("cancel", in: glass)
                GlassIconGroup(
                    first: .init(symbol: "eye", label: "Mark as read", action: onMarkRead),
                    second: .init(symbol: "eye.slash", label: "Mark as unread", action: onMarkUnread)
                )
                .glassEffectID("read", in: glass)
                Spacer()
                GlassMenuButton(symbol: "ellipsis", label: "More") { moreMenu() }
                    .glassEffectID("more", in: glass)
            }
        }
    }

    /// Cancel: a red glass capsule the same height as the pair and the menu, so
    /// the three controls line up. The count rides along with the cross.
    private var cancelButton: some View {
        Button { selection.end() } label: {
            HStack(spacing: 6) {
                AppIcon(systemName: "xmark", size: 15, relativeTo: .subheadline)
                Text("\(selection.paths.count)").monospacedDigit()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(height: GlassMetrics.side)
            .padding(.horizontal, 16)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .appGlassEffect(.regular.tint(.red).interactive(), in: .capsule, frostTint: AppTheme.destructive.opacity(0.18))
        .accessibilityLabel("Cancel selection")
        .accessibilityValue("\(selection.paths.count) selected")
    }
}

extension View {
    func chapterSelectionToolbar(
        selection: ChapterSelection, entry: Entry?, ordered: [ChapterDisplay],
        allChapters: [ChapterDisplay], sourceKey: String
    ) -> some View {
        modifier(ChapterSelectionToolbar(
            selection: selection, entry: entry, ordered: ordered,
            allChapters: allChapters, sourceKey: sourceKey))
    }
}
