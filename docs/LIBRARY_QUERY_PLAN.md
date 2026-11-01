# Library data flow: snapshots, a single writer, no live models in views

**Status** proposed, not started · **Written** 2026-10-25 · **For** a future agent

The reader hitches while scrolling a webtoon because an unrelated screen, the
library, re-fetches and re-derives its data every time reading progress is
written. This plan fixes the architecture that makes that possible. It does
**not** add a "pause while covered" switch: see *Rejected*.

## Evidence

Instruments trace (`./scripts/profile-device.sh`, Release build, iPhone 17,
30 s of webtoon scrolling), taken before any workaround:

| | |
|---|---|
| Hitches | 27, 633 ms total |
| Cause tag | 24 "expensive app update" (main thread), 1 GPU offscreen |
| Main-thread samples inside hitch windows | 571 |
| ...inside `LibraryView.body` | **325** |
| ...inside `NSManagedObjectContext.fetch` (the library `@Query`) | **154** |
| ...in the reader / webtoon strip | **0** |

The library is covered by the reader and shows nothing, yet it does the most
work on the main thread.

## The actual problem

Not "the library is alive under the reader". That is normal in SwiftUI and
cannot be switched off reliably. The problem is that **the library's inputs
change for reasons that do not change what it displays**.

1. `@Query` hands views live `@Model` objects and re-fetches whenever any
   managed object in the context changes. Writing one chapter's page position
   re-runs the whole library fetch.
2. Views read model properties directly (`entry.title`, chapter counts, cover,
   progress). Every such read is a dependency on that object, so a mutation
   invalidates every view that touched it, whether or not the displayed value
   changed.
3. Derivation (filter, category, search, sort, group, unread counts) happens in
   or beside `body` on the main thread, so each invalidation pays for all of it.
4. Writes come from many places (reader views, `LibraryManager`, trackers) with
   no single point that knows *what* changed, so nothing downstream can tell a
   progress tick from a membership change.

Any covered, backgrounded or merely distant screen with this shape will cost
frames on every write elsewhere. Fixing only the library would move the problem
to History or Updates.

## Target architecture

Three rules. Everything in the plan serves one of them.

### 1. Views render immutable snapshots, not live models

Introduce value types for what a screen shows, for example `LibraryItem`
(`id`, `title`, `coverURL`, `kind`, `unreadCount`, `totalCount`, `lastReadAt`,
category ids; `Sendable`, `Hashable`). Rows take a `LibraryItem`. No view in the
list touches an `Entry` or `Chapter`. A mutation to a model therefore cannot
invalidate a row; only a new snapshot value can.

### 2. A store owns the data and publishes only real changes

`LibraryStore` (`@Observable @MainActor`) holds the current snapshot array and
derived pages. It loads and derives **off the main thread** (a `@ModelActor`
for reads, a pure function for derivation), then publishes on the main actor
**only if the result differs** (`Equatable` comparison of the new snapshot
against the old). A progress write that does not change any displayed field
produces an identical snapshot, so the store publishes nothing and no view body
runs. That is the property that fixes this class of problem, and it holds
whether or not the screen is visible.

Derivation is a pure function,
`LibraryPages.derive(items, kind:, category:, search:, sort:) -> [LibraryItem]`,
unit-testable without SwiftUI or SwiftData and run off-main.

### 3. One writer, with typed change events

`LibraryManager` is already the funnel for most writes. Make it the only one
and have it emit typed events, for example
`.progress(chapterID)`, `.readState(entryID)`, `.membership`, `.categories`,
`.metadata(entryID)`. Stores subscribe and decide whether an event can affect
their snapshot. Progress ticks do not affect the library snapshot unless the
unread count changes. Do not rely on SwiftData change notifications to infer
what happened; the writer knows, so it says so.

Reader progress policy (how often to checkpoint) moves out of `MangaReaderView`
into a small service (`ProgressRecorder`) with the policy as testable code.
The reader reports positions; the service decides when to persist. This
replaces the debounce tasks currently living in the view.

## Plan

Each phase is independently shippable. Measure after each; stop early if the
success criteria are met.

### Phase 0: baseline and guard rails

1. Record a trace with the current workaround and write the numbers here.
2. Add a check script in the style of `scripts/check-library-*.sh` that will
   later assert the key property: *a progress write produces no library
   publish*. It can fail now; it is the target.

### Phase 1: snapshots and pure derivation

1. Define `LibraryItem` and a mapper from `Entry` (+ cached counts via the
   existing `LibraryChapterCounts`) to it.
2. Extract the filter/sort/group logic from `LibraryView` into
   `LibraryPages.derive`. Same behaviour, no SwiftUI types. Cover with the
   existing library check scripts (`check-library-filters`, `-sorts`,
   `-categories`, `-badges`).
3. Switch library rows and grid cells to take `LibraryItem`.

At this point `@Query` can still feed the mapper. Behaviour is unchanged; the
view is already decoupled from live models.

### Phase 2: the store

1. `LibraryStore` as above: loads via a `@ModelActor`, derives off-main,
   publishes on change only. Replace both `@Query` properties and `PageItemsCache`
   in `LibraryView`.
2. Remove the `isReaderPresented` guard in `pageItems(for:)` and the
   environment key if nothing else uses it. The store makes it unnecessary.
3. Selection, search text and sort stay as view state; they are *inputs* to
   `derive`, not stored results.

Success: with the reader open and progress being written, the library store
publishes nothing (the Phase 0 check passes) and `LibraryView` frames are absent
from the trace.

### Phase 3: single writer and events

1. Route every write that affects a snapshot through `LibraryManager` and have
   it emit the typed events. Grep for direct `modelContext` mutation of
   `Entry` / `Chapter` / `Category` in views and move them behind the manager.
2. Stores filter events cheaply (a progress event for a chapter that does not
   change `unreadCount` is dropped before any fetch).
3. Extract `ProgressRecorder` and delete the progress debounce/flush code from
   `MangaReaderView` (`scheduleProgress`, `flushProgress`,
   `settleAndFlushProgress`, `progressTask`, `unsavedPage`). Keep the guarantees:
   flush on close, chapter change and backgrounding.

### Phase 4: the same shape for other screens, as traces demand

History, Updates, entry detail (`EntryDetailView`), Browse. Apply snapshot +
store only to a screen that appears in a trace or shows a body that is not
trivially cheap. Do not convert speculatively.

## Rejected

- **Pause the library while the reader is presented.** It encodes presentation
  state into the data layer, has to be undone on every dismissal path (swipe,
  error, kill) or the library goes stale, is needed again for every other
  covered screen, and fixes only the case we happened to profile. The same
  cost would reappear for a screen that is merely off-screen in a tab.
- **Only caching in `body`.** Cheaper, but the fetch and invalidation remain,
  and the view still depends on live models.
- **A new persistence layer.** The problem is data flow, not SwiftData.

## Risks and notes

- Snapshots can go stale if an event is missed. The single-writer rule is what
  prevents this; the check scripts must cover add/remove from library, category
  edits, read-state changes, library update runs, and tracker sync.
- `@ModelActor` and Swift concurrency: models are not `Sendable`. Pass
  `PersistentIdentifier`s across the boundary and map to value types inside the
  actor. Verify the deployment target supports what is used.
- Reads off the main context see data after it is saved. Progress saves are
  deferred (`LibraryManager.deferredSaveInterval`); the library may show older
  progress for a while. That already holds today; do not fix it here.
- More types and indirection than a bare `@Query`. That is the cost, and it is
  justified only because this screen derives heavily from a large store. Keep
  `@Query` for small, simple screens.

## Already done (do not redo)

- Reader webtoon progress is held in memory and written after 4 s idle, on
  close, on chapter change, and when the app leaves the foreground. A reader-side
  workaround that cut the trigger frequency; Phase 3 replaces it with a proper
  service.
- `PageDecode`, `PageImageCache`, `PagePrerender` pre-decode pages. Unrelated to
  this problem.
- The webtoon strip is a `UICollectionView` (`WebtoonStrip`). The trace shows it
  is not the bottleneck; keep or revert it independently of this plan.

## How to verify

```sh
./scripts/profile-device.sh 30
```

Open a chapter and scroll for the whole window. In Instruments, open the
Hitches track, then Time Profiler with *Invert Call Tree* and *Hide System
Libraries*. Record hitch count, total ms and the share of samples in
`LibraryView`. Success is the library absent from the hitch windows **without
any code that knows the reader is open**, plus the Phase 0 check passing.
