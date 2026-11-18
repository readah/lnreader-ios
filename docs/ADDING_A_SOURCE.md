# Adding a source

A source is one Swift file in `Services/Sources/Native/`. There is no install step and no JS: the
site's logic is compiled into the app, so fixing a site means editing the file and reinstalling.

## 1. Write the source

Copy a small one as a starting point: `FourKHDSource.swift` (manga, JSON API) or
`NovelFireSource.swift` (novel, HTML). Conform to `MangaSource` or `NovelSource`
(`Services/Sources/CatalogSource.swift`).

- **Identity:** `key = SourceKey.makeBuiltin(id: "<id>")`, `kind`, `name`, `lang`. The key is
  stored on every library entry, so never change it once shipped.
- **Network:** build a `SiteClient(sourceKey:baseURL:)`. It goes through the shared `HTTPClient`,
  so rate limits, cookies and Cloudflare handling are not per source. Parse with SwiftSoup or
  `Codable`. Mind the `Element` helpers in `NativeSupport.swift`.
- **Website:** `homepage` is the site's root, which Browse's browser button opens in the app's
  web view; a login or a solved challenge earned there is exported to the scraper's cookies.
  One line, next to the client: `var homepage: URL? { URL(string: site.baseURL) }`.
- **Browsing:** `popular`, `latest` (set `supportsLatest`), `search`, `filters()`. Filters are
  definitions (`SourceFilter`); the user's choices arrive as `FilterState`.
- **Reading:** manga returns `pages(_:)` and, if the CDN needs headers, a `URLRequest` from
  `imageRequest(_:)` (`SourcePage.headers` is the easy route). Novels return HTML from
  `chapterHTML(_:)`.
- **Urls are persisted.** Entry and chapter `url` values are stored in the library, in downloads
  and in backups. Keep them in the shape upstream uses (for a port, exactly what the Mihon
  extension stores), or old data stops resolving.
- Order chapters however the site does; the app orders by chapter number. Return `-1` when the
  site gives no number and `ChapterRecognition` fills it.
- `isAdult = true` shows the red 18+ chip in Browse.
- Keep the type `Sendable`: a final class with `let` properties, or a struct. Shared mutable
  state (a throttle, a cache) goes in a private actor.

## 2. Register it

1. Add `YourSource()` to `NativeSources.all()` in `NativeSupport.swift`.
2. **Manga ported from Mihon/Tachiyomi:** add its id to `NativeSourceIDs.mihon` so `.tachibk`
   backups land on it. The id is `MihonSourceID.make(name:lang:versionId:)`: the lowercased
   name, the language and upstream's `versionId` (default 1; some sources pin an id by hand,
   as AllManga does). Check it against a real backup if you have one.
3. **Add the file to the Xcode target by hand.** The project lists files individually and a
   missing file fails silently. Validate with `plutil -lint LNReader.xcodeproj/project.pbxproj`.
4. **Icon (optional):** add `Assets.xcassets/<Name>Icon.imageset` with a PNG and set
   `iconAsset = "<Name>Icon"`.

## 3. Check it

```sh
SOURCES=<id> ./scripts/try-native.sh     # live site: popular, latest, search, details,
                                         # chapters, then pages + one image (manga) or
                                         # chapter HTML (novel)
./scripts/typecheck.sh
./scripts/check.sh all
```

`try-native.sh` compiles only the app files listed in the script plus `Services/Sources/Native/`,
so a source that needs another app file takes it via `EXTRA="path/One.swift ..."`. It needs the
network and is not part of `check.sh all`. A PASS there is not "verified": open the source on an
iPhone, read a chapter and download one before calling it working.

Sites behind Cloudflare time out in the headless runner, which has no WebKit solver. That is
a runner limit; confirm those in the app.

## 4. Record the upstream baseline

`.github/upstream-sources.json` says which upstream commit each port was written against.
`.github/workflows/source-drift.yml` compares it with upstream once a day and opens one issue
per source that has moved, so a port cannot rot unnoticed.

```sh
gh api "repos/<owner>/<repo>/commits?path=<path>&sha=<branch>&per_page=1" --jq '.[0] | .sha, .commit.committer.date'
```

The sha must be a commit that touched `path`, which is what that query returns — not the
repository HEAD from `git rev-parse HEAD`. A repo-wide sha never equals the path's last commit,
so the check would report drift immediately and then call the baseline vanished.

`--bump <id>` does the same lookup and writes both fields, so adding an entry by hand is only
needed the first time:

```sh
python3 .github/scripts/check_source_drift.py --bump weebcentral
```

Add to `sources`:

```json
{
  "id": "weebcentral",
  "name": "Weeb Central",
  "repo": "keiyoushi/extensions-source",
  "branch": "main",
  "path": "src/en/weebcentral",
  "ported_sha": "<40-char sha from above>",
  "ported_at": "2026-10-30",
  "files": ["Services/Sources/Native/WeebCentralSource.swift"]
}
```

`id` is the marker in the issue body and the name you pass to `--bump`; `files` is what the
issue tells you to edit. Manga ports point at `keiyoushi/extensions-source` (`src/<lang>/<name>`
for one site, `lib-multisrc/<name>` for a family), novel ports at
`lnreader/lnreader-plugins` (`plugins/multisrc/<template>`). Every port has an entry; a source
written from scratch would not.

When you have ported a change, record the new commit — the open issue closes itself on the
next run:

```sh
python3 .github/scripts/check_source_drift.py --bump weebcentral
python3 .github/scripts/check_source_drift.py --bump weebcentral <sha>   # pin to a commit
```

Either form stores the newest commit touching the source's `path` at or before that point, so a
short sha from `git log` or the repo HEAD is resolved rather than written down as given.

`--dry-run` reports what would happen without touching issues; `--only <id>` checks one entry.
Locally a check needs `GH_TOKEN` (any token with `issues: write`) and `GITHUB_REPOSITORY`;
`--bump` needs neither and runs unauthenticated.
