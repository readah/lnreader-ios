import Foundation
@main struct NavigationContractChecks {
    static func main() {
        for total in [0, 1, 49, 50, 51, 999, 1000, 1003, 10000] {
            let pages = (0..<ChapterPages.count(total: total)).flatMap { Array(ChapterPages.bounds(total: total, page: $0)) }
            precondition(pages == Array(0..<total), "Every chapter must appear once, including the final partial page")
            precondition(ChapterPages.bounds(total: total, page: -1).lowerBound == 0)
            precondition(ChapterPages.bounds(total: total, page: Int.max).upperBound == total)
        }
        print("PASS: chapter pages cover every chapter through 10,000 without gaps or duplicates")
    }
}
