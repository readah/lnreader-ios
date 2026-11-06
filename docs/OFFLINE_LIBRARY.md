# Offline chapters, scheduled updates, and local backups

Implemented on 2026-10-22. These features cover novels and manga and do not change
extension hosting, repositories, transpilation, or captcha handling.

## Download and read

- Add a title to the library. In **More → Downloads**, choose the title and download
  unread or all chapters. Long-press a saved chapter for a single-chapter download.
- Novels save the source's chapter HTML/text. Embedded remote images are not bundled.
  Manga resolves each source image request and saves all page bytes.
- Both readers prefer a validated offline chapter before making a source request.
  Downloaded manga can therefore open even when its source is unavailable.
- The persisted queue supports pause, retry, removal, progress, and error messages.
  A paused chapter does not block other queued chapters. Relaunch requeues work that
  was interrupted. A retry restarts the chapter; it does not resume an individual
  partially transferred network response.
- The default is Wi-Fi only. Network changes wake a waiting queue. A 200 MB free-space
  floor prevents starting the next write when storage is low.
- Files live under Application Support/ChapterDownloads, outside the evictable image
  cache, and are excluded from automatic device backup. Identity uses hashes of source,
  entry, and chapter. Each folder contains page files or chapter.html and a manifest.
  The manifest is published only after every file has been written.
- Removing a download removes its durable files and queue row, retaining the chapter.
- User batches request iOS 26 continued processing. Scheduled processing can pick up
  pending work later. When iOS expires a task, unfinished work stays in the queue.
  Network I/O currently uses the source/HTTP stack under those assertions; there is
  no separate background URLSession transfer reconciliation or CBZ exporter.

## Background library updates

**More → Library updates** controls automatic checks, requested interval, Wi-Fi,
notifications, optional downloads of new chapters, unread-only and completed-title
restrictions, and each title's update strategy. Notification permission is requested
when the notification setting is enabled.

Automatic checks honor Always / Only once / Never. Manual pull-to-refresh overrides
those restrictions. Local imported books are skipped. iOS selects actual execution
windows; an interval is an earliest request, not a guarantee. Low Power Mode, disabled
Background App Refresh, network availability, or force-quitting can delay work.

App refresh and processing identifiers are registered at launch and declared in
Info.plist. Expiration cancels work, avoids applying cancelled update results, and
preserves pending downloads.

## Encrypted .lnbk backup

**More → Backup & restore** exports an authenticated AES-256-GCM backup. Copy and save
its recovery key separately. The key is random, kept in this device's Keychain, and
never stored inside the backup. There is no weak password-derived key. Restoring on
another device requires the original recovery key.

The payload includes:

- Novel and manga metadata, custom metadata, categories, library membership/order.
- Chapters, bookmarks, reading position, read state, history, existing tracker metadata.
- Reader/library/manga/download/scanlator preferences, profile, and imported LocalNovels files.

Downloaded chapter files and audio are excluded. Source packages, login credentials,
session tokens, and cloud synchronization are excluded. Existing extension installation
and migration behavior is unchanged.

The local format is `LNRB | 2 | AES-GCM combined box`, authenticating the five-byte
header. Its payload is versioned JSON. This is a distinct envelope version from the
plan's Argon2/protobuf proposal, so it cannot silently misread that future format.
**More → Backup & restore → Mihon / Tachiyomi (.tachibk)** reads and exports `.tachibk` files compatible with Mihon, Tachiyomi forks, Yokai and Tachimanga (see below). There
is no cloud backup endpoint in this change.

Import authenticates and validates the snapshot before presenting the merge action.
Restore matches entries by source+URL, categories by name, and chapters by URL.
Existing title details win; read/bookmark flags merge with OR; newer progress, history,
and tracker progress win. Offline download flags are not restored without their files.
Existing local files win. Relative file paths and resolved paths are checked before
writing. File and snapshot sizes are bounded (256 MB encrypted payload; local imported
files must fit within a 128 MB export budget).

## Verification

`./scripts/check.sh offline` runs without a Simulator and covers encrypted round
trip, wrong key and tampered ciphertext, unsafe paths, library/category/chapter/history/
tracker restoration, repeat merges preserving newer state, offline manifests and missing
files, and automatic versus manual update policy. Existing schema and page-pipeline
checks cover queue relationships, deletion direction, cache, loader, and reading progress.

**None of this has been exercised on a device as of 2026-10-25.** Device checks are still
required for the download screens, Files export/import and Keychain recovery, airplane-mode
reading for both kinds, queue cancellation and recovery after relaunch, task expiration,
continued-processing progress, and scheduled refresh and notifications. The reader and library
paths these features feed into are device-verified, so a failure here belongs to the feature
rather than the reader.

## Importing a .tachibk backup

`Services/Backup/MihonBackup.swift` reads the gzipped protobuf those apps write with a small
hand-written wire reader — the field numbers in that file are the spec — so there is no protobuf
dependency.
It restores titles, categories, chapters (read, bookmark, last page, scanlator, upload and fetch dates),
history and trackers. App preferences, extension repos and source preferences are ignored.

- **Merge, not replace.** Titles match on source and URL and keep the details already stored. Chapters
  match on URL; read and bookmark are OR-ed and the further page wins. History keeps the later read,
  trackers keep the higher chapter. Importing the same file twice changes nothing.
- **Sources.** A backup names a source by its Mihon id. `BundledExtensions.mihonSourceIDs` maps the ids of
  built-in extensions (MangaFire, AllManga) to them. A title from any other source is still imported, under
  `mihon:<id>`, and the confirmation says which sources are missing; it opens once a matching extension
  is installed.
- **Favorites.** Mihon omits `favorite` when it is true, so a missing flag means "in library".
- **Novels.** The plan reserves fields 5000+ for LNReader's own novel data. Nothing writes them yet, so
  nothing reads them.

`./scripts/check.sh mihon-backup` builds a backup in the test, gzips it and restores it into an in-memory
store; set `TACHIBK_SAMPLE=/path/to/file.tachibk` to run a real export too.
