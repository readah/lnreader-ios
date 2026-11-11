// WebtoonStrip.swift - The webtoon's vertical strip, as a collection view.
//
// A SwiftUI `LazyVStack` guesses the height of rows it has not built and
// corrects the content size as it builds them, which makes scrolling up
// reluctant and jittery. Here every row has an explicit height: the page's real
// aspect ratio once known (read from the image header), a guess until then.

import SwiftUI
import UIKit
import os

/// Debug builds log any strip step that takes over 4 ms (a frame is 8 at 120 Hz),
/// under subsystem `com.lnreader`, category `strip`. Release builds compile it out.
private struct StripTimer {
    #if DEBUG
    private static let logger = Logger(subsystem: "com.lnreader", category: "strip")
    private let label: StaticString
    private let start = CACurrentMediaTime()
    init(_ label: StaticString) { self.label = label }
    func end() {
        let ms = (CACurrentMediaTime() - start) * 1000
        if ms > 4 { Self.logger.warning("\(label) took \(ms, format: .fixed(precision: 1)) ms") }
    }
    #else
    init(_ label: StaticString) {}
    func end() {}
    #endif
}

/// One chapter's pages in the strip. Chapters are stitched end to end, each
/// followed by a divider card naming the next one.
struct WebtoonSegment {
    /// The chapter's URL.
    let id: String
    let pages: [SourcePage]
    /// Title of the chapter that follows; `nil` when there is none, which also drops the divider.
    let nextTitle: String?
}

/// What a row of the strip shows.
private enum WebtoonItem {
    case page(segment: Int, index: Int, page: SourcePage)
    /// The divider after a segment. `loading` while the next chapter is still being fetched.
    case divider(segment: Int, title: String, loading: Bool)
}

struct WebtoonStrip: UIViewControllerRepresentable {
    let segments: [WebtoonSegment]
    let sourceKey: String
    let loader: PageLoader
    /// Page of the first segment to open on. Only read when the strip is built.
    let startIndex: Int
    /// Page width as a share of the screen; the rest is still margin.
    let widthFraction: CGFloat
    let controller: WebtoonScrollController
    /// The page at the top of the screen changed: its chapter and index in it.
    let onPageChange: (String, Int) -> Void
    /// The divider after this chapter became fully visible; `nil` when none is.
    let onEndCard: (String?) -> Void
    /// A tap, in the strip's own (screen) coordinates.
    let onTap: (CGPoint) -> Void

    func makeUIViewController(context: Context) -> WebtoonViewController {
        let vc = WebtoonViewController(startIndex: startIndex, controller: controller)
        apply(to: vc)
        return vc
    }

    func updateUIViewController(_ vc: WebtoonViewController, context: Context) {
        apply(to: vc)
    }

    private func apply(to vc: WebtoonViewController) {
        vc.sourceKey = sourceKey
        vc.loader = loader
        vc.onPageChange = onPageChange
        vc.onEndCard = onEndCard
        vc.onTap = onTap
        vc.setWidthFraction(widthFraction)
        vc.update(segments: segments)
    }
}

@MainActor
final class WebtoonViewController: UIViewController,
    UICollectionViewDataSource, UICollectionViewDelegateFlowLayout,
    UICollectionViewDataSourcePrefetching, UIGestureRecognizerDelegate {

    /// Height guess for a page whose size is not known yet. Real heights come
    /// from the first bytes of the image (`PageImageCache.aspectRatios`) and
    /// replace it without moving what is on screen.
    private static let fallbackRatio: CGFloat = 0.7
    private static let dividerHeight: CGFloat = 220

    var sourceKey = ""
    var loader: PageLoader?
    var onPageChange: ((String, Int) -> Void)?
    var onEndCard: ((String?) -> Void)?
    var onTap: ((CGPoint) -> Void)?

    private let startIndex: Int
    private let controller: WebtoonScrollController
    private var segments: [WebtoonSegment] = []
    private var items: [WebtoonItem] = []
    private var indexByURL: [String: [Int]] = [:]

    private let layout = UICollectionViewFlowLayout()
    private var collectionView: UICollectionView!
    private let scrollbar = WebtoonScrollbar()
    private var segmentPageRanges: [Int: (first: Int, last: Int)] = [:]
    private var activeSegmentIndex: Int = 0
    private var didRestore = false
    private var lastReported: Int
    private var endCardSegment: String?
    private var lastWidth: CGFloat = 0
    private var widthFraction: CGFloat = 1
    private var pendingRatios: Set<Int> = []
    private var flushScheduled = false
    private var observer: NSObjectProtocol?
    private var touchStoppedScroll = false
    private var lastScrollTime: CFTimeInterval = 0
    private var speedometer = ScrollSpeedometer()
    private var detents = ScrollDetents()
    private var chapterMarks = ScrollChapterMarks()
    private var edgeBump = ScrollEdgeBump()

    init(startIndex: Int, controller: WebtoonScrollController) {
        self.startIndex = startIndex
        self.lastReported = startIndex
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = .zero

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .black
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.showsVerticalScrollIndicator = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.isPrefetchingEnabled = true
        collectionView.register(WebtoonPageCell.self, forCellWithReuseIdentifier: WebtoonPageCell.reuseID)
        collectionView.register(WebtoonEndCell.self, forCellWithReuseIdentifier: WebtoonEndCell.reuseID)
        view.addSubview(collectionView)

        scrollbar.frame = CGRect(x: view.bounds.width - 40, y: 0, width: 40, height: view.bounds.height)
        scrollbar.autoresizingMask = [.flexibleHeight, .flexibleLeftMargin]
        scrollbar.onScrub = { [weak self] progress in self?.scrub(to: progress) }
        scrollbar.onScrubActivity = { [weak self] in self?.controller.onScrollActivity?() }
        scrollbar.onTap = { [weak self] point in self?.onTap?(point) }
        view.addSubview(scrollbar)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        collectionView.addGestureRecognizer(tap)

        controller.attach(collectionView)
        Haptics.shared.prepare()
        controller.jumpToPage = { [weak self] chapter, index in
            guard let self, let item = self.items.firstIndex(where: {
                if case let .page(segment, pageIndex, _) = $0 {
                    return self.segments[segment].id == chapter && pageIndex == index
                }
                return false
            }) else { return }
            self.jump(to: item)
        }

        observer = NotificationCenter.default.addObserver(
            forName: PageImageCache.ratioLearned, object: nil, queue: .main
        ) { [weak self] note in
            guard let key = note.object as? String else { return }
            MainActor.assumeIsolated { self?.ratioLearned(forURL: key) }
        }
    }

    // MARK: Data

    /// Segments the reader asked for whose leading chapters are still on the
    /// strip, waiting for it to stop moving (`applyDeferredTrim`).
    private var deferredSegments: [WebtoonSegment]?

    func update(segments newSegments: [WebtoonSegment]) {
        let timer = StripTimer("update segments"); defer { timer.end() }
        let dropped = StripWindow.leadingDrop(oldCount: segments.count, newCount: newSegments.count) {
            Self.same(segments[$0], newSegments[$1])
        }
        // Removing rows above the screen shifts the offset under the finger and
        // would cut a fling short; it waits until the strip is at rest. Anything
        // appended meanwhile goes in now, behind the rows still waiting to go.
        if let dropped, dropped > 0, isViewLoaded, isMoving {
            deferredSegments = newSegments
            apply(Array(segments.prefix(dropped)) + newSegments, dropped: 0)
            return
        }
        deferredSegments = nil
        apply(newSegments, dropped: dropped)
    }

    private static func same(_ a: WebtoonSegment, _ b: WebtoonSegment) -> Bool {
        a.id == b.id && a.nextTitle == b.nextTitle && a.pages.count == b.pages.count
            && zip(a.pages, b.pages).allSatisfy { $0.url == $1.url }
    }

    /// Auto scroll and hold-scroll move the offset from a display link, which the
    /// scroll view does not report as dragging: without this a trim or a height
    /// correction would land mid-crawl and show as a jump.
    private var isMoving: Bool {
        collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating
            || controller.isAutoScrolling || controller.holdSpeed != nil
    }

    private func applyDeferredTrim() {
        guard !isMoving else { return }
        if !pendingRatios.isEmpty {
            flushRatios()
        }
        guard let pending = deferredSegments else { return }
        deferredSegments = nil
        update(segments: pending)
    }

    /// - Parameter dropped: segments removed from the front, the rest kept or
    ///   appended; `nil` when the change is something else.
    private func apply(_ newSegments: [WebtoonSegment], dropped: Int?) {
        let timer = StripTimer("apply segments"); defer { timer.end() }
        let unchanged = dropped == 0 && newSegments.count == segments.count
        guard !unchanged else { return }
        let oldItems = items
        let removedRows = dropped.map { count in
            oldItems.prefix { item in
                switch item {
                case let .page(segment, _, _), let .divider(segment, _, _): segment < count
                }
            }.count
        } ?? 0
        segments = newSegments
        var built: [WebtoonItem] = []
        var lookup: [String: [Int]] = [:]
        var ranges: [Int: (first: Int, last: Int)] = [:]
        for (segment, entry) in newSegments.enumerated() {
            let start = built.count
            for (index, page) in entry.pages.enumerated() {
                lookup[page.url, default: []].append(built.count)
                built.append(.page(segment: segment, index: index, page: page))
            }
            if !entry.pages.isEmpty {
                ranges[segment] = (first: start, last: built.count - 1)
            }
            if let title = entry.nextTitle {
                built.append(.divider(segment: segment, title: title, loading: segment == newSegments.count - 1))
            }
        }
        items = built
        indexByURL = lookup
        segmentPageRanges = ranges
        if let dropped, dropped > 0 {
            activeSegmentIndex = max(0, activeSegmentIndex - dropped)
        }
        if activeSegmentIndex >= segments.count {
            activeSegmentIndex = max(0, segments.count - 1)
        }
        // Row numbers waiting on a height, and the last reported row, follow
        // the rows they meant.
        pendingRatios = Set(pendingRatios.map { $0 - removedRows }.filter { $0 >= 0 && $0 < built.count })
        lastReported = max(lastReported - removedRows, 0)
        guard isViewLoaded else { return }
        let kept = oldItems.count - removedRows
        guard dropped != nil, !segments.isEmpty, kept > 0, built.count >= kept else {
            return collectionView.reloadData()
        }

        // Whatever is above the first kept row goes, and the offset moves up by
        // the same height, so the page on screen stays where it is.
        let removedHeight = removedRows > 0
            ? layout.layoutAttributesForItem(at: IndexPath(item: removedRows, section: 0))?.frame.minY ?? 0
            : 0
        let target = collectionView.contentOffset.y - removedHeight
        // The divider that was last stops showing its spinner.
        let refreshed = built.count > kept ? oldItems.indices.last.flatMap { index -> IndexPath? in
            if case .divider = oldItems[index] { return IndexPath(item: index, section: 0) }
            return nil
        } : nil
        UIView.performWithoutAnimation {
            // Indices in one batch: deletes against the old rows,
            // inserts against the new.
            collectionView.performBatchUpdates {
                if removedRows > 0 {
                    collectionView.deleteItems(at: (0..<removedRows).map { IndexPath(item: $0, section: 0) })
                }
                if built.count > kept {
                    collectionView.insertItems(at: (kept..<built.count).map { IndexPath(item: $0, section: 0) })
                }
            }
        }
        if let refreshed, let cell = collectionView.cellForItem(at: refreshed) as? WebtoonEndCell,
           case let .divider(_, title, loading) = items[refreshed.item] {
            cell.show(title: title, loading: loading)
        }
        if removedRows > 0 {
            collectionView.contentOffset.y = max(target, 0)
        }
    }

    private var itemCount: Int { items.count }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { itemCount }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        switch items[indexPath.item] {
        case let .divider(_, title, loading):
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: WebtoonEndCell.reuseID, for: indexPath) as! WebtoonEndCell
            cell.show(title: title, loading: loading)
            return cell
        case let .page(_, _, page):
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: WebtoonPageCell.reuseID, for: indexPath) as! WebtoonPageCell
            if let loader {
                // Decoded for the full screen width whatever the strip width:
                // the cache keeps one bitmap per page, and widening the strip
                // again must not stretch one decoded for a narrower strip.
                cell.show(
                    page: page,
                    sourceKey: sourceKey,
                    loader: loader,
                    targetWidth: collectionView.bounds.width * traitCollection.displayScale,
                    scale: traitCollection.displayScale
                )
            }
            return cell
        }
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        guard let loader else { return }
        let wanted: [SourcePage] = indexPaths.compactMap {
            if case let .page(_, _, page) = items[$0.item] { return page }
            return nil
        }
        PagePrerender.prime(
            wanted,
            sourceKey: sourceKey,
            loader: loader,
            targetWidth: collectionView.bounds.width * traitCollection.displayScale,
            screenScale: traitCollection.displayScale
        )
    }

    // MARK: Sizing

    private func height(forItem item: Int, width: CGFloat) -> CGFloat {
        guard case let .page(_, _, page) = items[item] else { return Self.dividerHeight }
        let ratio = PageImageCache.aspectRatios[page.url] ?? Self.fallbackRatio
        let scale = max(traitCollection.displayScale, 1)
        // Whole device pixels, so neighbouring pages never leave a seam.
        return (width / max(ratio, 0.01) * scale).rounded() / scale
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let width = max(pageWidth, 1)
        return CGSize(width: width, height: height(forItem: indexPath.item, width: width))
    }

    /// The strip's width in whole device pixels, so its edges never blur.
    private var pageWidth: CGFloat {
        let scale = max(traitCollection.displayScale, 1)
        return (collectionView.bounds.width * widthFraction * scale).rounded() / scale
    }

    /// Centre the strip between equal margins. The collection view itself stays
    /// full width, so a drag or tap in the margin still scrolls.
    private func applyMargins() {
        let side = max(0, (collectionView.bounds.width - pageWidth) / 2)
        layout.sectionInset = UIEdgeInsets(top: 0, left: side, bottom: 0, right: side)
    }

    /// Narrow or widen the strip, keeping the same spot of the same page at
    /// the top of the screen.
    func setWidthFraction(_ fraction: CGFloat) {
        guard fraction != widthFraction else { return }
        guard isViewLoaded, collectionView.bounds.width > 0, itemCount > 0 else {
            widthFraction = fraction
            return
        }
        let top = collectionView.contentOffset.y
        let anchor = collectionView.indexPathForItem(at: CGPoint(x: collectionView.bounds.midX, y: top + 0.5))
        let progress = anchor.flatMap { layout.layoutAttributesForItem(at: $0)?.frame }
            .map { ($0.height > 0 ? (top - $0.minY) / $0.height : 0) } ?? 0

        widthFraction = fraction
        applyMargins()
        layout.invalidateLayout()
        collectionView.layoutIfNeeded()

        guard let anchor, let frame = layout.layoutAttributesForItem(at: anchor)?.frame else { return }
        let target = min(max(frame.minY + progress * frame.height, 0), maxOffsetY)
        collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
    }

    /// A page's real aspect ratio just became known. Resize its slot; if the
    /// slot is above the screen, shift the offset by the same amount so what the
    /// reader is looking at does not move.
    private func ratioLearned(forURL url: String) {
        guard let indices = indexByURL[url] else { return }
        pendingRatios.formUnion(indices)
        guard !flushScheduled else { return }
        flushScheduled = true
        let delay: DispatchTime = isMoving ? .now() + 0.1 : .now()
        DispatchQueue.main.asyncAfter(deadline: delay) { [weak self] in self?.flushRatios() }
    }

    private func flushRatios() {
        let timer = StripTimer("flushRatios"); defer { timer.end() }
        flushScheduled = false
        let indices = pendingRatios
        pendingRatios = []
        let width = pageWidth
        guard width > 0 else { return }

        let top = collectionView.contentOffset.y
        var adjustment: CGFloat = 0
        var changed = false
        for index in indices {
            guard let old = layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { continue }
            let delta = height(forItem: index, width: width) - old.height
            guard abs(delta) >= 0.5 else { continue }
            changed = true
            if old.maxY <= top { adjustment += delta }
        }
        guard changed else { return }

        // If the strip is currently moving and there's an offset adjustment
        // (meaning rows above the viewport changed height), adjusting contentOffset
        // under the user's finger would cause a jump or interrupt momentum.
        // Defer offset adjustments until the strip is at rest.
        if isMoving && abs(adjustment) > 0 {
            pendingRatios.formUnion(indices)
            return
        }

        let context = UICollectionViewFlowLayoutInvalidationContext()
        context.invalidateFlowLayoutDelegateMetrics = true
        context.contentOffsetAdjustment = CGPoint(x: 0, y: adjustment)
        layout.invalidateLayout(with: context)
        updateScrollbar()
    }

    // MARK: Layout and position

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = collectionView.bounds.width
        guard width > 0 else { return }
        if lastWidth != width {
            lastWidth = width
            applyMargins()
            layout.invalidateLayout()
        }
        if !didRestore, itemCount > 0 {
            didRestore = true
            // Measure first: unmeasured rows are stubs at y = 0, and the report
            // below would read that as a strip scrolled to its end.
            collectionView.layoutIfNeeded()
            if startIndex > 0 { jump(to: startIndex) }
            // A strip that fits on screen, or restores to offset 0, never scrolls.
            scrollViewDidScroll(collectionView)
        }
        updateScrollbar()
    }

    private var maxOffsetY: CGFloat {
        max(0, collectionView.contentSize.height - collectionView.bounds.height)
    }

    private func jump(to index: Int) {
        guard itemCount > 0 else { return }
        collectionView.layoutIfNeeded()
        let item = min(max(index, 0), itemCount - 1)
        guard let frame = layout.layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame else { return }
        collectionView.setContentOffset(CGPoint(x: 0, y: min(frame.minY, maxOffsetY)), animated: false)
    }

    // MARK: Reporting

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let timer = StripTimer("scrollViewDidScroll"); defer { timer.end() }
        lastScrollTime = CACurrentMediaTime()
        guard didRestore else { return }
        let userDriven = scrollView.isDragging || scrollView.isDecelerating
        if userDriven { controller.onScrollActivity?() }
        let top = scrollView.contentOffset.y
        let bottom = top + scrollView.bounds.height
        playScrollHaptics(top: top, userDriven: userDriven)

        var current: Int?
        var endSegment: String?
        for path in collectionView.indexPathsForVisibleItems.sorted() {
            guard let frame = layout.layoutAttributesForItem(at: path)?.frame, frame.height > 0 else { continue }
            let visible = min(frame.maxY, bottom) - max(frame.minY, top)
            switch items[path.item] {
            case let .divider(segment, _, _):
                if visible >= frame.height * 0.95 { endSegment = segments[segment].id }
            case let .page(segment, index, _):
                if current == nil, visible >= frame.height * 0.05 { current = path.item }
                // A chapter's last page scrolled fully into view finishes it, even
                // when the divider after it cannot reach 95% (it can sit under the
                // bottom inset, or be a stub while the next chapter loads).
                if index == segments[segment].pages.count - 1, bottom >= frame.maxY - 2 {
                    endSegment = segments[segment].id
                }
            }
        }
        // At the very bottom the top row can be a page or two short of the last
        // one; the reader has still reached it.
        // Judged by the last row's own edge rather than the offset limit, which
        // is off by the insets and by rows that resized after loading.
        // Only for a strip that scrolls: unmeasured, or shorter than the screen,
        // the last row is on screen at offset 0 too.
        if maxOffsetY > 0, let last = items.indices.last, case .page = items[last],
           let frame = layout.layoutAttributesForItem(at: IndexPath(item: last, section: 0))?.frame,
           frame.height > 0,
           bottom >= frame.maxY - 2 || top >= maxOffsetY - 1 {
            current = last
        }
        if let current, case let .page(segment, index, _) = items[current] {
            activeSegmentIndex = segment
            if current != lastReported {
                lastReported = current
                onPageChange?(segments[segment].id, index)
            }
        }
        if endSegment != endCardSegment {
            endCardSegment = endSegment
            onEndCard?(endSegment)
        }
        updateScrollbar()
    }

    /// Top and height of the active chapter's pages in the strip, once laid out.
    private var activeChapterSpan: (startY: CGFloat, height: CGFloat)? {
        guard let range = segmentPageRanges[activeSegmentIndex],
              let first = layout.layoutAttributesForItem(at: IndexPath(item: range.first, section: 0))?.frame,
              let last = layout.layoutAttributesForItem(at: IndexPath(item: range.last, section: 0))?.frame,
              first.height > 0, last.height > 0, last.maxY > first.minY
        else { return nil }
        return (first.minY, last.maxY - first.minY)
    }

    private func updateScrollbar() {
        guard !scrollbar.isDragging, let span = activeChapterSpan else { return }
        let viewportHeight = collectionView.bounds.height
        guard viewportHeight > 0 else { return }

        let maxOffset = max(1, span.height - viewportHeight)
        let currentOffset = min(max(collectionView.contentOffset.y - span.startY, 0), maxOffset)
        let thumbRatio = min(1.0, max(0.08, viewportHeight / span.height))
        scrollbar.setProgress(currentOffset / maxOffset, thumbRatio: thumbRatio)
    }

    private func scrub(to progress: CGFloat) {
        guard let span = activeChapterSpan else { return }
        let maxOffset = max(0, span.height - collectionView.bounds.height)
        let startY = span.startY
        let targetY = min(max(startY + progress * maxOffset, 0), maxOffsetY)

        controller.stopAuto()
        collectionView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
        playScrollHaptics(top: targetY, userDriven: true)
    }

    // A trim held back while the strip moved goes in once it stops.
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { applyDeferredTrim() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { applyDeferredTrim() }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { applyDeferredTrim() }

    // MARK: Haptics

    /// A steady tick as the strip moves, a chapter cue as a divider reaches the
    /// middle of the screen, a thud on running into either end. Only for the
    /// reader's own drag and its momentum: hold, auto scroll and jumps are silent.
    private func playScrollHaptics(top: CGFloat, userDriven: Bool) {
        let now = CACurrentMediaTime()
        let speed = speedometer.sample(offset: Double(top), time: now)
        let line = CGPoint(x: collectionView.bounds.midX, y: top + collectionView.bounds.height / 2)
        let row = collectionView.indexPathForItem(at: line)?.item
        var isDivider = false
        if let row, items.indices.contains(row), case .divider = items[row] { isDivider = true }
        // Every tracker sees every frame, so none loses its place when another fires.
        let detent = detents.update(offset: Double(top), speed: speed, time: now, userDriven: userDriven)
        let chapter = chapterMarks.update(row: row, isChapterBreak: isDivider, speed: speed, userDriven: userDriven)
        let edge = edgeBump.update(offset: Double(top), minOffset: 0, maxOffset: Double(maxOffsetY),
                                   speed: speed, userDriven: userDriven)
        if let cue = edge ?? chapter ?? detent { Haptics.shared.scroll(cue) }
    }

    // MARK: Taps

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        // A finger that landed to stop the strip is not a tap: it would hit a
        // tap zone and scroll a screenful the moment the reader stops to read.
        guard !touchStoppedScroll else { return }
        onTap?(gesture.location(in: view))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // The scroll view halts its momentum as the touch lands, so by the time
        // the tap is recognised it no longer says it was moving; remember it now.
        touchStoppedScroll = collectionView.isDecelerating
            || collectionView.isDragging
            || CACurrentMediaTime() - lastScrollTime < 0.1
        return !(touch.view is UIControl)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
}

/// A vertical scrollbar that represents and controls progress within the current chapter.
@MainActor
final class WebtoonScrollbar: UIControl {
    private let thumbView = UIView()
    private var hideTimer: Timer?
    private(set) var isDragging = false
    private var currentProgress: CGFloat = 0
    private var currentThumbRatio: CGFloat = 0.1

    var onScrub: ((CGFloat) -> Void)?
    var onScrubActivity: (() -> Void)?
    var onTap: ((CGPoint) -> Void)?

    private static let idleWidth: CGFloat = 3.5
    private static let activeWidth: CGFloat = 7.5
    private static let minThumbHeight: CGFloat = 28
    private static let rightMargin: CGFloat = 3
    private static let touchTargetWidth: CGFloat = 44

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        alpha = 0

        thumbView.backgroundColor = UIColor(white: 1.0, alpha: 0.35)
        thumbView.layer.cornerRadius = Self.idleWidth / 2
        thumbView.layer.masksToBounds = true
        thumbView.isUserInteractionEnabled = false
        addSubview(thumbView)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.cancelsTouchesInView = true
        addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateThumbFrame(animated: false)
    }

    private var trackTop: CGFloat {
        safeAreaInsets.top + 16
    }

    private var trackBottom: CGFloat {
        safeAreaInsets.bottom + 16
    }

    private var trackHeight: CGFloat {
        max(1, bounds.height - trackTop - trackBottom)
    }

    private func updateThumbFrame(animated: Bool) {
        let width = isDragging ? Self.activeWidth : Self.idleWidth
        let thumbHeight = max(Self.minThumbHeight, trackHeight * currentThumbRatio)
        let travel = max(0, trackHeight - thumbHeight)
        let y = trackTop + currentProgress * travel
        let x = bounds.width - Self.rightMargin - width
        let targetFrame = CGRect(x: x, y: y, width: width, height: thumbHeight)

        let update = {
            self.thumbView.frame = targetFrame
            self.thumbView.layer.cornerRadius = width / 2
            self.thumbView.backgroundColor = UIColor(white: 1.0, alpha: self.isDragging ? 0.75 : 0.35)
        }

        if animated {
            UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .curveEaseOut], animations: update)
        } else {
            update()
        }
    }

    func setProgress(_ progress: CGFloat, thumbRatio: CGFloat) {
        let clamped = min(max(progress, 0), 1)
        currentProgress = clamped
        currentThumbRatio = min(max(thumbRatio, 0.05), 1.0)
        updateThumbFrame(animated: false)

        guard !isDragging else { return }
        showAndScheduleHide()
    }

    private func showAndScheduleHide() {
        if alpha < 1 {
            UIView.animate(withDuration: 0.15) { self.alpha = 1 }
        }
        // Called every scroll frame: push the existing timer back instead of
        // building a new one 120 times a second.
        if let timer = hideTimer, timer.isValid {
            timer.fireDate = Date(timeIntervalSinceNow: 0.8)
            return
        }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isDragging else { return }
                UIView.animate(withDuration: 0.3) { self.alpha = 0 }
            }
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let y = gesture.location(in: self).y
        let relativeY = y - trackTop
        let progress = min(max(relativeY / trackHeight, 0), 1)

        switch gesture.state {
        case .began:
            isDragging = true
            hideTimer?.invalidate()
            alpha = 1
            Haptics.shared.selection()
            updateThumbFrame(animated: true)
            onScrub?(progress)
            onScrubActivity?()
        case .changed:
            currentProgress = progress
            updateThumbFrame(animated: false)
            onScrub?(progress)
            onScrubActivity?()
        case .ended, .cancelled, .failed:
            isDragging = false
            updateThumbFrame(animated: true)
            showAndScheduleHide()
        default:
            break
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let pointInView = gesture.location(in: superview ?? self)
        onTap?(pointInView)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard alpha > 0.05 else { return false }
        let touchArea = CGRect(
            x: bounds.width - Self.touchTargetWidth,
            y: trackTop,
            width: Self.touchTargetWidth,
            height: trackHeight
        )
        return touchArea.contains(point)
    }
}
