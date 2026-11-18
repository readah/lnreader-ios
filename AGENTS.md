# Working on LNReader for iOS

What an agent must assume before changing code here. Reasoning lives in `docs/` (the doc in
brackets); `docs/V2_PROGRESS.md` has status.

## Ground rules

- **v2 is a hard break from v1.** Store `default.store`, schema `SchemaV4`. The v1 data is
  discarded: do not write a migration. [V2_PROGRESS]
- **On device only, sideloaded.** No server-side source execution; no App Store, so code signing
  matters and review rules do not. [MANGA_SUPPORT_PLAN]
- **Built is not verified.** "Built" = compiles and passes headless checks; "verified" = used on
  an iPhone. Downloads, backup and restore are verified; update scheduling and narration are not.
  Never report a feature as working from a typecheck, and do not edit the docs to say so.
  [V2_PROGRESS]
- **On hold:** v1 migration. Removed, not to be restored: the JS bridge, the extension repos, the
  Kotlin/JS transpiler. [V2_PROGRESS]
- `docs/UI_AUDIT.md` and `docs/TTS_REVAMP_PLAN.md` are historical. Narration is Breeze TTS 2.
- **A ported source has an upstream baseline** (`.github/upstream-sources.json`, checked daily by
  `source-drift.yml`). Bump `ported_sha` only when the port really matches — the bump closes the
  issue. A new port adds an entry. [ADDING_A_SOURCE]
- **Own the shape of the code.** Rewrite rather than append; delete what nothing reads. An
  abstraction with one caller is a bug; nothing is built "for later". Share a *rule*
  (`ChapterOrder`, `LibrarySort`), not lines that differ in their inputs.

## Build and checks

- `./scripts/typecheck.sh` typechecks the app (`-D DEBUG`); `./scripts/check.sh all` runs the
  headless checks (`./scripts/check.sh` lists them), which compile programs from `tests/` against
  the app files they touch. No Simulator, XCTest or SwiftPM target.
- **New `.swift` files go into the target in `LNReader.xcodeproj` by hand** — files are listed
  individually and a missing one fails silently. XcodeGen is not installed. Never touch non-Swift
  references: losing one does not fail the build. Check with
  `plutil -lint LNReader.xcodeproj/project.pbxproj`.
- `xcodebuild` needs the sandbox bypassed and the foreground (SPM resolution fails inside it).
- Device builds: `./scripts/build-ipa.sh [release]`; keep `ENABLE_DEBUG_DYLIB=NO`.
- **The type checker gives up before it gives an error.** Split big bodies (`ReaderView`,
  `LibraryView`) into computed properties instead of adding another modifier.

## Haptics

- **Every vibration goes through `Haptics.shared`** (app-wide, strength and scroll-haptics
  switches). Never create a `UIImpactFeedbackGenerator`, `CHHapticEngine` or `.sensoryFeedback` in
  a view: use `impact(_:)`, `.selection()`, `.notify(_:)` or a named cue, and
  `.hapticFeedback(_:trigger:)`.
- A new cue is a named method in `Services/Haptics.swift`; *when* it fires belongs to the call
  site.

## Performance [PERFORMANCE, LIBRARY_QUERY_PLAN]

- **Never do expensive work on the main thread if it can hurt the UX.** Relationships, big
  payloads, base64, file I/O and big saves go to a background `ModelContext` (ids and the
  container, not models) or a detached task; show progress, hop back only to publish.
- **Debug builds log stalls over 40 ms** (`MainThreadWatchdog`, category `hang`). An `async`
  method on a `@MainActor` type still runs its synchronous parts on main: heavy work goes in a
  `@concurrent` function taking plain values, as `ChapterDownloadManager.fetch` does.
- **Never read a relationship count in a `body`.** Use `LibraryChapterCounts` or a background
  `fetchCount`; `Entry.unreadCount` is only fine in a background pass.
- **Never `save()` from a scroll or progress callback.** Mutate and let
  `LibraryManager.flushProgress` write it; every save re-runs every `@Query` in the app.
- Nothing render-blocking in the reader's `<head>`; chapters paint from local bytes.
- Cache decoded images, not compressed data, and always with a cost.
- Derived lists (chapter order, navigable chapters) are state rebuilt on change, not computed
  properties read several times per body.
- The library rewrite (snapshots, one writer, typed changes) is proposed, not started. Do not add
  a "pause while the reader is open" switch; it was rejected.

## Data model

- `Entry.lastReadAt` is a cached column (predicates cannot walk chapters → history); it and
  `History.lastRead` refresh at most once a minute. `Chapter.isDownloaded` is computed, never
  stored.
- **Chapter order lives in `Services/ChapterOrder.swift`; never sort chapters inline.**
  `sourceOrder` 0 is the **oldest** chapter; `normalized` enforces that at the boundary,
  `oldestFirst` / `newestFirst` are the only sorts, and `display(_:ascending:)` is the only place
  `chapters.ascending` is applied.
- **Library order lives in `Models/Enums/LibrarySort.swift`; never sort `Entry`s inline.**
  `facts(for:counts:)` builds what an order ranks by (columns plus the count pass, never the
  `chapters` relationship), `sorted(_:counts:cache:)` applies it and `LibrarySortCache` reuses the
  answer. The grid and Minimal Mode's shelf both call it.
- Manga sources return the whole chapter list; novels keep the windowed preview.
- Scanlator rules live in UserDefaults keyed `sourceKey::url`; hiding and priority are independent.
- **A hidden or merged-away chapter does not exist.** `Chapter.hidden` is written only by
  `ChapterVisibility`; anything that counts, lists, queues or navigates chapters filters `!hidden`
  (in the predicate, or `Entry.visibleChapters`). Never re-run the scanlator rules in a view.
  `ChapterTwins` marks a copy of a read chapter read and drops its `dateFetch`.
- Schema is `SchemaV4`; `SchemaV1`–`SchemaV3` are frozen. A model change adds `SchemaV5` and a
  stage.
- Per-series manga settings are optional overrides (`MangaReaderOverrides`) under
  `mangareader.<sourceKey>::<url>`.
- Opening an entry does not refetch; only a browse result, or an entry with no `lastUpdate`.

## UI invariants [V2_PROGRESS]

- **Every screen paints the light field itself** with `.appBackdrop()`; lists and forms add
  `.scrollContentBackground(.hidden)` (`.settingsScreen` does both). No opaque background of its
  own, reader surfaces excepted.
- **Grey means secondary, never tappable.** `AccentColor` is primary, so buttons read as primary
  text. Toggles take `controlFill` from `AppToggleStyle` at the root: never add a root `.tint` (it
  beats button roles). Use `AppTheme` tokens, `.primaryActionStyle()`, and `foregroundStyle` —
  never `foregroundColor` or `Color.gray.opacity(…)`.
- Text uses `Typography`; animation goes through `AppMotion` (nil under Reduce Motion). Settings
  screens use `.settingsScreen(_:)`; reader settings are sheets at `.medium`/`.large`, opening at
  `.large`, with the novel and manga versions changing together. Other sheets stay partial-height.
- **Toolbar actions run least to most likely used, left to right** (the right end suits a right
  thumb). Never put a single action in a `…` menu.
- Detail screen: one primary button in the hero, up to four stateful tiles in `EntryActionBar`,
  and a toolbar of one `…` menu (cover, Migrate, web view, Share) with Refresh beside it. No pull
  to refresh — pulling down goes back. Chapter header: search and one sort/filter menu.
  [DETAIL_SCREEN]
- **Minimal Mode is switched by the title, both ways**: a vertical swipe on the library's title
  enters, the same swipe on the page title inside leaves (`MinimalPageHeader`), one
  `LibrarySwipeInteraction.isTitleSwipe` predicate. No button; the Appearance toggle is the
  non-gesture path. The entry pan must not scroll the list under it.
- **Swipe right from the left edge goes back.** Surfaces that hide the back button add
  `EdgeSwipeDismiss` and ignore it while a sheet is open.
- **A migrated entry replaces the screen it came from**: `EntryDetailView(entry:onReplace:)` and a
  stack that swaps its `NavigationPath` top; a new stack passes a closure too. Never route it
  through a shared environment object — every stack would answer.
- **Chapter lists select by holding**; no context menu on rows. Library rows are a `Menu` with a
  `primaryAction`; a source row is a button with a `LongPressGesture`. No manual ordering.
- **A bulk action lives with what it acts on**: migrate by holding a source in Browse
  (`MigrateSourceSheet`) or from one entry's toolbar; there is no library-wide entry point.
  Anything walking entries against sources goes through `MigrationPacer`.
- Reader tap zones are simultaneous gestures, never an overlay above the scroll view.
- **The webtoon never uses `scrollPosition(id:)`**: read with `onScrollTargetVisibilityChange`,
  jump once through `ScrollViewReader`.

## Sources [MANGA_SUPPORT_PLAN]

- Every source is a `CatalogSource` (`NovelSource` / `MangaSource`) in
  `Services/Sources/CatalogSource.swift`; `SourceManager` is the registry.
- Sources are native Swift in `Services/Sources/Native/`, keyed `builtin:<id>`. A new one is a
  file there, an entry in `NativeSources.all()` and (manga) its Mihon id in `NativeSourceIDs`.
  `scripts/try-native.sh` runs it against the live site.
- Entry and chapter urls are persisted: a source keeps returning the shape it always did.
- The source returns a `URLRequest` per page image; Swift downloads it.
- MangaFire's "token" is upstream code ported byte for byte, not a secret.
- **A multisrc family is one class, not one class per site**: `MasonrySource(id:name:baseURL:)`,
  one line per site in `NativeSources.all()`.
