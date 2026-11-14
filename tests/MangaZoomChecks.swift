// MangaZoomChecks.swift - The manga reader's zoom transform, headless.
//
// The invariant: after a pinched zoom, the content point that was under the
// pinch is still under it — unless the view had to stop at a content edge.

import CoreGraphics

@main
struct MangaZoomChecks {

    static let viewport = CGSize(width: 400, height: 800)

    static func main() {
        checkPinchKeepsTheCentre()
        checkPinchInACornerKeepsThatCorner()
        checkRepeatedPinchUsesTheCommittedTransform()
        checkScaleLimitsDoNotDrift()
        checkZoomOutReturnsToFit()
        checkEdgeClampingMovesTheAnchor()
        checkPan()
        checkClampAfterResize()
        checkReset()
        print("PASS: manga zoom — anchored pinch, corner anchors, repeated pinches, scale "
            + "limits, edge clamping, pan, resize, reset")
    }

    private static func zoomed(_ state: MangaZoomState, by factor: CGFloat,
                               around anchor: CGPoint = CGPoint(x: 200, y: 400),
                               in size: CGSize = viewport) -> MangaZoomState {
        var next = state
        next.zoom(by: factor, around: anchor, in: size)
        return next
    }

    private static func checkPinchKeepsTheCentre() {
        let state = zoomed(MangaZoomState(), by: 2)
        precondition(state.scale == 2, "2x")
        precondition(state.translation == CGSize(width: -200, height: -400),
                     "the middle pinch moves the content half a viewport each way")
        precondition(state.contentPoint(at: CGPoint(x: 200, y: 400)) == CGPoint(x: 200, y: 400),
                     "the centre stays put")
    }

    private static func checkPinchInACornerKeepsThatCorner() {
        // Top-left: the corner is the content origin, so the translation stays
        // zero and the corner grows in place.
        let topLeft = zoomed(MangaZoomState(), by: 3, around: .zero)
        precondition(topLeft.translation == .zero, "top-left pinch does not move the content")
        precondition(topLeft.contentPoint(at: .zero) == .zero, "top-left stays put")

        // Bottom-right: the far corner grows outward while staying on the corner.
        let bottomRight = zoomed(MangaZoomState(), by: 3, around: CGPoint(x: 400, y: 800))
        precondition(bottomRight.contentPoint(at: CGPoint(x: 400, y: 800)) == CGPoint(x: 400, y: 800),
                     "the pinch point is preserved")
        precondition(bottomRight.translation == CGSize(width: -800, height: -1600),
                     "a corner pinch is not centred")
    }

    private static func checkRepeatedPinchUsesTheCommittedTransform() {
        let first = zoomed(MangaZoomState(), by: 2)
        let point = first.contentPoint(at: CGPoint(x: 100, y: 100))
        let second = zoomed(first, by: 1.5, around: CGPoint(x: 100, y: 100))
        precondition(second.scale == 3, "the scales multiply")
        precondition(second.contentPoint(at: CGPoint(x: 100, y: 100)) == point,
                     "a second pinch keeps the point under the new pinch")
        precondition(second.contentPoint(at: CGPoint(x: 100, y: 100)) == CGPoint(x: 150, y: 250),
                     "the committed transform is the start, not the last update")
    }

    private static func checkScaleLimitsDoNotDrift() {
        var maxed = MangaZoomState(scale: MangaZoomState.maxScale,
                                   translation: CGSize(width: -1200, height: -2400))
        let atMax = zoomed(maxed, by: 2)
        precondition(atMax == maxed, "pinching past the maximum leaves the view alone")

        var fitted = MangaZoomState()
        let atMin = zoomed(fitted, by: 0.5)
        precondition(atMin == fitted, "pinching past the minimum leaves the view alone")
        precondition(!atMin.canZoomOut, "nothing left to zoom out of")

        // A button press at a limit does not move either.
        maxed.zoom(by: MangaZoomState.step, in: viewport)
        precondition(maxed == atMax, "the zoom-in button stops at the maximum")
        precondition(!maxed.canZoomIn, "nothing left to zoom into")
        fitted.zoom(by: 1 / MangaZoomState.step, in: viewport)
        precondition(fitted == atMin, "the zoom-out button stops at the minimum")
    }

    private static func checkZoomOutReturnsToFit() {
        let zoomedState = zoomed(MangaZoomState(), by: 2)
        let back = zoomed(zoomedState, by: 0.5)
        precondition(back == MangaZoomState(), "zooming back out to 1x fits the content again")
    }

    private static func checkEdgeClampingMovesTheAnchor() {
        // Pinned to the bottom-right at 4x, then zoomed out near the top-left:
        // the anchor cannot stay put and the content stops at its edge.
        let pinned = MangaZoomState(scale: 4, translation: CGSize(width: -1200, height: -2400))
        let next = zoomed(pinned, by: 0.5, around: .zero)
        precondition(next.scale == 2, "the scale still changes")
        precondition(next.translation == CGSize(width: -400, height: -800),
                     "the translation is bounded to the content's edge, so the anchor drifts")
    }

    private static func checkPan() {
        let zoomedState = zoomed(MangaZoomState(), by: 2)
        var panned = zoomedState
        panned.pan(by: CGSize(width: 50, height: 30), in: viewport, horizontalOnly: false)
        precondition(panned.translation == CGSize(width: -150, height: -370), "pan adds the drag")

        panned.pan(by: CGSize(width: -10_000, height: -10_000), in: viewport, horizontalOnly: false)
        precondition(panned.translation == CGSize(width: -400, height: -800),
                     "pan stops at the content's edge")

        var sideways = zoomedState
        sideways.pan(by: CGSize(width: 50, height: 30), in: viewport, horizontalOnly: true)
        precondition(sideways.translation == CGSize(width: -150, height: -400),
                     "a webtoon pan leaves the vertical position to its own scrolling")

        var fitted = MangaZoomState()
        fitted.pan(by: CGSize(width: 50, height: 30), in: viewport, horizontalOnly: false)
        precondition(fitted == MangaZoomState(), "there is nothing to pan at 1x")
    }

    private static func checkClampAfterResize() {
        var resized = MangaZoomState(scale: 2, translation: CGSize(width: -400, height: -800))
        resized.clamp(in: CGSize(width: 300, height: 600))
        precondition(resized.translation == CGSize(width: -300, height: -600),
                     "a smaller viewport pulls the translation inside it")
    }

    private static func checkReset() {
        var zoomedState = zoomed(MangaZoomState(), by: 4)
        zoomedState.reset()
        precondition(zoomedState == MangaZoomState(), "reset fits the content again")
        precondition(!zoomedState.isZoomed, "1x is not zoomed")
    }
}
