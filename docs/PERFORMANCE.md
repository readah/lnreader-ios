# Performance

**Updated** 2026-10-31 · **Branch** `main`

The app was slow in a specific, measurable way: the library and the reader both
did per-row work that resolved SwiftData relationships, and the reader wrote to
the store on every scroll tick. This documents what was wrong, what changed, and
how to measure the next regression.

## Measure first

```sh
./scripts/profile-hotpaths.sh          # headless, no device, ~45 s
./scripts/profile-device.sh 30         # builds Release, installs, records hitches + Time Profiler
```

Debug builds also run `MainThreadWatchdog` (`Services/MainThreadWatchdog.swift`): when the
main thread goes 40 ms without answering, it samples main's stack and logs it under subsystem
`com.lnreader`, category `hang` (Xcode console, or Console.app). Read that first when something
feels choppy; it names the stall without a trace. Release and profiling builds leave it out.

`profile-hotpaths.sh` builds a 120-book × 250-chapter store on disk and times the
data work behind the UI. `profile-device.sh` records a Time Profiler trace of a
real device (Animation Hitches plus Time Profiler) so the parts the benchmark cannot see — body evaluation, layout,
WebKit, image decode — are covered too.

## Numbers

From `profile-hotpaths.sh`, 120 entries × 250 chapters (30 000 chapters):

| Path | Before | After | |
|---|---|---|---|
| Library unread + total counts, whole library | 4 776 ms | 1 155 ms | 4.1× |
| One grid cell's badge (3 reads) | 37.3 ms | 10.4 ms | 3.6× |
| Reading progress tick (save vs mutate) | 1.5 ms | 0.1 ms | 10.8× |
| Chapter rows, date formatting (2 000) | 3.2 ms | 0.1 ms | 22.4× |
| Chapter ordering (2 000 rows, 3 body passes) | 0.9 ms | 0.3 ms | 3.8× |

The absolute numbers matter more than the ratios. A 12-cell grid paid
`37.3 × 12 ≈ 450 ms` of relationship faulting **per body pass**, and the reader's
save-per-tick re-ran every `@Query` in the app, which triggered that body pass
again — four times a second, while scrolling.

## What was wrong

### 1. `Entry.unreadCount` walked the whole chapter list, per cell

`Entry.unreadCount` / `totalChapterCount` are `chapters.count { !$0.read }`.
Accessing them faults every `Chapter` row for that entry. `NovelGridCell` read
`unreadCount` twice and `totalChapterCount` once; `LibraryListRow` did the same;
sorting by unread did it for every entry.

Fixed with `LibraryChapterCounts` (`Services/LibraryManager.swift`): a SQL
`COUNT` per entry off the main actor, cached by `PersistentIdentifier`. Cells
read the cached value synchronously and fill it in a `.task`.

The first shape gave every entry its own `ModelContext` and its own detached
task, and dropped the whole cache on any change: 300 books meant 300 contexts
and ~1,200 queries, thrown away again by a single chapter read, and again once
per merged entry during a library update. It now coalesces every request made in
one frame into a single pass (at most four contexts, one per worker), counts only
the extras a caller asked for (`downloads`, `newCount`, `dates`; total and unread
are always counted), and invalidates **per entry** — a chapter read, a download
finishing or a sync dropping chapters marks just that entry, and `revision`
tells the cells holding a count to ask again.

Nothing is denormalised onto the model, so the count cannot drift from the
chapters — it is only ever a cached read of them. That was the reason for not
adding a stored column: a schema migration to cache a number the store can
already answer is a bad trade.

### 2. The reader saved on every scroll tick

`recordReadingPosition` called `context.save()`. The JS scroll listener debounces
at 300 ms, so a scroll wrote to the store ~4×/second. Each save is a WAL write
plus a store-change notification, and the notification re-runs every `@Query` in
the app — including the library's entry query sitting behind the full-screen
reader.

Fixed by coalescing: the model is mutated immediately (the UI stays live) and
written on a 3 s timer, with `flushProgress` called when the reader closes and
when the app backgrounds. `Entry.lastReadAt` and `History.lastRead` are only
refreshed once a minute, because nothing reads them below that granularity and
rewriting them invalidated the library query for no benefit.

### 3. Every chapter load fetched a font from a third-party CDN

`readerHTML` put `<link href="https://fonts.cdnfonts.com/css/open-dyslexic">` in
`<head>` unconditionally. A stylesheet link in the head is render-blocking: the
first line of text waited on a network round trip to a CDN that has nothing to do
with the chapter. Now the link is only emitted when OpenDyslexic is the selected
family, and switching to it from the settings sheet injects the link from script
(which does not block).

### 4. Covers were decoded at full resolution, on the draw path

`CustomAsyncImage` cached `UIImage(data:)` results — lazy-decoded, so the decode
happened on the main thread at first draw — and inserted them into `NSCache`
without a cost, so `totalCostLimit` did nothing and 200 full-resolution covers
could sit in memory at ~8 MB each.

Now `CoverDecode` downsamples with ImageIO to a 700 px long edge and forces the
decode at creation, and the cache is byte-accounted. `EntryCoverView` also lost
its per-cell `GeometryReader`, which was a layout pass per cell.

Manga pages keep full resolution (they are read, not glanced at) but are decoded
with `preparingForDisplay()` off the main actor and kept in `PageImageCache`, so
scrolling back over a page no longer decodes it again.

### 5. The chapter list recomputed ordering on every body pass

`EntryDetailView.orderedChapters` was a computed property: a scanlator pass plus
a full `localizedStandardCompare` sort, read two to three times per body
evaluation. It is now state, rebuilt when the chapters or the scanlator
preference change. `ChapterDisplay` also formatted a release date per chapter in
its initializer — 2 000 formatter runs to display ten rows — and now keeps the
`Date` and formats on access.

`MangaReaderView.navigableChapters` had the same shape (rebuilt twice per body
via `hasChapter`) and is now state too.

### 6. Statistics pulled the whole store into a view

`@Query private var chapters: [Chapter]` loaded every chapter in the database as
a SwiftUI dependency, and the "downloaded" tile faulted each chapter's
`downloadItem`. Replaced with one background pass of `fetchCount` plus the
history dates the charts actually need.

History and Updates grouped rows by a fully formatted timestamp string, which put
every row in its own section and rebuilt a format style per row. They now group
by `startOfDay` with one shared formatter.

### 7. The manga reader (second pass)

Found by reading the code, not by a trace — verify on a Release device build.

- **Every page turn saved.** `scheduleProgressSave` writes immediately after 3 s idle, which
  is every turn when reading page by page, and each save re-runs every `@Query` on the main
  thread. Manga progress is now `deferred` (30 s) and lands on close, chapter change and
  backgrounding.
- **Decoded pages were never released.** Each `MangaPageView` held its bitmap in `@State`, so
  a long chapter kept every page alive. Pages now drop the bitmap in `onDisappear`; the
  byte-accounted `PageImageCache` (160 MB) serves a quick scroll back, and the aspect ratio is
  remembered per page so the slot keeps its height instead of collapsing to a spinner.
- **Decoding ignored scrolling.** `Task.detached` was not cancelled when a page scrolled
  away and there was no limit on parallel decodes. Decoding is now `@concurrent`, cancellable,
  and gated to two at a time (`PageDecodeGate`).
- **Pages were drawn 3× oversized.** The bitmap was decoded at pixel width but tagged scale 1,
  so the GPU minified it every frame. It is now tagged with the display scale.
- **A drag gesture covered the whole strip** for the right-edge dismiss swipe. It is now a
  `UIScreenEdgePanGestureRecognizer` that only exists at the edge.
- **A chapter download stalled the reader four times a second.** Found in a device trace
  (Animation Hitches, iPhone 17, 2026-10-31): smooth for 20 s, then once a download
  started, 50–65 % of main-thread samples were in `ChapterDownloadManager.checkSpace`.
  It read `volumeAvailableCapacityForImportantUsage`, a synchronous call to the system's
  storage service of about 45 ms, once per page, on the main actor (the worker is
  `@MainActor`). That was a 45 ms stall every ~250 ms while reading. It explains why the
  reader was smooth on first open and choppy only *sometimes*: the queue resumes on
  `.active` (unlock, return from the app switcher) and download-ahead queues the next
  chapters when one is opened. The check now runs off the main actor, once per chapter.
  Rule: no storage-capacity query on the main actor, ever. The rest of a chapter's download
  (source calls, page requests, disk writes, the manifest) then moved into
  `ChapterDownloadManager.fetch`, a `@concurrent` job that takes plain values; the manager
  keeps only the queue's rows, a few writes and one save per chapter. Not yet verified on a
  device.
- **The webtoon strip grew for the whole session.** Each chapter scrolled into was stitched
  on and never removed, and every page whose height became known invalidated the flow
  layout's delegate metrics, which re-measures *every* row. Ten chapters in, each new page
  re-measured 600+ rows on the main thread, so the strip got choppier the longer a session
  ran. The strip now keeps the open chapter and one behind it (`StripWindow`, checked by
  `check.sh page-pipeline`); older rows are deleted once the strip is at rest, with the
  offset moved by their height so the page on screen does not move. This was a suspect
  for the choppiness above before the trace showed the download; it is a real cost in a
  long session but was not that cause. Not yet verified on a device.
- **Not done:** `ChapterCache.data` still rewrites the file's modification date on every read.
  Throttling it breaks the cache's LRU contract (checked by `check.sh page-pipeline`), so it
  stays unless a trace shows it matters.

### 8. Background work and scroll stalls (Phase 1 performance pass)

- **Non-blocking haptic engine startup:** `CHHapticEngine` powers down when idle (`isAutoShutdownEnabled = true`). The first scroll tick after a reading pause ran a synchronous `try engine.start()` on the main thread, causing 20–50 ms stalls. Changed to `engine.start(completionHandler:)` with scroll ticks skipped while starting and back-off on repeated failures.
- **Off-main library update and chapter merge:** `LibraryManager.updateLibrary` previously merged source details and chapters on the `@MainActor`, saving every 10 titles to the main context and re-running all active `@Query` properties. Merging and batch saves moved to a dedicated background actor (`LibraryUpdateMerger`) on an isolated `ModelContext`.
- **Targeted notification query:** `LibraryMaintenance.handle` previously ran `context.fetch(FetchDescriptor<Chapter>())` fetching all 30 000+ chapters in the database and walking `$0.entry` on main thread to check for updates. Replaced with a targeted `#Predicate<Chapter>` filtering directly on `dateFetch >= started` and gated to only run when notifications or auto-downloads are enabled.
- **Coalesced download saves:** `ChapterDownloadManager` saved on the main context after every single chapter download. Saves are now coalesced into batches of 3 while items remain queued.
- **Isolated TTS transport controls:** `ReaderTTSManager.shared` fired a 20 Hz periodic time observer on the main queue updating `elapsed`, causing the entire `ReaderView` and `WKWebView` to re-evaluate continuously. Extracted the playback controls into `ReaderTTSControlsHost` so only the overlay updates at 20 Hz.

## Still to look at

Ordered by expected payoff on device, not yet measured:

1. **`ChapterRow.audioCount`** filters the whole TTS record list per row, and
   every row observes `TTSOfflineLibrary`.
2. **`SourceManager` / plugin restore at launch** runs on the main actor in
   `ContentView.task`, ahead of the first frame's work.
3. **MangaFire `vrf`** is recomputed per request; check whether the extension
   caches it.

## Rules that came out of this

- **Never read a relationship count in a `body`.** Use `LibraryChapterCounts` or a
  `fetchCount` off-main. `Entry.unreadCount` is fine inside a background pass that
  has already faulted the chapters; it is not fine per cell.
- **Never `save()` from a scroll or progress callback.** Mutate and let
  `LibraryManager.flushProgress` land it.
- **Nothing render-blocking in the reader's `<head>`.** The chapter should paint
  from local bytes only.
- **Cache decoded images, not compressed data, and always with a cost.**
