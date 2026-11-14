import SwiftUI
import SwiftData

struct ReaderChapterListSheet: View {
    let entry: Entry?
    let currentChapterPath: String
    let onSelectChapter: (Chapter) -> Void
    let onDismiss: () -> Void
    @State private var chapters: [ChapterDisplay] = []
    @State private var chapterByPath: [String: Chapter] = [:]
    /// The same setting the detail screen's menu writes.
    @AppStorage(ChapterOrder.ascendingKey) private var ascending = false

    var body: some View {
        ChapterDirectoryView(entry: entry, chapters: chapters, sourceKey: entry?.sourceKey ?? "",
            currentChapterPath: currentChapterPath,
            onSelect: { chapter in if let stored = chapterByPath[chapter.path] { onSelectChapter(stored) } },
            onClose: onDismiss)
            .onAppear(perform: load)
            // The rows are value snapshots, so a read-state change made in this
            // sheet has to rebuild them before the unread dot can go away.
            .onReceive(NotificationCenter.default.publisher(for: .lnreaderChapterReadChanged)) { _ in load() }
    }

    private func load() {
        // `visibleChapters` is a relationship, so its order is whatever the store
        // hands back. This sheet used to sort it oldest-first and ignore the
        // setting, which is why it disagreed with the list behind it.
        let sorted = ChapterOrder.display(entry?.visibleChapters ?? [], ascending: ascending)
        // The entry is already here, so its identity is passed in rather than
        // read back through `chapter.entry` once per chapter.
        let sourceKey = entry?.sourceKey ?? ""
        let entryURL = entry?.url
        let kind = entry?.kind ?? .novel
        chapters = sorted.map {
            ChapterDisplay(chapter: $0, sourceKey: sourceKey, entryURL: entryURL, kind: kind)
        }
        chapterByPath = Dictionary(sorted.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
