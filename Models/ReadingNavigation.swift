import Foundation

enum ChapterPages {
    static func count(total: Int, size: Int = 50) -> Int { max(1, (max(0, total) + max(1, size) - 1) / max(1, size)) }
    static func bounds(total: Int, page: Int, size: Int = 50) -> Range<Int> {
        let length = max(0, total), width = max(1, size)
        let safePage = min(max(0, page), count(total: length, size: width) - 1)
        let start = min(safePage * width, length)
        return start..<min(start + width, length)
    }
}
