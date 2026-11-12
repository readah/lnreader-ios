// WebtoonScrollController.swift - Drives the webtoon strip's scroll view.
//
// The strip itself is a `UICollectionView` (`WebtoonStrip`, below), not a
// SwiftUI `LazyVStack`: a lazy stack guesses the height of rows it has not built
// and corrects the content size as it builds them, which makes scrolling up
// reluctant and jittery. Here every row has an explicit height.
//
// Auto scroll and hold-to-scroll talk to that `UIScrollView` directly: a
// `CADisplayLink` moves `contentOffset`, and the strip reports the current page
// from the offset.
//
// The decisions — how fast, when to stop — live in `ScrollStep` and
// `HoldScrollConfig` (MangaReaderControls.swift). This file only moves pixels.

import SwiftUI
import UIKit

@MainActor
@Observable
final class WebtoonScrollController {

    // MARK: Configuration (set by the reader)

    @ObservationIgnored var autoSpeed: Double = 60
    @ObservationIgnored var autoStyle: AutoScrollStyle = .stepped {
        didSet {
            guard autoStyle != oldValue else { return }
            rest = 0
            updateLink()
        }
    }
    @ObservationIgnored var momentum: WebtoonMomentum = .medium {
        didSet { applyMomentum() }
    }
    @ObservationIgnored var hold = HoldScrollConfig()
    @ObservationIgnored var isHoldEnabled = true {
        didSet { holdRecognizer.isEnabled = isHoldEnabled }
    }
    /// Which way a hold at this point (in the strip's container) scrolls: `true`
    /// is forward. Set by the reader from the series' tap-zone layout.
    @ObservationIgnored var holdGoesForward: ((CGPoint) -> Bool)?
    /// Called when auto scroll runs out of content.
    @ObservationIgnored var onReachedEnd: (() -> Void)?
    /// Called while the strip is moving for any reason: drag, hold, auto or a screenful.
    @ObservationIgnored var onScrollActivity: (() -> Void)?
    /// Set by the strip: scrolls the page at this index of that chapter to the top.
    @ObservationIgnored var jumpToPage: ((String, Int) -> Void)?

    // MARK: State (read by the reader's overlay)

    private(set) var isAutoScrolling = false
    /// Current hold speed in points per second, `nil` when not holding.
    private(set) var holdSpeed: Double?
    @ObservationIgnored private var holdForward = true

    /// A hold just ended. The finger lifting after a long press looks like a
    /// tap to the reader's tap gesture; this lets it ignore that one.
    var justHeld: Bool { Date().timeIntervalSince(lastHoldEnd) < 0.4 }

    // MARK: Internals

    @ObservationIgnored private weak var scrollView: UIScrollView?
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var lastTimestamp: CFTimeInterval = 0
    /// The crawl's true position. The scroll view is only ever set to whole
    /// pixels, so a slow crawl accumulates here between them.
    @ObservationIgnored private var exactOffset: Double?
    /// Seconds stepped auto scroll has rested since it last moved.
    @ObservationIgnored private var rest: Double = 0
    @ObservationIgnored private var holdStartY: CGFloat = 0
    @ObservationIgnored private var lastHoldEnd = Date.distantPast
    @ObservationIgnored private var hapticTracker: HoldHapticTracker?
    @ObservationIgnored private lazy var proxy = Proxy(owner: self)
    @ObservationIgnored private lazy var holdRecognizer: UILongPressGestureRecognizer = {
        let recognizer = UILongPressGestureRecognizer(target: proxy, action: #selector(Proxy.held(_:)))
        recognizer.minimumPressDuration = 0.3
        // Only governs the wait: a finger that travels this far before the
        // press registers is a scroll, and the recognizer steps aside.
        recognizer.allowableMovement = 10
        recognizer.delegate = proxy
        recognizer.isEnabled = isHoldEnabled
        return recognizer
    }()

    // MARK: - Attaching

    /// Bind to the scroll view the strip is rendered in. Called again when the
    /// strip is rebuilt (new chapter), so the previous one is released.
    func attach(_ view: UIScrollView) {
        guard scrollView !== view else { return }
        scrollView?.removeGestureRecognizer(holdRecognizer)
        scrollView = view
        view.addGestureRecognizer(holdRecognizer)
        applyMomentum()
        updateLink()
    }

    private func applyMomentum() {
        scrollView?.decelerationRate = UIScrollView.DecelerationRate(rawValue: CGFloat(momentum.decelerationRate))
    }

    func detach() {
        stopAuto()
        endHold()
        stepSettled()
        scrollView?.removeGestureRecognizer(holdRecognizer)
        scrollView = nil
    }

    // MARK: - Auto scroll

    func startAuto() {
        guard scrollView != nil, !isAutoScrolling else { return }
        isAutoScrolling = true
        rest = 0
        Haptics.shared.scrollEngaged()
        updateLink()
    }

    func stopAuto() {
        guard isAutoScrolling else { return }
        isAutoScrolling = false
        Haptics.shared.scrollReleased()
        updateLink()
    }

    func toggleAuto() {
        if isAutoScrolling { stopAuto() } else { startAuto() }
    }

    // MARK: - Paging by a screenful

    /// A screenful is being animated by `setContentOffset(animated:)`.
    ///
    /// UIKit reports a finger's drag and its momentum (`isDragging`,
    /// `isDecelerating`) but not a programmatic animated scroll, so the strip
    /// believes it is at rest while a tap's step is still running. It would then
    /// land a height correction (`flushRatios`) or a trim in the middle of that
    /// animation, which cuts the step short and moves the strip by however much
    /// the pages above it had been mismeasured — a tap that skips several pages.
    @ObservationIgnored private(set) var isStepping = false

    /// The step's animation ended, or was cancelled by a finger or a jump.
    func stepSettled() { isStepping = false }

    /// Scroll roughly one screen, for a tap zone or a volume key.
    func scrollScreen(forward: Bool, fraction: CGFloat = ScrollStep.screenful) {
        guard let view = scrollView else { return }
        let minY = -view.adjustedContentInset.top
        let maxY = maxOffset(view)
        let delta = view.bounds.height * fraction * (forward ? 1 : -1)
        let target = min(max(view.contentOffset.y + delta, minY), maxY)
        // A step that cannot move (already at the end) does not animate, so it
        // never reports an end; it must not leave the flag set either.
        if abs(target - view.contentOffset.y) > 0.5 { isStepping = true }
        view.setContentOffset(CGPoint(x: view.contentOffset.x, y: target), animated: true)
        onScrollActivity?()
    }

    // MARK: - Hold to scroll

    fileprivate func holdBegan(at y: CGFloat, zonePoint: CGPoint) {
        guard let view = scrollView else { return }
        holdForward = holdGoesForward?(zonePoint) ?? true
        holdStartY = y
        let start = hold.speed(forDrag: 0)
        holdSpeed = start
        hapticTracker = HoldHapticTracker(startSpeed: start, config: hold)
        Haptics.shared.prepare()
        // The hold owns the finger from here: a drag changes the speed, it
        // does not also drag the content.
        view.panGestureRecognizer.isEnabled = false
        Haptics.shared.scrollEngaged()
        updateLink()
    }

    fileprivate func holdMoved(to y: CGFloat, zonePoint: CGPoint) {
        guard holdSpeed != nil else { return }
        // Sliding into another zone turns the scroll around mid-hold.
        let forward = holdGoesForward?(zonePoint) ?? true
        if forward != holdForward {
            holdForward = forward
            Haptics.shared.scrollSpeedLimit()
        }
        let speed = hold.speed(forDrag: Double(y - holdStartY))
        holdSpeed = speed
        switch hapticTracker?.update(speed: speed, config: hold) {
        case .tick: Haptics.shared.scrollSpeedStep(level: hold.level(of: speed))
        case .limit: Haptics.shared.scrollSpeedLimit()
        case nil: break
        }
    }

    fileprivate func endHold() {
        guard holdSpeed != nil else { return }
        holdSpeed = nil
        hapticTracker = nil
        lastHoldEnd = Date()
        Haptics.shared.scrollReleased()
        scrollView?.panGestureRecognizer.isEnabled = true
        updateLink()
    }

    // MARK: - Frame loop

    /// The display link only runs while something is scrolling.
    private func updateLink() {
        let needed = scrollView != nil && (isAutoScrolling || holdSpeed != nil)
        if needed, link == nil {
            let displayLink = CADisplayLink(target: proxy, selector: #selector(Proxy.frame(_:)))
            lastTimestamp = 0
            exactOffset = nil
            displayLink.add(to: .main, forMode: .common)
            link = displayLink
        } else if !needed, let existing = link {
            existing.invalidate()
            link = nil
        }
        link?.preferredFrameRateRange = isCrawling
            // A crawl at the screen's full rate, as smooth as a finger's drag.
            // Without this the link stays at 60 Hz on a 120 Hz screen and the
            // strip visibly steps.
            ? CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            // Stepped auto scroll only counts time between screenfuls.
            : CAFrameRateRange(minimum: 10, maximum: 30, preferred: 15)
    }

    /// Something moves the strip every frame, as opposed to stepping it.
    private var isCrawling: Bool {
        holdSpeed != nil || (isAutoScrolling && autoStyle == .continuous)
    }

    fileprivate func tick(_ displayLink: CADisplayLink) {
        guard let view = scrollView else { return stopAll() }
        let dt = lastTimestamp == 0 ? 0 : displayLink.timestamp - lastTimestamp
        lastTimestamp = displayLink.timestamp
        let readerMoving = view.isTracking || view.isDragging || view.isDecelerating

        let speed: Double
        if let holdSpeed {
            speed = holdForward ? holdSpeed : -holdSpeed
        } else if isAutoScrolling, autoStyle == .stepped {
            return stepTick(view, dt: dt, readerMoving: readerMoving)
        } else if isAutoScrolling, !readerMoving {
            // The reader's own finger always wins: auto scroll waits for the
            // drag and its momentum to finish, then carries on.
            speed = autoSpeed
        } else {
            exactOffset = nil
            return
        }

        let scale = Double(view.traitCollection.displayScale)
        let shown = Double(view.contentOffset.y)
        // Carry on from the exact position unless something else moved the
        // strip since the last frame (a drag, a jump).
        let start = exactOffset.flatMap { abs($0 - shown) <= 1 / max(scale, 1) ? $0 : nil } ?? shown
        let step = ScrollStep.advance(
            offset: start,
            speed: speed,
            dt: dt,
            maxOffset: Double(maxOffset(view)),
            minOffset: Double(-view.adjustedContentInset.top)
        )
        exactOffset = step.offset
        view.contentOffset.y = CGFloat(ScrollStep.pixelAligned(step.offset, scale: scale))
        onScrollActivity?()

        if step.reachedEnd, holdSpeed == nil, isAutoScrolling {
            stopAuto()
            onReachedEnd?()
        }
    }

    /// Stepped auto scroll: rest long enough to keep the set pace, then move a
    /// screenful. Moving the strip by hand restarts the rest, so the reader
    /// always gets a full screen's reading time after letting go.
    private func stepTick(_ view: UIScrollView, dt: Double, readerMoving: Bool) {
        guard !readerMoving else { rest = 0; return }
        rest += min(dt, ScrollStep.maxFrameGap)
        let distance = Double(view.bounds.height) * ScrollStep.screenful
        guard rest >= ScrollStep.restInterval(distance: distance, speed: autoSpeed) else { return }
        rest = 0
        if view.contentOffset.y >= maxOffset(view) - 1 {
            stopAuto()
            onReachedEnd?()
        } else {
            scrollScreen(forward: true)
        }
    }

    private func maxOffset(_ view: UIScrollView) -> CGFloat {
        let inset = view.adjustedContentInset
        return max(-inset.top, view.contentSize.height - view.bounds.height + inset.bottom)
    }

    private func stopAll() {
        isAutoScrolling = false
        holdSpeed = nil
        updateLink()
    }

    // MARK: - Objective-C bridge

    /// `CADisplayLink` and gesture recognizers need an `NSObject` target, which
    /// an `@Observable` class is not. Holds the owner weakly, so the display
    /// link retaining its target is not a retain cycle.
    private final class Proxy: NSObject, UIGestureRecognizerDelegate {
        weak var owner: WebtoonScrollController?
        init(owner: WebtoonScrollController) { self.owner = owner }

        @objc func frame(_ link: CADisplayLink) {
            MainActor.assumeIsolated { owner?.tick(link) }
        }

        @objc func held(_ recognizer: UILongPressGestureRecognizer) {
            MainActor.assumeIsolated {
                // Window coordinates: the content moves under the finger while
                // it scrolls, so a point in the scroll view would drift.
                let y = recognizer.location(in: nil).y
                let zone = recognizer.view?.superview.map { recognizer.location(in: $0) }
                    ?? recognizer.location(in: nil)
                switch recognizer.state {
                case .began: owner?.holdBegan(at: y, zonePoint: zone)
                case .changed: owner?.holdMoved(to: y, zonePoint: zone)
                case .ended, .cancelled, .failed: owner?.endHold()
                default: break
                }
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }
}
