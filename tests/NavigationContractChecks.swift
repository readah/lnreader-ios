import Foundation
@main struct NavigationContractChecks {
    static func main() {
        for total in [0, 1, 49, 50, 51, 999, 1000, 1003, 10000] {
            let pages = (0..<ChapterPages.count(total: total)).flatMap { Array(ChapterPages.bounds(total: total, page: $0)) }
            precondition(pages == Array(0..<total), "Every chapter must appear once, including the final partial page")
            precondition(ChapterPages.bounds(total: total, page: -1).lowerBound == 0)
            precondition(ChapterPages.bounds(total: total, page: Int.max).upperBound == total)
        }
        let swipe = LibrarySwipeInteraction()
        precondition(swipe.allowsActivation(at: 0), "A normal tap opens a book")
        swipe.changed(horizontal: 4, vertical: 3)
        precondition(swipe.allowsActivation(at: 0), "Small finger jitter is still a tap")
        swipe.ended(at: 0)
        precondition(swipe.allowsActivation(at: 0), "A tap needs no cooldown")
        swipe.changed(horizontal: -25, vertical: 2)
        precondition(!swipe.allowsActivation(at: 10), "An unfinished drag cannot open a cover")
        precondition(LibrarySwipeInteraction.pageStep(horizontal: -25, vertical: 2) == 0)
        swipe.ended(at: 10)
        precondition(!swipe.allowsActivation(at: 10), "An aborted swipe cannot become a release-time tap")
        precondition(!swipe.allowsActivation(at: 10.1), "Delayed release callbacks are suppressed")
        precondition(swipe.allowsActivation(at: 10.3), "A fresh tap works after a swipe")
        swipe.changed(horizontal: 90, vertical: 1)
        swipe.ended(at: 20)
        precondition(!swipe.allowsActivation(at: 20), "An edge swipe cannot open a cover either")
        precondition(LibrarySwipeInteraction.pageStep(horizontal: -100, vertical: 10) == 1)
        precondition(LibrarySwipeInteraction.pageStep(horizontal: 100, vertical: 10) == -1)
        precondition(LibrarySwipeInteraction.pageStep(horizontal: 20, vertical: 100) == 0)
        precondition(LibrarySwipeInteraction.pageStep(horizontal: 100, vertical: 80) == 0)
        swipe.changed(horizontal: 0, vertical: 20)
        precondition(!swipe.allowsActivation(at: 30), "Vertical scrolling is not a cover tap")
        swipe.ended(at: 30)
        precondition(swipe.allowsActivation(at: 31), "Cancelled drags recover on gesture reset")
        precondition(LibrarySwipeInteraction.isTitleSwipe(horizontal: 2, vertical: -50))
        precondition(LibrarySwipeInteraction.isTitleSwipe(horizontal: 2, vertical: 50))
        precondition(!LibrarySwipeInteraction.isTitleSwipe(horizontal: 50, vertical: 2))
        precondition(!LibrarySwipeInteraction.isTitleSwipe(horizontal: 2, vertical: 15))
        precondition(!LibrarySwipeInteraction.isTitleSwipe(horizontal: 40, vertical: 50))
        print("PASS: stable book moves, complete chapter pages, title mode gestures and cover-tap suppression")
    }
}
