# Working on LNReader for iOS

What an agent must assume before changing code here. Each point is condensed from `docs/`;
the doc named in brackets has the reasoning. Start with `docs/V2_PROGRESS.md` for status.

## Ground rules

- **v2 is a hard break from v1.** The store is `default.store`, schema `SchemaV1`. The old v1
  data is discarded and there is no v1 migration; do not write one. [V2_PROGRESS]
- **On device only, sideloaded.** No server-side source execution; no App Store, so review rules
  do not apply, code signing does. [MANGA_SUPPORT_PLAN]
- **Built is not verified.** "Built" means it compiles and passes headless checks. "Verified"
  means used on an iPhone. Downloads, update scheduling, backup/restore and narration have
  never run on a device. Do not report a feature as working from a typecheck alone, and do not
  edit the docs to say it is. [V2_PROGRESS]
- **Some areas are on hold by the user's decision:** v1 migration. Do not start it. The JS
  bridge, extension repos and Kotlin/JS transpiler were removed; do not bring them back.
  [V2_PROGRESS]
- `docs/UI_AUDIT.md` and `docs/TTS_REVAMP_PLAN.md` are historical records. Narration is
  Breeze TTS 2, not Qwen. [V2_PROGRESS]
- **A ported source has an upstream baseline.** `.github/upstream-sources.json` records the
  upstream commit each port was written against; `.github/workflows/source-drift.yml` checks it
  daily and files one issue per drifted source. Do not bump `ported_sha` unless the port really
  matches upstream — the bump is what closes the issue. A new port adds an entry.
  [ADDING_A_SOURCE]

## Build and checks

- `./scripts/typecheck.sh` typechecks the whole app (with `-D DEBUG`). `./scripts/check.sh all`
  runs every headless check; `./scripts/check.sh` lists them. Checks compile a program from
  `tests/` against the app files they touch. There is no Simulator, XCTest or SwiftPM target.
- **New `.swift` files must be added to the target in `LNReader.xcodeproj` by hand.** The
  project lists files individually and a missing file fails silently. XcodeGen is not
  installed, so `project.yml` is not the source of truth. When patching the project, never
  touch non-Swift references: an earlier patch removed `Assets.xcassets` and the app icon and
  the build still passed. Validate with `plutil -lint LNReader.xcodeproj/project.pbxproj`.
- `xcodebuild` needs the sandbox bypassed and the foreground (SPM resolution fails inside it).
- Device builds: `./scripts/build-ipa.sh [release]`. Keep `ENABLE_DEBUG_DYLIB=NO`.
- **The type checker gives up before it gives an error.** Big bodies (`ReaderView`,
  `LibraryView`) are split into computed properties; do the same rather than adding a 25th
  modifier.

## Haptics

- **Every vibration goes through `Haptics.shared` (`Services/Haptics.swift`).** It honours the
  app-wide switch (Settings › General › Haptics), the strength setting and, for scroll cues,
  the scroll-haptics switch. Never create a `UIImpactFeedbackGenerator`, `CHHapticEngine` or
  plain `.sensoryFeedback` in a view: use `Haptics.shared.impact(_:)` / `.selection()` /
  `.notify(_:)` or a named cue, and the `.hapticFeedback(_:trigger:)` view modifier in place of
  `.sensoryFeedback`.
- A new cue gets a named method in `Haptics.swift`. *When* to fire is decided at the call site
  (`ScrollHaptics.swift`, `MangaReaderControls.swift`); `Haptics.swift` only decides how it feels.

## Performance rules [PERFORMANCE, LIBRARY_QUERY_PLAN]

- **Never do expensive work on the main thread if it can hurt the UX.** Walking relationships
  across a library, encoding or decoding large payloads, base64, file I/O and big saves go to a
  background `ModelContext` (pass `PersistentIdentifier`s and `container`, not models) or a
  detached task. Show progress (a spinner) while it runs and hop back only to publish results.
  Sync-now froze the app by building its whole upload on the main actor.
- **Debug builds log main-thread stalls.** `MainThreadWatchdog` logs a stack for any stall
  over 40 ms (subsystem `com.lnreader`, category `hang`). An `async` method on a `@MainActor`
  type still runs its synchronous parts on main; heavy work goes in a `@concurrent` function
  that takes plain values, as `ChapterDownloadManager.fetch` does.
- **Never read a relationship count in a `body`.** Use `LibraryChapterCounts` or a background
  `fetchCount`. `Entry.unreadCount` is only fine in a background pass.
- **Never `save()` from a scroll or progress callback.** Mutate the model and let
  `LibraryManager.flushProgress` write it. Every save re-runs every `@Query` in the app,
  including screens hidden under the reader.
- Nothing render-blocking in the reader's `<head>`; chapters paint from local bytes.
- Cache decoded images, not compressed data, and always with a cost.
- Derived lists (chapter ordering, navigable chapters) are state rebuilt on change, not
  computed properties read several times per body.
- The library rewrite (snapshots, a single writer, typed change events) is proposed, not
  started. Do not add a "pause while the reader is open" switch; it was rejected.

## Data model

- `Entry.lastReadAt` is a cached column (predicates cannot walk chapters → history).
  `Entry.lastReadAt` and `History.lastRead` refresh at most once a minute.
- `Chapter.isDownloaded` is computed, never stored.
- **Chapter order lives in `Services/ChapterOrder.swift`; do not sort chapters inline.** One
  invariant: `sourceOrder` 0 is the **oldest** chapter. `ChapterOrder.normalized` enforces it at
  the boundary (a source's list is reversed once if it counts down — numbers decide, dates when
  the numbers are unusable), `oldestFirst` / `newestFirst` are the only sorts, and
  `display(_:ascending:)` is the only place the user's `chapters.ascending` setting is applied.
  Nine call sites used to sort for themselves and disagreed about which end was newest, so the
  list could show chapter 0, 1, 2 at the top with "Newest first" selected. A new consumer calls
  this file; it does not write its own `.sorted`.
- Manga sources return the whole chapter list; novels keep the windowed preview.
- Scanlator rules live in UserDefaults keyed `sourceKey::url`. Hiding and priority are
  independent.
- **A hidden or merged-away chapter does not exist.** `Chapter.hidden` is the one answer,
  written only by `ChapterVisibility` from `ScanlatorRules`. Anything that counts, lists,
  queues or navigates chapters filters `!hidden` (in the predicate where there is one, or
  `Entry.visibleChapters`); never re-run the scanlator rules in a view. A new consumer of
  chapters has to do the same, or the next "Updates still shows it" bug is yours. A copy of
  an already-read chapter is marked read by `ChapterTwins`, which also drops its `dateFetch`
  so it never enters Updates.
- The schema is `SchemaV2`; `SchemaV1.swift` is frozen for the migration. Further model
  changes add a `SchemaV3` and a stage.
- Per-series manga settings are optional overrides (`MangaReaderOverrides`) stored under
  `mangareader.<sourceKey>::<url>`, so a new setting never breaks saved data.
- Opening an entry does not refetch. Only a browse result or an entry with no `lastUpdate`
  fetches on its own.

## UI invariants [V2_PROGRESS]

- **Behave consistently.** The same kind of surface acts the same everywhere. Novel and manga
  reader settings are sheets with `.medium` and `.large` detents, opening at `.large`;
  change one, change both. Other settings sheets stay partial-height.
- **Swipe right from the left edge goes back.** Full-screen surfaces that hide the back button
  must add `EdgeSwipeDismiss` and ignore it while a sheet is open.
- **On the detail screen a control lives with what it acts on.** Hero: one primary button.
  `EntryActionBar`: up to four stateful entry tiles. Toolbar: visible Refresh and Migrate
  buttons (no pull to refresh; pulling down goes back). Do not bury a real action in a
  one-item `…` menu; an overflow menu earns its place once it holds several.
  Chapter header: search and one sort/filter menu. [DETAIL_SCREEN]
- **Toolbar actions run least to most likely used, left to right.** The right end of the bar is
  the easiest corner for a right thumb, so the routine action takes it. On the detail screen
  Refresh is rightmost, then Share, then the web view, and Migrate — once per broken source —
  is furthest left.
- **A migrated entry replaces the screen it came from.** After a single migration
  `EntryDetailView(entry:onReplace:)` calls `onReplace` with the new entry; the stacks that push
  it (Library, Updates, History) swap the top of their `NavigationPath`, so Back goes to the
  library instead of to a book that just left it. A new stack that pushes the detail should pass
  a closure too — without one the screen just pops, which is the old behaviour. Do not route this
  through a shared environment object: every stack that exists would answer the request, and a
  background tab would push into its own path.
- **Chapter lists select by holding.** No context menu on chapter rows; it shares the long press.
- **A bulk action lives with the thing it acts on.** Migrating many entries is a property of
  their source, so it starts by holding a source in Browse (`MigrateSourceSheet`); there is no
  library-wide bulk entry point, and adding one back means two flows to keep in step. One entry
  migrates from its detail toolbar. Anything that walks a list of entries against sources goes
  through `MigrationPacer` (one request per source at a time, spaced, backoff, cool-down) rather
  than firing a burst. The source row is a button with a `LongPressGesture`, not a
  `NavigationLink` with a `.contextMenu`: the system menu lifts the row into a preview and fades
  that overlay out on dismissal, which reads as the screen sticking after you back out. Same
  hold as `InteractiveListRow` and `ChapterRow`.
- Settings screens use `.settingsScreen(_:)` for their sentence-case title.
- **Grey means secondary, never tappable.** The `AccentColor` asset is primary, so buttons and
  links read as primary text; only metadata is `.secondary`. Switches get the `controlFill`
  track from `AppToggleStyle` at the root; never add a root `.tint` (it beats button roles, so
  destructive swipes turn white) or tint toggles one by one. Use `AppTheme` tokens
  (`hairline`, `surface`, `warning`), `.primaryActionStyle()` for a filled call to action, and
  `foregroundStyle`, never `foregroundColor` or `Color.gray.opacity(…)`.
- Text uses `Typography` tokens, which scale with Dynamic Type. Animations go through
  `AppMotion`, which returns nil under Reduce Motion.
- Reader tap zones are simultaneous gestures, never an overlay above the scroll view.
- **The webtoon never uses `scrollPosition(id:)`.** Read the page with
  `onScrollTargetVisibilityChange`; jumps are one-shot through `ScrollViewReader`.

## Sources and extensions [MANGA_SUPPORT_PLAN]

- Every source is a `CatalogSource` (`NovelSource` / `MangaSource`) in
  `Services/Sources/CatalogSource.swift`; `SourceManager` is the registry.
- Sources are native Swift in `Services/Sources/Native/`, keyed `builtin:<id>`. A new one is a
  file there, an entry in `NativeSources.all()`, and (manga) its Mihon id in `NativeSourceIDs`.
  `scripts/try-native.sh` runs it against the live site.
- Entry and chapter urls are persisted, so a source keeps returning the shape it always did.
- The source returns a `URLRequest` for each page image and Swift downloads it.
- MangaFire's "token" is upstream code ported byte for byte, not a secret.
- **A multisrc family is one class, not one class per site.** `MasonrySource` (keiyoushi's
  `lib-multisrc/masonry`) is configured per site: `MasonrySource(id:name:baseURL:)` in
  `NativeSources.all()`, one line each. Do not copy the file per domain.
