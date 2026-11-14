// MangaZoom.swift - Pinch and button zoom for the manga reader.
//
// One zoom for both layouts: the whole reader content is scaled, so the pager
// and the webtoon strip need no zoom code of their own.
//
// The gesture is attached to the fixed viewport, outside the scaled content, so
// its locations are viewport points. The content is placed with
//
//     screen = content × scale + translation
//
// A pinch changes the scale and the translation together, so the content
// beneath the fingers — a corner, if that is where the pinch is — stays put.

import SwiftUI

/// Scale and position of the reader content. Pure value logic, kept apart from the gestures.
struct MangaZoomState: Equatable {
    static let minScale: CGFloat = 1
    static let maxScale: CGFloat = 4
    /// One press of a zoom button.
    static let step: CGFloat = 1.5

    var scale: CGFloat = 1
    /// Where the scaled content's top-left corner sits, in viewport points.
    var translation: CGSize = .zero

    var isZoomed: Bool { scale > Self.minScale + 0.001 }
    var canZoomIn: Bool { scale < Self.maxScale - 0.001 }
    var canZoomOut: Bool { isZoomed }

    /// The content point shown at `point` before the transform is applied.
    func contentPoint(at point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - translation.width) / scale,
                y: (point.y - translation.height) / scale)
    }

    /// Zooms by `factor`, keeping the content under `anchor` in place.
    ///
    /// The scale is clamped before the translation is computed, so a pinch past
    /// a limit leaves the view where it is instead of drifting. The translation
    /// is then bounded to the content's edges, which can move the anchor near an
    /// edge: there is no empty space to show beyond the content.
    mutating func zoom(by factor: CGFloat, around anchor: CGPoint, in size: CGSize) {
        guard factor.isFinite, factor > 0,
              anchor.x.isFinite, anchor.y.isFinite,
              size.width > 0, size.height > 0 else { return }
        let target = min(max(scale * factor, Self.minScale), Self.maxScale)
        guard abs(target - scale) > 0.0001 else { return }
        let point = contentPoint(at: anchor)
        scale = target
        translation = CGSize(width: anchor.x - point.x * target,
                             height: anchor.y - point.y * target)
        clamp(in: size)
    }

    /// Zooms about the middle of the viewport, which is all a button can mean.
    mutating func zoom(by factor: CGFloat, in size: CGSize) {
        zoom(by: factor, around: CGPoint(x: size.width / 2, y: size.height / 2), in: size)
    }

    mutating func pan(by delta: CGSize, in size: CGSize, horizontalOnly: Bool) {
        guard isZoomed else { return }
        translation = CGSize(
            width: translation.width + delta.width,
            height: horizontalOnly ? translation.height : translation.height + delta.height
        )
        clamp(in: size)
    }

    mutating func reset() {
        scale = Self.minScale
        translation = .zero
    }

    /// Pulls the translation back so the scaled content still covers the viewport.
    mutating func clamp(in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        translation = Self.bounded(translation, scale: scale, in: size)
    }

    static func bounded(_ translation: CGSize, scale: CGFloat, in size: CGSize) -> CGSize {
        CGSize(width: bounded(translation.width, length: size.width, scale: scale),
               height: bounded(translation.height, length: size.height, scale: scale))
    }

    /// The offset may not move the content off its own edge: from
    /// `-length × (scale - 1)` (the bottom-right showing) to 0 (the top-left showing).
    private static func bounded(_ value: CGFloat, length: CGFloat, scale: CGFloat) -> CGFloat {
        let overhang = max(0, length * (scale - 1))
        return min(0, max(-overhang, value))
    }
}

private struct MangaZoomModifier: ViewModifier {
    @Binding var zoom: MangaZoomState
    /// The viewport the content is laid out in. The transform is computed against it.
    let size: CGSize
    /// The webtoon scrolls vertically on its own, so a drag pans it sideways only.
    let horizontalPan: Bool

    /// The zoom when the gesture began. `magnification` and the drag translation
    /// are cumulative for a gesture, so every update is applied to this, not to
    /// the value the last update produced.
    @State private var pinchBase: MangaZoomState?
    @State private var panBase: CGSize?

    func body(content: Content) -> some View {
        // A container of the fixed viewport size, with the transformed content
        // inside it: a gesture on this container reports viewport points, even
        // when the content below it is scaled and offset.
        ZStack(alignment: .topLeading) {
            content
                .scaleEffect(zoom.scale, anchor: .topLeading)
                .offset(x: zoom.translation.width, y: zoom.translation.height)
        }
        .contentShape(Rectangle())
        .onChange(of: size) { _, newSize in zoom.clamp(in: newSize) }
        // A zoomed page is panned, not swiped; at 1x the pager and the strip
        // keep the drags for themselves. The pinch is attached outside this
        // mask, so the pan never has a say in whether it is recognised.
        .simultaneousGesture(pan, including: zoom.isZoomed ? .all : .subviews)
        .simultaneousGesture(magnify)
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchBase ?? zoom
                if pinchBase == nil { pinchBase = base }
                var next = base
                next.zoom(by: value.magnification, around: value.startLocation, in: size)
                if next != zoom { zoom = next }
            }
            .onEnded { _ in pinchBase = nil }
    }

    private var pan: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard zoom.isZoomed else { return }
                let base = panBase ?? zoom.translation
                if panBase == nil { panBase = base }
                var next = zoom
                next.translation = CGSize(
                    width: base.width + value.translation.width,
                    height: horizontalPan ? base.height : base.height + value.translation.height
                )
                next.clamp(in: size)
                if next != zoom { zoom = next }
            }
            .onEnded { _ in panBase = nil }
    }
}

extension View {
    /// Pinch to zoom and pan while zoomed. `zoom` is also driven by the reader's zoom buttons.
    func mangaZoom(_ zoom: Binding<MangaZoomState>, in size: CGSize, horizontalPan: Bool) -> some View {
        modifier(MangaZoomModifier(zoom: zoom, size: size, horizontalPan: horizontalPan))
    }
}
