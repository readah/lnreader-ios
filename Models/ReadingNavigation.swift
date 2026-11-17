import Foundation

/// A drag is not a cover tap, even if it is too short to change pages or hits
/// the first/last page. Keep release-time button callbacks suppressed briefly.
final class LibrarySwipeInteraction {
    private var hasDragged = false
    private var suppressUntil = -Double.infinity

    func changed(horizontal: Double, vertical: Double) {
        if hypot(horizontal, vertical) >= 12 { hasDragged = true }
    }

    func ended(at time: TimeInterval) {
        guard hasDragged else { return }
        hasDragged = false
        suppressUntil = time + 0.25
    }

    func allowsActivation(at time: TimeInterval) -> Bool {
        !hasDragged && time >= suppressUntil
    }

    static func isTitleSwipe(horizontal: Double, vertical: Double) -> Bool {
        abs(vertical) > 32 && abs(vertical) > abs(horizontal) * 1.5
    }

    static func pageStep(horizontal: Double, vertical: Double) -> Int {
        guard abs(horizontal) > 80, abs(horizontal) > abs(vertical) * 2 else { return 0 }
        return horizontal < 0 ? 1 : -1
    }
}

/// Only a finger release can refresh. Bounce, inset changes and programmatic
/// scrolling may change the indicator distance but never start work.
struct PullToRefreshState {
    static let threshold = 80.0
    private(set) var distance = 0.0
    private(set) var didRelease = false
    private var interacting = false
    private var allowed = false

    var progress: Double { min(1, distance / Self.threshold) }
    var isPulling: Bool { interacting && allowed }

    mutating func begin(enabled: Bool) {
        interacting = true
        allowed = enabled
        didRelease = false
    }

    mutating func changed(distance: Double) {
        self.distance = max(0, distance)
    }

    mutating func end(distance: Double, enabled: Bool) -> Bool {
        guard interacting else { return false }
        interacting = false
        changed(distance: distance)
        didRelease = allowed && enabled && self.distance >= Self.threshold
        allowed = false
        return didRelease
    }

    mutating func cancel() {
        interacting = false
        allowed = false
        didRelease = false
        distance = 0
    }
}

enum SheetDragDecision: Equatable {
    case dismiss, expand, restore

    static func resolve(translation: Double, predicted: Double, canDismiss: Bool) -> Self {
        if canDismiss && (translation > 90 || (translation > 24 && predicted > 180)) { return .dismiss }
        if translation < -40 || (translation < -16 && predicted < -120) { return .expand }
        return .restore
    }
}

enum ChapterPages {
    static func count(total: Int, size: Int = 50) -> Int { max(1, (max(0, total) + max(1, size) - 1) / max(1, size)) }
    static func bounds(total: Int, page: Int, size: Int = 50) -> Range<Int> {
        let length = max(0, total), width = max(1, size)
        let safePage = min(max(0, page), count(total: length, size: width) - 1)
        let start = min(safePage * width, length)
        return start..<min(start + width, length)
    }
}
