# v2 rewrite — status

**Updated** 2026-10-29 · **Branch** `main` · **Version** 2.0.0 (build 3)
· **Latest update** Source migration reworked (one sheet, source-scoped bulk run, rate-limited
with backoff), Browse shows how many entries each source has

The rewrite replaces the v1 store with `SchemaV1`, adds a manga path end to end, and puts
every source behind one protocol (`CatalogSource`). Every source is native Swift, compiled into
the app; the JavaScript bridge is gone.

Migration from v1 is **dropped by decision**: the v1 store is discarded. The app store is
`default.store` (the interim `LNReader-v2.store` was folded into it). Fresh installs start empty; `.tachibk`
import already covers a manga library.

**Built** means it compiles and passes its headless checks. **Verified** means it has also been
used on the iPhone. The readers and the library are verified. Downloads, update scheduling,
backup/restore and narration are built but have never been exercised on a device — see
[Next, in order](#next-in-order).

## At a glance

| Area | State | Notes |
|---|---|---|
| Data model | **Built** | `SchemaV1`, `default.store`, v1 models deleted |
| Novel read path | **Verified** | Library, detail, chapter list, web reader, history, updates, stats |
| Manga read path | **Verified** | Pager + webtoon, cache, prefetch, progress; all reader gestures checked on device |
| Source abstraction | **Built** | `CatalogSource` / `NovelSource` / `MangaSource`; `SourceManager` registry |
| Native sources | **Built** | Light novels: Novel Fire, Novel Phoenix, Free Web Novel. Manga: MangaFire, AllManga, Manhwa18, 4KHD, Omega Scans, Atsumaru, Weeb Central, Kagane, PornPics, MetArt Hunter (ported from keiyoushi). All tested on a real device |
| Chapter lists | **Built** | Number ordering, all-chapters for manga, scanlator priority |
| Browse | **Built** | Split into Light Novels / Manga; native search, glass switcher |
| Downloads | **Built** | Novel text and manga pages, durable queue, offline reader paths, pause/retry/remove, Wi-Fi and storage guards. Not exercised on a device |
| Update scheduling | **Built** | App refresh, continued/processing tasks, per-title policy, notifications, new-chapter downloads. Not exercised on a device |
| Trackers | **AniList built** | Implicit-flow login, bind/edit sheet on detail, auto-update on finish, offline queue. Others not started |
| Backup / restore | **Built (local)** | Encrypted `.lnbk` snapshots, recovery key, merge restore; `.tachibk` import and export. Cloud sync remains deferred. Not exercised on a device |
| Library | **Verified** | Filters, per-category sort / display / update scope, badges — all checked on device. The category editor (More › Categories) is **Built**, not verified |
| Chapter fetching | **Verified** | Opening an entry no longer refetches; last-fetched time and a Refresh button |
| Entry links | **Built** | The detail screen shares a `lnreader://entry` link (source key + source-relative url + kind + title, see `Services/EntryLink.swift`); opening one pushes that entry onto the library stack. Custom scheme only — no universal link, so the link is tappable in Messages and Safari but not everywhere. Not exercised on a device |
| Performance | **Pass done** | Library counts cached off-main, reader writes coalesced, covers downsampled; numbers in [PERFORMANCE.md](PERFORMANCE.md), next rewrite in [LIBRARY_QUERY_PLAN.md](LIBRARY_QUERY_PLAN.md) |
| Extension repos, JS bridge, Kotlin/JS transpiler | **Removed** | Sources are native; adding one is a Swift file in `Services/Sources/Native/` |
| Migration (v1 → v2) | **Dropped** | User's call; fresh installs start empty. Importing another app's `.tachibk` is the only way in |

## Roadmap — Mihon / Yokai parity

Ordered by dependency: the per-series settings store comes first because reader modes,
filters and incognito all read it.

| # | Feature | State | Depends on |
|---|---|---|---|
| R1 | Per-series reader settings store | **Verified** | — |
| R2 | Per-series read mode (pager / webtoon / direction) | **Verified** | R1 |
| R3 | Tap-zone layouts | **Verified** | R1 |
| R4 | Volume-key page turns | **Verified** | R1 |
| R5 | Auto scroll | **Verified** | R1 |
| R6 | Hold to scroll, with swipe-to-change-speed | **Verified** | R5 |
| R7 | Library filters | **Verified** | — |
| R8 | Library sorts (per category) | **Verified** | R7 |
| R9 | Categories: per-category sort, display, update scope | **Verified** | R7, R8 |
| R10 | Library badges | **Verified** | — |
| R11 | Duplicate detection | Planned | — |
| R12 | Migrate manga / novel to another source, one or in bulk | Built, not verified | R11 |
| R13 | Incognito mode | Planned | — |
| R14 | Download UI/UX polish | **Built**, not used on a device | — |

### Reader (R1–R6)

Pure rules live in `Features/MangaReader/MangaReaderControls.swift`, checked headless by
`./scripts/check.sh reader-settings` (`MangaTapZoneLayout`, `HoldScrollConfig`,
`ScrollStep`, `VolumeKeyDetector`, `MangaControlSettings` under `manga.controls`).

- **R1/R2 settings.** `MangaReaderOverrides` (all optional, so a new setting never breaks
  saved data) resolve into `MangaReaderPreferences`, persisted under
  `mangareader.<sourceKey>::<url>`. Overrides win field by field; an empty override set is
  removed. "Use for all series" promotes to the global defaults; chapters opened outside a
  library entry are keyed by chapter URL.
- **R3 tap zones.** Default, L, Kindle, Edges, Disabled, plus invert, per series. RTL and
  invert are two reversals that cancel. Paged only; in webtoon a tap still toggles the
  controls. Always a simultaneous gesture, never an overlay — an overlay above a scroll view
  eats the drag.
- **R4 volume keys.** iOS reports a press only as an `AVAudioSession.outputVolume` change, so
  `VolumeKeyHost` parks media volume at 50 % while the reader is open, reads each change as up
  or down, and restores it on exit and on resigning active. A hidden `MPVolumeView` suppresses
  the HUD. Up = back, down = forward, invertable. Global, not per series.
- **R5/R6 scrolling.** `WebtoonScrollController` drives the `UIScrollView` from a
  `CADisplayLink` (SwiftUI has no per-frame offset API); the finger always wins. Hold-to-scroll
  disables the pan recognizer so the drag changes speed instead of position, and suppresses
  the would-be tap for 0.4 s. Both webtoon only.
- **Settings sheet:** layout, direction and tap zones are per series; volume keys and scroll
  speeds are global.

### Library (R7–R10)

- **Filters** (`library.filters`), **sorts** (`library.sorts`) and **display**
  (`library.displays`) are each one JSON value per category; a category with no entry follows
  the Settings default. Filters are tri-state (downloaded, unread, started, completed,
  tracked). Entries whose counts have not arrived yet pass, so the library never blanks.
- **Ascending means smallest first** everywhere, and an order starts in its natural
  direction, so a saved Alphabetical + Descending now reads Z to A. **Chapter Fetch Date**
  empties when Updates are cleared (`dateFetch` is the unseen-update stamp); "Last Updated" is
  labelled **Last Checked**. `LibraryView.hasLoadedCounts` holds the page until the first
  count pass lands, or the library visibly reshuffles on launch.
- **Update scope** is the `CategoryFlags.excludedFromUpdates` bit (carried by `.lnbk`).
  Exclusion wins when **any** category is excluded, while `updateLibrary(category:)` updates
  its own category regardless. Per-category sorts, display modes and filters are keyed by
  category **name**, so the editor (More › Categories) migrates them on rename and drops them
  on delete; categories can now be created without a Mihon import.
- **Badges:** unread (the old key, on), new chapters, downloaded count, source language (the
  last three off). "New" is unread with `dateFetch` set, so it clears with Updates. Counts
  stay off-main and extras are remembered so the sort pass and the cells do not evict each
  other.

### Library maintenance (R11–R13)

- **R11 duplicates.** On add-to-library, match by normalized title (and alt titles) across
  sources and warn with a "view existing / add anyway" choice. Index once, not per keystroke.
- **R12 migrate.** Built, not used on a device. **One entry:** the detail toolbar's Migrate
  button (its own button, next to Refresh — it was the only item of a `…` menu) → search the
  chosen sources (the source it is in is never searched) → confirm, which shows from → to, how
  many read chapters have a counterpart, and the carry options → the screen reports what carried
  over instead of closing over it, and Done opens the entry it created: the stack swaps its top
  for the new one (`EntryDetailView(entry:onReplace:)`), so Back goes to the library rather than
  to a book that just left it. **Bulk:** hold a source in Browse (0.4 s, the same hold the
  library and chapter lists use; it opens the sheet directly — no context menu, whose dismissal
  overlay hangs on screen for a beat) → the source, its entry count and the destination order →
  "Find matches" → review (live progress, untick anything, tap a row to change its match) →
  migrate. The source is the unit, so there is one bulk entry point; the library has none.
  **Destination order is one preference per content kind** (`migration.sources.<kind>` in
  UserDefaults), shared by every migration of that kind: set it once, it applies to the next
  entry and the next bulk run. It is stored whole and the current source is filtered per run, so
  editing the order while moving away from a source does not drop that source from the
  preference.
  Bulk takes the first source with a close title match (`MigrationMatcher.autoAcceptScore`);
  weaker hits start unticked. Chapters match by number (unnumbered ones by name) and carry read,
  bookmark, position and history; categories, tracking and per-series manga settings follow. A
  hidden chapter carries nothing. The old entry leaves the library but is never deleted
  (chapters and history stay); an option also deletes its downloads.
  **Politeness:** every search and chapter fetch goes through `MigrationPacer` — one request at
  a time per source, 1.2 s apart, `MigrationBackoff` retries (1.5 s doubling to a 20 s cap, ±jitter,
  three tries) and a source that uses up its tries rests 45 s so the remaining entries skip it
  instead of each waiting on it. Failed rows say which source did not answer and can be retried
  in place. Logic is in `Services/EntryMigration.swift` (checked by `check.sh migration`) and
  `EntryMigrationApply.swift`; screens in `Features/Migration/`. Not done: matching by cover or
  author, scanlator rules do not carry (names differ per source), and the bulk run is sequential
  per entry (two in flight), so forty entries take a few minutes by design.
- **R13 incognito.** A global toggle that suppresses history writes, reading progress and
  `lastReadAt`. Must be visible (banner or icon) so it is never on by accident, and must be
  respected by both readers and the downloader's auto-mark-read.

### Downloads (R14)

Built, not yet used on a device. Chapter rows end in a 44 pt download control
(`ChapterDownloadControl`): tap to download, then a menu per state (pause, cancel, run next,
retry, delete) with a progress ring while it runs. State and live progress come from
`ChapterDownloadManager.states` / `liveProgress`, keyed by chapter, so rows update without a
model lookup or a save. The chapter list header has Mihon's download menu (next 1 / 5 / 10 / 25
unread, all unread, all, delete). More → Downloads is an overview (count, storage, Wi-Fi,
pause/resume all), a reorderable queue with swipe actions (cancel, run next), downloads by
title and an empty state. Runs of selected chapters are drawn as one rounded block.

**While reading** (More → Downloads, `downloads.aheadCount`, `downloads.deleteAfterRead`,
`downloads.keepBookmarked`): *Download ahead* queues the next 1–10 chapters by number the first
time a chapter is read each session (`ChapterDownloadManager.chapterOpened`, called from the
two `LibraryManager.record…` paths). *Delete after reading* removes the download of the chapter
N places behind the one just finished (`chapterFinished`), sparing bookmarks by default. Rows
in the downloads screen open the title. *Remove when marked as read*
(`downloads.deleteOnMarkRead`, off by default) deletes downloads of chapters marked read from the
selection bar, including "mark previous as read".

Not done from Mihon: downloaded-only mode, per-title size, split tall images.

## Chapter fetching is manual

Opening an entry no longer refetches it. `EntryDetailView.fetchDetails` fetches on its own
only when there is nothing stored to show: a browse result, or a library entry with no
`lastUpdate`. A stored entry shows "Last fetched …" with a **Refresh** button; a failed
refresh raises an alert and leaves the page up. `addToLibrary` stamps `lastUpdate` when
chapters came with the add, so a title just added from Browse does not refetch on first
open. Library-wide updates (pull to refresh, background) are unchanged.

## Offline, background work, backups

Full detail in [OFFLINE_LIBRARY.md](OFFLINE_LIBRARY.md); the shape:

- **Downloads.** More → Downloads: title batches, per-chapter actions, durable queue,
  pause/retry/remove, progress, Wi-Fi waiting, 200 MB free-space guard. Novels save chapter
  HTML/text; manga saves page files. Both readers prefer validated durable files before the
  network. Chapter folders are published with a manifest only after completion.
- **Background work.** Task identifiers registered and declared. User batches request iOS 26
  continued processing; pending work resumes in a scheduled processing task. App refresh has
  an interval, Wi-Fi preference, unread/completed filters, per-entry strategies, optional
  notifications and new-chapter downloads.
- **Backup.** AES-256-GCM `.lnbk` with a random Keychain recovery key; merge restore that
  keeps existing details and newer progress. Media, audio, source packages and credentials
  are excluded. `.tachibk` import/export handles Mihon/Yokai/Tachimanga files; cloud sync is
  still deferred.

## Trackers

AniList only: implicit-flow login via `ASWebAuthenticationSession` with our own client ID and
`lnreader://anilist-auth`, token in the Keychain, search/bind/edit sheet on the detail
screen, auto-update on chapter finish (3 s debounce, highest chapter read), and a
`PendingTrackUpdate` queue flushed on foreground and network change. Other trackers are not
started; the protocol is in [MANGA_SUPPORT_PLAN.md](MANGA_SUPPORT_PLAN.md) §2.

## Narration

Breeze TTS 2 with the original 16-bit checkpoint, four LNReader voice designs plus custom
reference voices, default narrator "Warm narrator"; downloaded Qwen packages stay readable.
The app validates the Breeze model and accepts zero-length word-timing bins rather than
inventing highlight durations.

The superseded Qwen design is kept in [TTS_REVAMP_PLAN.md](TTS_REVAMP_PLAN.md) for reference
only. **The backend docs have not caught up** — see open issue 6. Playback on the device
(lock screen, backgrounding, seeking against real audio) has not been verified.

## Open issues

1. **MangaFire captcha.** A `403 {"error":"captcha_required"}` surfaces as an error.
   Upstream solves it with OpenCV.js in a WebView and a `waf_pass` cookie. The host
   primitive now exists (`webview.capture`), but the MangaFire bundle does not use it.
2. **Category editor not verified.** More › Categories names, reorders and deletes categories,
   sets their update scope, and picks their titles with a searchable list (membership is
   written on `Category.entries`). Built only; it has not run on a device. A shortcut that
   assigns a category from the entry detail screen is still missing.
3. **Global search is novel-only.** `GlobalSearchView` iterates `sourceManager.novelSources`;
   it is hidden on the Manga tab rather than shown broken.
4. **Bundle signing.** Repositories pin a signing-key fingerprint, but bundle bytes are not
   verified.
5. **UI follow-ups from the audit** (Glur private API, Dynamic Type in narrow layouts): see
   [UI_AUDIT.md](UI_AUDIT.md). The audit's right-edge-dismissal concern is settled — the
   device pass showed the edge swipe does not advance a page.
6. **Backend narration docs are stale.** The app moved to Breeze TTS 2 on 24 October, but
   `lnreader-backend/docs/` still documents the Qwen pipeline (snapshot 20 October) and the
   `breeze-tts-2.md` that an earlier entry here referred to was never written. Whoever owns
   the backend should write it before the Qwen notes get mistaken for current.

## Next, in order

1. **Device pass on the parts that have never been exercised.** Readers and the library are
   verified; what is left is offline reading in airplane mode (both kinds), queue
   cancellation and recovery after relaunch, `.lnbk` export/import through Files with a
   fresh-device recovery key, background scheduling and expiration with notifications, and
   Breeze narration playback.
2. **Then R11 → R14** (duplicates, migrate source, incognito, download UI).

Sources are native Swift. The extension repository UI, the JS bridge and the Kotlin/JS shims were removed.

## Verification

`./scripts/check.sh all` runs every check that needs no setup; `./scripts/check.sh` alone
lists them. Each one compiles a program from `tests/` against the app files it touches and
runs it — no Simulator, no XCTest, no SwiftPM target (see the header of `typecheck.sh` for
why).

Offline checks (no device, no network):

| Check | Covers |
|---|---|
| `scripts/typecheck.sh` | Whole app, `-D DEBUG` so DEBUG-only code is checked |
| `check.sh schema` | CRUD, cascades, uniqueness, history cascade, download queue |
| `check.sh foundation` | Status mapping, identity, filters, dates, HTTP values |
| `check.sh chapter-sync` | Chapter parsing (40 Yokai cases), merge, delete guard |
| `check.sh page-pipeline` | Cache LRU, loader dedupe, prefetch order, progress |
| `check.sh scanlators` | Dedup/hide rules, hidden-winner fallback |
| `scripts/try-native.sh` | Every native source against its live site (network; not part of `all`) |
| `check.sh reader-settings` | Per-series reader settings: resolution, persistence, reset, make default |
| `check.sh offline` | Backup encryption, rejection/merge rules, durable manifests, manual vs automatic update policy |
| `check.sh mihon-backup` | `.tachibk` import: merge rules, bundled source ids; `TACHIBK_SAMPLE=` runs a real file |
| `check.sh native-comments` | Native comment provider parsing (needs the SwiftSoup checkout or network, and a normal terminal) |
| `check.sh tts-contracts` | Swift timing contracts and real WKWebView text extraction |
| `check.sh player <package>` | AVPlayer seek and highlight against a downloaded narration package |
| `check.sh filters` | Tri-state filters, per-category store, count-based rules |
| `check.sh sorts` | Every sort order and direction, nil dates, tie-breaks, per-category store |
| `check.sh categories` | Per-category display store, exclude-from-updates flag, update scope |
| `check.sh badges` | Badge settings, count clamping, new-vs-unread, language labels |

Live and performance:

| Script | Covers |
|---|---|
| `scripts/try-mangafire.sh` | Live MangaFire through the host (network required) |
| `scripts/try-allmanga.sh` | Live AllManga through the host, including `webview.capture` (network required) |
| `scripts/profile-hotpaths.sh` | Library counts, progress writes, chapter rows and ordering at library scale |
| `scripts/profile-device.sh` | Release build on a device: hitch and Time Profiler trace |

Device builds come from `./scripts/build-ipa.sh` (`release` for a Release build, `--checks`
to typecheck first). It builds, packages and sanity-checks the archive, and writes
`LNReader-<version>-unsigned.ipa` here in `lnreader-ios/`:

```sh
./scripts/build-ipa.sh              # Debug
./scripts/build-ipa.sh release      # Release
```

`ENABLE_DEBUG_DYLIB=NO` matters: the default Debug build is a stub launcher plus a dylib,
which is fragile once re-signed.

## Decisions worth remembering

- **Invariant: behave consistently.** The same kind of surface must act the same way across
  the app. Reader settings (novel and manga) are a half-height sheet with a single `.medium`
  detent; scrolling never grows it. Change one, change the other.
- **Swipe right from the left edge goes back.** Pushed screens get the system gesture; the
  full-screen readers use `EdgeSwipeDismiss` (screen-edge recognizer, so it never competes
  with scrolling or paging) and ignore it while a sheet is open. The manga reader also keeps
  its leftward swipe from the right edge. New full-screen surfaces that hide the back button
  must add it.
- **Chapter lists select by holding.** Hold a row to start selecting; tap rows to toggle,
  hold another row to take everything between. `ChapterSelection` (in `ChapterRow.swift`) is
  owned by the screen so `ChapterSelectionBar` pins to it: Read, Unread, Download, and a More
  menu. Rows have no context menu — it shared the long press. Only library entries select; a
  browse result has no stored chapters to change.
- **Settings screens use `.settingsScreen(_:)`** (`Design/Theme.swift`): large sentence-case
  title. Do not title-case labels ("Reader settings", "Sort order").
- **`Entry.lastReadAt` is a cached column.** The library sorts by "recently read" and a
  predicate cannot walk chapters → history.
- **`Chapter.isDownloaded` is computed**, not stored, so it cannot drift from the queue.
- **Order by chapter number, never `sourceOrder`.** MangaFire lists newest-first, novel
  sources oldest-first; the index means different things per source.
- **Both kinds list every chapter inline** on the detail screen. `CatalogSource.chapters`
  returns the whole list for novels too; the old 10-chapter window and "All N chapters"
  sheet are gone. The paged `ChapterDirectoryView` remains only for the readers.
- **Scanlator rules live in UserDefaults**, keyed by `sourceKey::url` — a schema migration
  for a view preference is not worth it. Hiding and priority are **independent**: hiding
  applies on its own, priority only merges duplicate chapter numbers. The stored key for the
  priority toggle is still `enabled`.
- **The webtoon never uses `scrollPosition(id:)`.** It treats the binding as the position of
  record: when auto scroll, hold-to-scroll or the volume keys move the `UIScrollView` offset
  underneath it, the next re-render pushed the stale id back and the strip snapped to the top
  of the page it was leaving. The current page is read with `onScrollTargetVisibilityChange`
  and jumps are one-shot (`ScrollViewReader`).
- **Grey means secondary, never tappable.** The `AccentColor` asset is primary (black/white),
  so buttons, links and toolbar items read as primary text; only metadata is `.secondary`. An
  earlier 62% grey accent made every button look like a footnote. Switches get the
  `AppTheme.controlFill` track from `AppToggleStyle`, applied once at the root; never a root
  `.tint`, which beats button roles and turned destructive swipe actions white. Colours go
  through `AppTheme` tokens (`hairline`, `surface`, `warning`), not `Color.gray.opacity(…)`.
- **Settings sheets are partial-height** (`.medium`/`.large` detents), not full-screen modals.
- **MangaFire's "token" is upstream code, not a secret.** `VrfSigner.kt` is three
  substitution stages over the sorted query string; ported byte for byte it returns 200.
- **Performance rules are in [PERFORMANCE.md](PERFORMANCE.md).** The two that bite most: no
  relationship counts in a `body` (use `LibraryChapterCounts`), and no `save()` from a scroll
  or progress callback (mutate, let `LibraryManager.flushProgress` land it).

## Gotchas for the next session

- **The type checker gives up before it gives an error.** `ReaderView` and `LibraryView`
  bodies are split into computed properties for that reason; a 25-modifier body fails with
  "unable to type-check in reasonable time".
- **`LNReader.xcodeproj` lists files individually.** New `.swift` files must be added to the
  target or the build silently misses them. `project.yml` exists and uses directory sources,
  but XcodeGen is not installed here (brew cannot install it in this sandbox), so the project
  file is patched by script; verify membership by counting files on disk against the Sources
  phase.
- **Never let that patch touch non-Swift references.** An earlier version removed
  `Assets.xcassets` and the app icon, and the build still succeeded.
- **`xcodebuild` needs the sandbox bypassed and the foreground.** Inside the sandbox SPM
  resolution dies with `sandbox-exec: sandbox_apply: Operation not permitted`.
