import Foundation

enum LibraryReordering {
    static func move<ID: Hashable>(_ item: ID, to target: ID, in order: [ID]) -> [ID] {
        guard let from = order.firstIndex(of: item), let to = order.firstIndex(of: target), from != to else { return order }
        var result = order
        result.remove(at: from)
        result.insert(item, at: to)
        return result
    }
}

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

enum ChapterPages {
    static func count(total: Int, size: Int = 50) -> Int { max(1, (max(0, total) + max(1, size) - 1) / max(1, size)) }
    static func bounds(total: Int, page: Int, size: Int = 50) -> Range<Int> {
        let length = max(0, total), width = max(1, size)
        let safePage = min(max(0, page), count(total: length, size: width) - 1)
        let start = min(safePage * width, length)
        return start..<min(start + width, length)
    }
}
