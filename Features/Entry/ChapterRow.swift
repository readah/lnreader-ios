// ChapterRow.swift
// Single chapter row with unread indicator, release time, and status icons.

import QuartzCore
import SwiftData
import SwiftUI
import UIKit

// Shared blur + spring reveal for buttons and selection controls.
private struct BlurSpringReveal: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let visible: Bool
    var scale: CGFloat = 0.86
    var offsetY: CGFloat = 12
    var blurRadius: CGFloat = 8
    var delay: Double = 0

    func body(content: Content) -> some View {
        let animation: Animation = reduceMotion
            ? .easeOut(duration: 0.16)
            : .spring(duration: 0.36, bounce: 0.14).delay(visible ? delay : 0)

        content
            .opacity(visible ? 1 : 0)
            .scaleEffect(visible || reduceMotion ? 1 : scale)
            .offset(y: visible || reduceMotion ? 0 : offsetY)
            .blur(radius: visible || reduceMotion ? 0 : blurRadius)
            .animation(animation, value: visible)
    }
}

extension View {
    func blurSpringReveal(
        _ visible: Bool,
        scale: CGFloat = 0.86,
        offsetY: CGFloat = 12,
        blurRadius: CGFloat = 8,
        delay: Double = 0
    ) -> some View {
        modifier(BlurSpringReveal(
            visible: visible,
            scale: scale,
            offsetY: offsetY,
            blurRadius: blurRadius,
            delay: delay
        ))
    }
}

struct ChapterRow: View {
    @Environment(ReaderRouter.self) private var readerRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var chapterTransition
    @ObservedObject private var audioLibrary = TTSOfflineLibrary.shared
    @State private var showAudioDownloads = false
    let chapter: ChapterDisplay
    let entry: Entry?
    let sourceKey: String
    /// Hold-to-select state shared with the list that owns this row. `nil`
    /// where selecting makes no sense (a browse result has no stored chapters).
    var selection: ChapterSelection? = nil
    /// Whether the neighbouring rows are selected too. A run of selected rows is
    /// drawn as one rounded block instead of a fill per row.
    var joinsAbove = false
    var joinsBelow = false
    /// Novel chapter titles rarely carry their number, so the row prints its
    /// position. Off where the caller already shows one (the directory sheet).
    var showsNumber = false
    private var isSelecting: Bool { selection?.isActive == true }
    private var isSelected: Bool { selection?.paths.contains(chapter.path) == true }
    /// Whether the metadata line under the title has anything to show. Rows are
    /// a fixed minimum height either way; this only decides whether to draw it.
    private var hasMetadata: Bool {
        if let scanlator = chapter.scanlator, !scanlator.isEmpty { return true }
        if chapter.releaseDate != nil { return true }
        if chapter.unread, let progress = chapter.progress, progress > 0, progress < 100 { return true }
        return false
    }
    private var bookPath: String { entry?.url ?? chapter.entryURL ?? chapter.path }
    private var bookID: String { TTSBookIdentity.make(pluginId: sourceKey, novelPath: bookPath) }
    private var audioCount: Int { audioLibrary.downloads(bookId: bookID, chapterId: chapter.path).filter(\.isAvailable).count }

    private var selectionSpring: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .spring(duration: 0.34, bounce: 0.14)
    }

    /// The selection circle. Two static layers cross-fade instead of a symbol
    /// replacement: `ChapterListView` re-evaluates rows whenever `paths` changes,
    /// and `.contentTransition(.symbolEffect(.replace))` replayed on every pass,
    /// flickering the tick on rows that never changed state.
    private var leadingIndicator: some View {
        ZStack {
            Image(systemName: "circle")
                .font(.title3)
                .foregroundStyle(.tertiary)
                .opacity(isSelected ? 0 : 1)

            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .scaleEffect(isSelected ? 1 : 0.4)
                .opacity(isSelected ? 1 : 0)
        }
        .frame(width: 24, height: 24)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: isSelected)
        // Entrance/exit of the indicator column itself.
        .opacity(isSelecting ? 1 : 0)
        .scaleEffect(isSelecting || reduceMotion ? 1 : 0.65)
        .animation(selectionSpring, value: isSelecting)
        .accessibilityHidden(true)
    }

    /// Download is offered for stored chapters of titles in the library; local
    /// books are already on disk and a browse result has nothing stored.
    private var showsDownload: Bool { entry?.inLibrary == true && entry?.isLocal == false }

    var body: some View {
        HStack(spacing: 0) {
            mainButton

            if let entry, showsDownload {
                // The control keeps its 52pt slot at all times. Only opacity and
                // scale change on selection: animating its width (and the
                // indicator's) used to change the title's proposed width on
                // every frame, re-wrapping text and re-measuring every row.
                ChapterDownloadControl(entry: entry, chapter: chapter)
                    .padding(.trailing, 8)
                    .frame(width: 52, height: 44)
                    .opacity(isSelecting ? 0 : 1)
                    .scaleEffect(isSelecting && !reduceMotion ? 0.72 : 1)
                    .allowsHitTesting(!isSelecting)
                    .animation(selectionSpring, value: isSelecting)
            }
        }
        .frame(minHeight: 60)
        .background { selectionBackground }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(ChapterSelection.coordinateSpace))
        } action: { frame in
            selection?.updateFrame(frame, for: chapter.path)
        }
        .onDisappear {
            selection?.removeFrame(for: chapter.path)
        }
    }

    private var selectionBackground: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: joinsAbove ? 0 : 14,
            bottomLeadingRadius: joinsBelow ? 0 : 14,
            bottomTrailingRadius: joinsBelow ? 0 : 14,
            topTrailingRadius: joinsAbove ? 0 : 14,
            style: .continuous
        )
        .fill(.tint.opacity(0.16))
        .padding(.horizontal, 6)
        .padding(.top, joinsAbove ? 0 : 3)
        .padding(.bottom, joinsBelow ? 0 : 3)
        .opacity(isSelected ? 1 : 0)
        .scaleEffect(isSelected || reduceMotion ? 1 : 0.985)
        // No live `.blur(radius:)`: a blurred fill on every visible row cost a
        // separate GPU pass while scrolling and while toggling selection.
        .animation(selectionSpring, value: isSelected)
        .animation(selectionSpring, value: joinsAbove)
        .animation(selectionSpring, value: joinsBelow)
    }

    private var mainButton: some View {
        // One hash and one scan for the row: `audioCount` used to be a computed
        // property read three times in this body, each a SHA256 plus a walk of
        // every download record.
        let audio = audioCount
        return Button {
            if selection?.consumeSuppressedTap() == true { return }
            if let selection, selection.isActive {
                Haptics.shared.selection()
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

                Spacer(minLength: 8)

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
            // Pure GPU shift — Text's proposed width never changes, so rows
            // never reflow. The title glides into the 52pt the download button
            // vacates while the indicator rides in from the leading overlay.
            .offset(x: isSelecting ? 34 : 0)
            .animation(selectionSpring, value: isSelecting)
            .padding(.leading, 16)
            .padding(.trailing, showsDownload ? 4 : 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .overlay(alignment: .leading) {
                leadingIndicator
                    .padding(.leading, 16)
            }
            .contentShape(Rectangle())
            .bookTransitionSource(chapter.path, in: chapterTransition)
        }
        .buttonStyle(AppPlainButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(chapter.unread ? "Unread" : "Read")
    }
}

// MARK: - Download control

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
                AppMenu { menuItems } label: { icon }
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
    static let coordinateSpace = "chapterListSelection"

    private(set) var isDragSelecting = false
    private(set) var paths: Set<String> = []
    /// The row selection grows from: the last one tapped or held.
    private(set) var anchor: String?

    /// Selection mode is exactly "at least one chapter picked", derived from
    /// the picked set instead of kept in a flag of its own.
    ///
    /// A stored flag can be left standing after the set empties — a sweep that
    /// lifted on nothing, a filter change or a list rebuild that dropped the
    /// rows — and the action bar then hangs over a list with no selection at
    /// all, which is the "menu is still visible with nothing selected" bug.
    /// Derived, the two cannot disagree: nothing picked, nothing on screen.
    var isActive: Bool { !paths.isEmpty }

    // Ignored by @Observable so scrolling never triggers re-renders on frame updates.
    @ObservationIgnored private var rowFrames: [String: CGRect] = [:]
    @ObservationIgnored private var dragAnchor: String?
    @ObservationIgnored private var dragBasePaths: Set<String> = []
    @ObservationIgnored private var dragAdding = true
    @ObservationIgnored private var lastDragPath: String?
    /// A hold's lift can still land as a tap on the row's button, since the
    /// recogniser only begins cancelling touches once it reports `.began`. The
    /// button asks `consumeSuppressedTap()` before acting, so that lift never
    /// flips back the row the sweep just selected.
    @ObservationIgnored private var suppressTapUntil: TimeInterval = 0

    /// `true` once for the tap that follows a hold's lift.
    func consumeSuppressedTap() -> Bool {
        guard ProcessInfo.processInfo.systemUptime < suppressTapUntil else { return false }
        suppressTapUntil = 0
        return true
    }

    func updateFrame(_ frame: CGRect, for path: String) {
        rowFrames[path] = frame
    }

    func removeFrame(for path: String) {
        rowFrames.removeValue(forKey: path)
    }

    func path(atY y: CGFloat) -> String? {
        rowFrames.first { _, rect in y >= rect.minY && y <= rect.maxY }?.key
    }

    func begin(_ path: String) {
        paths = [path]
        anchor = path
    }

    /// Starts an Apple Photos-style hold-and-swipe pass. Holding an unselected row
    /// sweeps to add; holding an already-selected row sweeps to deselect.
    ///
    /// A deselect pass never drops the row it started on, so the sweep can begin
    /// from a lone pick without the set — and the bar with it — blinking out.
    func beginDrag(at path: String, in order: [String]) {
        if paths.isEmpty {
            dragBasePaths = []
            dragAdding = true
            paths = [path]
        } else {
            dragBasePaths = paths
            dragAdding = !paths.contains(path)
            if dragAdding { paths.insert(path) }
            else if paths.count > 1 { paths.remove(path) }
        }
        isDragSelecting = true
        anchor = path
        dragAnchor = path
        lastDragPath = path
        suppressTapUntil = ProcessInfo.processInfo.systemUptime + 0.25
    }

    /// Updates the swept range as the finger moves. Returns `true` when crossing into a new row.
    @discardableResult
    func updateDrag(to target: String, in order: [String]) -> Bool {
        guard isDragSelecting,
              target != lastDragPath,
              let start = dragAnchor.flatMap({ order.firstIndex(of: $0) }),
              let end = order.firstIndex(of: target) else { return false }

        lastDragPath = target
        anchor = target
        let range = order[min(start, end)...max(start, end)]
        if dragAdding {
            paths = dragBasePaths.union(range)
        } else {
            let remaining = dragBasePaths.subtracting(range)
            // Keep the anchor: a deselect sweep that covered the whole base
            // still leaves the row it began on picked.
            paths = remaining.isEmpty ? dragBasePaths.intersection([dragAnchor].compactMap { $0 }) : remaining
        }
        return true
    }

    func endDrag() {
        guard isDragSelecting else { return }
        isDragSelecting = false
        dragAnchor = nil
        dragBasePaths = []
        lastDragPath = nil
        suppressTapUntil = ProcessInfo.processInfo.systemUptime + 0.25
        // A sweep that ended on nothing picked has nothing to grow from.
        if paths.isEmpty { anchor = nil }
    }

    func toggle(_ path: String) {
        if paths.contains(path) { paths.remove(path) } else { paths.insert(path); anchor = path }
        if paths.isEmpty { anchor = nil }
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

    func invert(in order: [String]) {
        paths = Set(order).subtracting(paths)
        if paths.isEmpty { anchor = nil }
    }

    func end() {
        endDrag()
        paths = []
        anchor = nil
    }

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
struct ChapterSelectionToolbar: ViewModifier {
    @Environment(\.modelContext) private var modelContext
    @Environment(TrackingManager.self) private var tracking
    @Environment(\.noLiquidGlass) private var noLiquidGlass
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
                // Mounted only while chapters are picked. The bar used to stay
                // mounted and hide behind an opacity of zero, but a
                // `GlassEffectContainer` renders its glass in its own pass, so a
                // faded control could still leave its glass on screen with
                // nothing selected. Building it only when there is a selection
                // removes that path entirely.
                ZStack {
                    if selection.isActive {
                        ChapterSelectionBar(
                            selection: selection,
                            onMarkRead: { setRead(true) },
                            onMarkUnread: { setRead(false) },
                            moreMenu: { moreMenuItems }
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .transition(.blurReplace.combined(with: .offset(y: 12)))
                    }
                }
                // Keep the animation strictly on the overlay. Animating `content`
                // here also animated the bottom safe-area shift caused by
                // `.toolbarVisibility(…, for: .tabBar)`, leaving the bar offset.
                .animation(revealAnimation, value: selection.isActive)
            }
            .toolbarVisibility(noLiquidGlass || selection.isActive ? .hidden : .automatic, for: .tabBar)
            .preference(key: ClassicTabBarHiddenKey.self, value: selection.isActive)
            .appSheet(isPresented: $showAudio) { audioSheet }
    }

    private var revealAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.18) : .spring(duration: 0.34, bounce: 0.12)
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
/// glass the reader toolbar uses: a red cancel capsule, the read/unread pair
/// merged into one capsule beside it, and a same-sized menu pushed to the right.
/// Only built while a selection exists, so nothing of it can outlive the picks.
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
                Text("\(selection.paths.count)")
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(height: GlassMetrics.side)
            .padding(.horizontal, 16)
            .contentShape(.capsule)
        }
        .buttonStyle(AppPlainButtonStyle())
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

// MARK: - Hold-and-swipe recogniser

extension View {
    /// Installs one UIKit long-press recogniser on the enclosing scroll view,
    /// scoped to this view's bounds, so normal scrolling is never intercepted.
    /// A hold then sweeps a selection across the rows, Photos-style.
    func chapterDragSelection(
        _ selection: ChapterSelection?,
        orderedPaths: @escaping () -> [String]
    ) -> some View {
        background {
            if let selection {
                ChapterDragSelectBridge(selection: selection, orderedPaths: orderedPaths)
            }
        }
    }
}

/// Edge auto-scroll for a hold-and-sweep selection. While the finger sits in
/// the top or bottom edge zone, a `CADisplayLink` moves the enclosing scroll
/// view and re-runs the drag hit-test each frame, so rows revealed by the
/// scroll are picked up continuously — the list itself is scroll-disabled
/// during a sweep.
@MainActor
final class DragAutoScroller {
    private var displayLink: CADisplayLink?
    private weak var scrollView: UIScrollView?
    private var velocity: CGFloat = 0          // points per second (+down, -up)
    private var lastTimestamp: CFTimeInterval = 0
    private var onScrollTick: (() -> Void)?

    /// Call on every `.changed` event of the UIKit sweep recognizer.
    /// - Parameters:
    ///   - pointInWindow: `gesture.location(in: nil)`
    ///   - scrollView: The enclosing `UIScrollView` (found via `findScrollView(from:)`).
    ///   - onScrollTick: Re-evaluates the drag hit-test at the current finger position.
    func update(pointInWindow: CGPoint, scrollView: UIScrollView?, onScrollTick: @escaping () -> Void) {
        guard let scrollView, let window = scrollView.window else {
            stop()
            return
        }
        self.scrollView = scrollView
        self.onScrollTick = onScrollTick

        // The scroll view's visible frame, in window coordinates.
        let visibleFrame = scrollView.convert(scrollView.bounds, to: window)
        let topZone: CGFloat = scrollView.adjustedContentInset.top + 68
        let bottomZone: CGFloat = scrollView.adjustedContentInset.bottom + 96 // clears the selection bar
        let maxSpeed: CGFloat = 520

        let distFromTop = pointInWindow.y - visibleFrame.minY
        let distFromBottom = visibleFrame.maxY - pointInWindow.y

        if distFromTop < topZone {
            let intensity = min(max(1 - (distFromTop / topZone), 0), 1)
            velocity = -maxSpeed * (0.2 + 0.8 * intensity * intensity)
            startIfNeeded()
        } else if distFromBottom < bottomZone {
            let intensity = min(max(1 - (distFromBottom / bottomZone), 0), 1)
            velocity = maxSpeed * (0.2 + 0.8 * intensity * intensity)
            startIfNeeded()
        } else {
            stop()
        }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        velocity = 0
        lastTimestamp = 0
        onScrollTick = nil
    }

    private func startIfNeeded() {
        guard displayLink == nil else { return }
        lastTimestamp = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let scrollView, velocity != 0 else { stop(); return }
        let dt = min(link.timestamp - lastTimestamp, 1.0 / 30.0)
        lastTimestamp = link.timestamp

        let minY = -scrollView.adjustedContentInset.top
        let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
        let nextY = min(max(scrollView.contentOffset.y + velocity * CGFloat(dt), minY), maxY)

        if abs(nextY - scrollView.contentOffset.y) > 0.25 {
            scrollView.contentOffset.y = nextY
            onScrollTick?()
        }
    }

    /// Walks up the view hierarchy from a bridge host view to find its `UIScrollView`.
    static func findScrollView(from view: UIView?) -> UIScrollView? {
        var current = view
        while let candidate = current {
            if let scroll = candidate as? UIScrollView { return scroll }
            current = candidate.superview
        }
        return nil
    }
}

/// A long-press on the chapter list that keeps tracking the touch after it
/// begins, so one hold can sweep a selection across rows.
///
/// Attached to the enclosing `UIScrollView` rather than expressed as a SwiftUI
/// `LongPressGesture.sequenced(before: DragGesture(minimumDistance: 0))`: a
/// sequenced drag joins the gesture arena on touch-down and fights the scroll
/// view's pan, so ordinary scrolling stutters. `UILongPressGestureRecognizer`
/// is a continuous UIKit recogniser — movement past `allowableMovement` before
/// the hold fails it and hands the touch straight back to the pan.
private struct ChapterDragSelectBridge: UIViewRepresentable {
    let selection: ChapterSelection
    let orderedPaths: () -> [String]

    func makeCoordinator() -> Coordinator { Coordinator(selection: selection) }

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        context.coordinator.hostView = view
        context.coordinator.orderedPaths = orderedPaths
        view.onAttach = { [weak coordinator = context.coordinator] in
            coordinator?.attachIfNeeded()
        }
        return view
    }

    func updateUIView(_ uiView: HostView, context: Context) {
        context.coordinator.selection = selection
        context.coordinator.orderedPaths = orderedPaths
        context.coordinator.attachIfNeeded()
    }

    static func dismantleUIView(_ uiView: HostView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class HostView: UIView {
        var onAttach: (() -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            onAttach?()
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var selection: ChapterSelection
        var orderedPaths: () -> [String] = { [] }
        weak var hostView: UIView?

        private weak var scrollView: UIScrollView?
        private var recognizer: UILongPressGestureRecognizer?
        private let autoScroller = DragAutoScroller()

        init(selection: ChapterSelection) {
            self.selection = selection
        }

        func attachIfNeeded() {
            guard let hostView, hostView.window != nil else { return }
            guard let target = findScrollView(from: hostView) else { return }
            if scrollView === target, recognizer != nil { return }

            detach()
            let press = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            press.minimumPressDuration = 0.35
            press.allowableMovement = 10
            press.cancelsTouchesInView = true
            press.delaysTouchesBegan = false
            press.delegate = self
            target.addGestureRecognizer(press)

            scrollView = target
            recognizer = press
        }

        func detach() {
            autoScroller.stop()
            if let recognizer {
                scrollView?.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            scrollView = nil
        }

        /// Walks up for a `ScrollView` (the `LazyVStack` case), or searches
        /// siblings for the `List`'s backing collection view.
        private func findScrollView(from view: UIView) -> UIScrollView? {
            var current: UIView? = view.superview
            while let node = current {
                if let scrollView = node as? UIScrollView { return scrollView }
                current = node.superview
            }
            return view.superview.flatMap(firstScrollView(in:))
        }

        private func firstScrollView(in root: UIView) -> UIScrollView? {
            if let scrollView = root as? UIScrollView { return scrollView }
            for subview in root.subviews {
                if let found = firstScrollView(in: subview) { return found }
            }
            return nil
        }

        @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let hostView else { return }
            let location = gesture.location(in: hostView)

            switch gesture.state {
            case .began:
                guard let path = selection.path(atY: location.y) else {
                    // Not on a row: hand the touch back to the scroll view.
                    gesture.isEnabled = false
                    gesture.isEnabled = true
                    return
                }
                Haptics.shared.impact(.medium)
                selection.beginDrag(at: path, in: orderedPaths())

            case .changed:
                updateSelection(for: gesture)

                // Keep sweeping as the list auto-scrolls under a finger held at
                // an edge. The tick re-runs the same hit-test at the live touch.
                autoScroller.update(
                    pointInWindow: gesture.location(in: nil),
                    scrollView: scrollView
                ) { [weak self, weak gesture] in
                    guard let self, let gesture else { return }
                    self.updateSelection(for: gesture)
                }

            case .ended, .cancelled, .failed:
                autoScroller.stop()
                selection.endDrag()

            default:
                break
            }
        }

        /// Re-runs the row hit-test and extends the swept range at the gesture's
        /// current location. Shared by the gesture callback and the display-link
        /// auto-scroll tick.
        private func updateSelection(for gesture: UILongPressGestureRecognizer) {
            guard let hostView else { return }
            let y = gesture.location(in: hostView).y
            if let target = selection.path(atY: y),
               selection.updateDrag(to: target, in: orderedPaths()) {
                Haptics.shared.selection()
            }
        }

        /// Only begin when the hold lands inside the chapter list's bounds, so
        /// holds on the hero title or the Continue button stay untouched.
        nonisolated func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            MainActor.assumeIsolated {
                guard let hostView, hostView.window != nil else { return false }
                let point = gestureRecognizer.location(in: hostView)
                guard hostView.bounds.contains(point) else { return false }
                return selection.path(atY: point.y) != nil
            }
        }

        /// Never run alongside the scroll view's pan: a quick drag scrolls at
        /// once, while a 0.35s hold locks the pan out for the sweep.
        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            MainActor.assumeIsolated { otherGestureRecognizer !== scrollView?.panGestureRecognizer }
        }
    }
}
