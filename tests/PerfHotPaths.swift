// PerfHotPaths.swift - Headless benchmark for the paths the UI hits per frame.
//
// Instruments needs a device and a human scrolling. This measures the parts of
// the render path that are pure data work, at library scale, so a regression is
// a number in CI rather than a feeling on a phone.
//
// Each pair below is "the shape the code had" vs "the shape it has now". Both
// sides run against the real schema and the real `ScanlatorRules`; only the
// view-layer types are mirrored, because those need SwiftUI.
//
// Run with `./scripts/profile-hotpaths.sh`.

import Foundation
import SwiftData

@main
struct PerfHotPaths {

    /// 120 books of 250 chapters is a large but ordinary library — big enough
    /// that per-row costs dominate, small enough to build in a few seconds.
    static let entryCount = 120
    static let chaptersPerEntry = 250

    static func main() throws {
        let container = try makeContainer()
        try populate(container)

        print("")
        print("LNReader hot paths — \(entryCount) entries × \(chaptersPerEntry) chapters"
            + " (\(entryCount * chaptersPerEntry) chapters)")
        print(String(repeating: "─", count: 74))

        try libraryCounts(container)
        try singleCellCounts(container)
        try scrollTickPersistence(container)
        try chapterRows()
        try chapterOrdering()

        print(String(repeating: "─", count: 74))
        print("")
    }

    // MARK: - Store

    static func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV4.self)
        let url = FileManager.default.temporaryDirectory
            .appending(path: "lnreader-perf-\(UUID().uuidString).store")
        // On disk, not in memory: relationship faults and COUNT queries are
        // what we are measuring, and an in-memory store has neither.
        let configuration = ModelConfiguration("PerfHotPaths", schema: schema, url: url)
        return try ModelContainer(
            for: schema,
            migrationPlan: LNReaderSchemaMigrationPlan.self,
            configurations: configuration
        )
    }

    static func populate(_ container: ModelContainer) throws {
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for e in 0..<entryCount {
            let entry = Entry(
                kind: e.isMultiple(of: 2) ? .novel : .manga,
                sourceKey: "ln:source\(e % 7)",
                url: "/book/\(e)",
                title: "Book \(e) — A Somewhat Long Light Novel Title"
            )
            entry.inLibrary = true
            entry.author = "Author \(e % 40)"
            entry.lastReadAt = base.addingTimeInterval(Double(e) * 3600)
            context.insert(entry)

            for c in 0..<chaptersPerEntry {
                let chapter = Chapter(
                    url: "/book/\(e)/chapter/\(c)",
                    name: "Chapter \(c + 1): The Long Road Home",
                    chapterNumber: Double(c + 1),
                    sourceOrder: c
                )
                chapter.read = c < chaptersPerEntry / 2
                chapter.progress = c < chaptersPerEntry / 2 ? 100 : 0
                chapter.dateUpload = base.addingTimeInterval(Double(c) * 86400)
                chapter.entry = entry
                context.insert(chapter)
            }

            if e.isMultiple(of: 10) {
                try context.save()
            }
        }
        try context.save()
    }

    // MARK: - Library: unread/total counts

    /// The library grid asked for `Entry.unreadCount` and `totalChapterCount`
    /// three times per visible cell, and sorting by unread asked for them for
    /// every entry. Both resolve the `chapters` relationship.
    static func libraryCounts(_ container: ModelContainer) throws {
        let walk = try measure("relationship walk (before)", iterations: 3) {
            let context = ModelContext(container)
            let entries = try context.fetch(
                FetchDescriptor<Entry>(predicate: #Predicate { $0.inLibrary })
            )
            var sink = 0
            for entry in entries {
                sink &+= entry.unreadCount
                sink &+= entry.totalChapterCount
            }
            blackhole(sink)
        }

        let counted = try measure("fetchCount (after)", iterations: 3) {
            let context = ModelContext(container)
            let entries = try context.fetch(
                FetchDescriptor<Entry>(predicate: #Predicate { $0.inLibrary })
            )
            var sink = 0
            for entry in entries {
                let url = entry.url
                let sourceKey = entry.sourceKey
                sink &+= try context.fetchCount(FetchDescriptor<Chapter>(predicate: #Predicate {
                    $0.entry?.url == url && $0.entry?.sourceKey == sourceKey
                }))
                sink &+= try context.fetchCount(FetchDescriptor<Chapter>(predicate: #Predicate {
                    $0.entry?.url == url && $0.entry?.sourceKey == sourceKey && $0.read == false
                }))
            }
            blackhole(sink)
        }

        report("library unread + total counts", before: walk, after: counted)
    }

    // MARK: - One grid cell

    /// What a single badge costs on screen. This is the number that decides
    /// whether the library scrolls: a cell asked for the count three times, so
    /// the walk was paid three times per cell, per body pass.
    static func singleCellCounts(_ container: ModelContainer) throws {
        let walk = try measure("one cell, relationship walk (before)", iterations: 10) {
            let context = ModelContext(container)
            var descriptor = FetchDescriptor<Entry>(predicate: #Predicate { $0.inLibrary })
            descriptor.fetchLimit = 1
            guard let entry = try context.fetch(descriptor).first else { return }
            var sink = 0
            for _ in 0..<3 {
                sink &+= entry.unreadCount
                sink &+= entry.totalChapterCount
            }
            blackhole(sink)
        }

        let counted = try measure("one cell, fetchCount (after)", iterations: 10) {
            let context = ModelContext(container)
            var descriptor = FetchDescriptor<Entry>(predicate: #Predicate { $0.inLibrary })
            descriptor.fetchLimit = 1
            guard let entry = try context.fetch(descriptor).first else { return }
            let url = entry.url
            let sourceKey = entry.sourceKey
            let total = try context.fetchCount(FetchDescriptor<Chapter>(predicate: #Predicate {
                $0.entry?.url == url && $0.entry?.sourceKey == sourceKey
            }))
            let unread = try context.fetchCount(FetchDescriptor<Chapter>(predicate: #Predicate {
                $0.entry?.url == url && $0.entry?.sourceKey == sourceKey && $0.read == false
            }))
            blackhole(total + unread)
        }

        report("library cell badge (3 reads)", before: walk, after: counted)
    }

    // MARK: - Reading progress

    /// The reader reports position on a 300 ms debounce, and every report used
    /// to `save()`. A save is a WAL write plus a store-change notification,
    /// which re-runs every `@Query` in the app — the library's included.
    static func scrollTickPersistence(_ container: ModelContainer) throws {
        let saving = try measure("save on every tick (before)", iterations: 10) {
            let context = ModelContext(container)
            var descriptor = FetchDescriptor<Chapter>()
            descriptor.fetchLimit = 1
            guard let chapter = try context.fetch(descriptor).first else { return }
            chapter.progress = (chapter.progress + 1).truncatingRemainder(dividingBy: 100)
            chapter.paragraphIndex = Int(chapter.progress)
            try context.save()
        }

        let coalesced = try measure("mutate, save on a timer (after)", iterations: 10) {
            let context = ModelContext(container)
            var descriptor = FetchDescriptor<Chapter>()
            descriptor.fetchLimit = 1
            guard let chapter = try context.fetch(descriptor).first else { return }
            chapter.progress = (chapter.progress + 1).truncatingRemainder(dividingBy: 100)
            chapter.paragraphIndex = Int(chapter.progress)
            blackhole(chapter.paragraphIndex ?? 0)
        }

        report("reading progress tick", before: saving, after: coalesced)
    }

    // MARK: - Chapter list: building rows

    /// `ChapterDisplay` used to format a release date inside its initializer,
    /// so opening a 2 000-chapter book formatted 2 000 dates to show ten rows.
    static func chapterRows() throws {
        let dates: [Date?] = (0..<chaptersPerEntry * 8).map {
            Date(timeIntervalSince1970: 1_700_000_000 + Double($0) * 3600)
        }

        let eager = measure("eager date formatting (before)", iterations: 5) {
            var rows: [EagerRow] = []
            rows.reserveCapacity(dates.count)
            for (index, date) in dates.enumerated() {
                rows.append(EagerRow(name: "Chapter \(index + 1)", releaseTime: date.map { $0.formatted() }))
            }
            blackhole(rows.count)
        }

        let lazy = measure("lazy date formatting (after)", iterations: 5) {
            var rows: [LazyRow] = []
            rows.reserveCapacity(dates.count)
            for (index, date) in dates.enumerated() {
                rows.append(LazyRow(name: "Chapter \(index + 1)", releaseDate: date))
            }
            // Only the visible rows ask for a string.
            var sink = 0
            for row in rows.prefix(10) { sink &+= row.releaseTime?.count ?? 0 }
            blackhole(sink + rows.count)
        }

        report("chapter rows (\(dates.count))", before: eager, after: lazy)
    }

    // MARK: - Chapter list: ordering

    /// `orderedChapters` was a computed property read two to three times per
    /// body evaluation: a scanlator pass plus a full sort each time.
    static func chapterOrdering() throws {
        let rows: [ChapterDisplayStub] = (0..<chaptersPerEntry * 8).map { index in
            ChapterDisplayStub(
                name: "Chapter \(index + 1): The Long Road Home",
                chapterNumber: Double(index + 1),
                scanlator: index.isMultiple(of: 5) ? "Group \(index % 4)" : nil
            )
        }
        let preference = ScanlatorPreference(
            priorityEnabled: true,
            priority: ["Group 1", "Group 2"],
            disabled: ["Group 3"]
        )

        let computed = measure("order on every body pass (before)", iterations: 3) {
            var sink = 0
            for _ in 0..<3 {
                let kept = ScanlatorRules.apply(preference, to: rows)
                let sorted = kept.sorted { lhs, rhs in
                    if lhs.sortNumber != rhs.sortNumber { return lhs.sortNumber > rhs.sortNumber }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedDescending
                }
                sink &+= sorted.count
            }
            blackhole(sink)
        }

        let memoized = measure("order once, then read (after)", iterations: 3) {
            let kept = ScanlatorRules.apply(preference, to: rows)
            let sorted = kept.sorted { lhs, rhs in
                if lhs.sortNumber != rhs.sortNumber { return lhs.sortNumber > rhs.sortNumber }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedDescending
            }
            blackhole(sorted.count)
        }

        report("chapter ordering (\(rows.count) rows, 3 body passes)", before: computed, after: memoized)
    }

    // MARK: - Harness

    struct Sample {
        let label: String
        let ms: Double
    }

    static func measure(_ label: String, iterations: Int, _ body: () throws -> Void) rethrows -> Sample {
        var samples: [Double] = []
        // One warm-up pass so we time steady state, not first-touch faults.
        try body()
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        return Sample(label: label, ms: samples.sorted()[samples.count / 2])
    }

    static func report(_ title: String, before: Sample, after: Sample) {
        let speedup = after.ms > 0 ? before.ms / after.ms : .infinity
        print("")
        print("  \(title)")
        print(String(format: "    %-38s %9.1f ms", (before.label as NSString).utf8String!, before.ms))
        print(String(format: "    %-38s %9.1f ms   %.1f× faster", (after.label as NSString).utf8String!, after.ms, speedup))
    }

    @inline(never)
    static func blackhole(_ value: Int) {
        if value == Int.min { print("\(value)") }
    }
}

// MARK: - Mirrored view types

/// Mirrors the old `ChapterDisplay` initializer: formats eagerly.
struct EagerRow {
    let name: String
    let releaseTime: String?
}

/// Mirrors the new one: keeps the date, formats on demand.
struct LazyRow {
    let name: String
    let releaseDate: Date?
    private static let style = Date.FormatStyle()

    var releaseTime: String? {
        releaseDate.map { $0.formatted(Self.style) }
    }
}

/// The subset of `ChapterDisplay` that ordering depends on.
struct ChapterDisplayStub {
    let name: String
    let chapterNumber: Double?
    let scanlator: String?

    var sortNumber: Double { chapterNumber ?? 0 }
}

extension ScanlatorRules {
    static func apply(_ preference: ScanlatorPreference, to rows: [ChapterDisplayStub]) -> [ChapterDisplayStub] {
        guard preference.enabled else { return rows }
        let items = rows.map { Item(number: $0.chapterNumber, scanlator: $0.scanlator) }
        return keptIndices(for: items, preference: preference).map { rows[$0] }
    }
}
