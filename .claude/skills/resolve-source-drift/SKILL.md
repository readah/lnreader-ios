---
name: resolve-source-drift
description: Triage and resolve "Source drift" issues. Lists open source-drift issues, pulls the upstream commits and diff for each drifted source, decides whether the Swift port needs to change, ports the change when it does, and bumps the baseline. Use when the user mentions source drift, an upstream source moving, a drift issue, or asks to sync a native source with keiyoushi/lnreader-plugins.
---

# Resolve source drift

A native source in `Services/Sources/Native/` was ported from an upstream source (Mihon
extension in `keiyoushi/extensions-source`, or a plugin in `lnreader/lnreader-plugins`).
`.github/upstream-sources.json` records the upstream commit each port matches (`ported_sha`).
The daily workflow opens one issue per drifted source, labelled `source-drift`, with the marker
`<!-- source-drift:<id> -->` in its body. This skill walks one or more of those issues to done.

Most upstream commits do not need a port. The job is to **decide**, with evidence, and only
change Swift when the diff actually affects behaviour we implement.

## Rules (from AGENTS.md)

- **Do not bump `ported_sha` unless the port really matches upstream.** The bump closes the
  issue. "Reviewed, nothing to port" counts as matching; "I didn't look" does not.
- Never bump to a repo-wide HEAD. Use `check_source_drift.py --bump <id> [sha]`, which resolves
  the newest commit touching the path.
- Built is not verified. After a port, say it compiles/passes headless checks; do not claim it
  works until it has been used on a device. Do not edit docs to claim otherwise.
- Do not run `./scripts/typecheck.sh` after edits (the user builds in Xcode) unless asked.
- Do not commit unless asked.
- A multisrc family is one class (`MasonrySource`, HeanCMS, etc.); a family drift is fixed once
  and applies to every site configured on it.
- Entry and chapter URLs are persisted: keep returning the shape the source always did. If
  upstream changed a URL format, keep old URLs working or tell the user it breaks saved data.

## 1. Fetch open drift issues

```sh
gh issue list --label source-drift --state open --json number,title,url,updatedAt
```

If the user named a source, filter to it. Otherwise list them and work one at a time (ask which
first only if there are several and the user gave no preference).

For each issue read the body; it contains the table (upstream repo/path, ported-from sha,
upstream-now sha, commits behind), the affected `files`, the commit list, and the bump command:

```sh
gh issue view <n> --json body --jq .body
```

The source id is in the marker `<!-- source-drift:<id> -->`. Get its manifest entry:

```sh
python3 -c 'import json,sys;print(json.dumps([s for s in json.load(open(".github/upstream-sources.json"))["sources"] if s["id"]==sys.argv[1]],indent=2))' <id>
```

No open issues? Run `python3 .github/scripts/check_source_drift.py --dry-run` (needs `GH_TOKEN`
and `GITHUB_REPOSITORY=readah/lnreader-ios`) to see drift the workflow has not filed yet.

## 2. Get the upstream commits and diff

Use `repo`, `path`, `ported_sha` (base) and the "Upstream now" sha (head) from the issue.
Prefer the GitHub API; it needs no clone.

Commits touching the path since the baseline (newest first):

```sh
gh api "repos/<repo>/commits?path=<path>&sha=<head>&per_page=100" \
  --jq '.[] | "\(.sha[0:7]) \(.commit.committer.date[0:10]) \(.commit.message|split("\n")[0])"'
```

Stop reading at `ported_sha`. Then the per-file diff, only for the path:

```sh
gh api "repos/<repo>/compare/<base>...<head>" \
  --jq '.files[] | select(.filename|startswith("<path>")) | "=== \(.filename) (\(.status))\n\(.patch)"'
```

Notes:
- `compare` is capped at 300 files and truncates large patches. If `patch` is missing, fetch
  that file at both shas: `gh api repos/<repo>/contents/<file>?ref=<sha> --jq .content | base64 -d`.
- For a single interesting commit: `gh api repos/<repo>/commits/<sha> --jq '.files[]|select(.filename|startswith("<path>"))|.patch'`.
- "Baseline not in the path history" in the issue means upstream rewrote history or `ported_sha`
  was a repo-wide sha. Diff against the nearest commit by date instead and say so.
- Read the matching Swift file(s) listed in `files` before judging the diff.

## 3. Validate: does the port need to change?

Classify each upstream commit touching the path, then give the user a verdict table
(commit, what changed, port impact, action).

**No port needed**
- Version bumps (`extVersionCode`, `build.gradle` only), icons, `AndroidManifest`, README.
- Kotlin/Android-only refactors (DI, `Injekt`, preferences UI, `SharedPreferences` keys) with no
  change to requests, parsing or output.
- Settings or filters the Swift port intentionally does not expose.
- Behaviour already implemented in the Swift file (check it, do not assume).

**Port needed** — anything that changes what the site is asked or how the answer is read:
- `baseUrl`/domain changes, headers, user agent, `Referer`/`Origin`, cookies, rate limiting.
- Request URL/query/body building, API version, pagination, search/filter params, sort options.
- Selectors, JSON field names, regexes, date formats, chapter-number parsing, status mapping.
- Page-image URL derivation, decryption/token logic (MangaFire's token is ported byte for byte,
  keep it that way), image headers.
- New or removed source ids, `versionId` or name/language changes (these change the source id).
- Chapter ordering assumptions (our invariant: `sourceOrder` 0 is oldest, see
  `Services/ChapterOrder.swift`; do not sort inline).

When unsure, test against the live site: `SOURCES=<id> scripts/try-native.sh` (network; not part
of `check.sh all`; Cloudflare sites time out headless, which is a runner limit).

Present the verdict before editing when it is non-obvious or the port is large. If everything is
"no port needed", say so and go to step 5.

## 4. Make the changes

1. Edit only the Swift files in the manifest entry's `files` (plus a shared base class if the
   source is part of a family; then check every site configured on it).
2. Mirror upstream semantics, not Kotlin structure. Keep URLs persisted by existing entries
   valid.
3. A new `.swift` file must be added to `LNReader.xcodeproj` by hand; avoid new files. If one is
   unavoidable follow AGENTS.md (never touch non-Swift references; `plutil -lint` the project).
4. Headless checks that cover the source: `./scripts/check.sh` lists them; run the relevant
   ones (not `typecheck.sh`, per the user's preference). Run `SOURCES=<id> scripts/try-native.sh`
   when network access is available and report PASS/FAIL faithfully.
5. Keep the change small and focused on what the drift required. No unrelated cleanup.

## 5. Record the baseline

Only after the port matches upstream (or the diff was reviewed and needs nothing):

```sh
python3 .github/scripts/check_source_drift.py --bump <id>           # branch head for the path
python3 .github/scripts/check_source_drift.py --bump <id> <sha>     # pin to a commit
```

This edits `.github/upstream-sources.json` (`ported_sha`, `ported_at`). Pin to a specific sha if
you only ported up to some commit and later ones still need work. Show `git diff` of the
manifest. The open issue closes itself on the next workflow run (daily, or
`gh workflow run source-drift.yml -f source=<id>`) once the change is on the default branch;
do not close it by hand or push unless the user asks.

If you ported only part of the drift, do not bump to head. Bump to the last commit you covered
and leave a note in your summary of what remains.

## 6. Report

For each source: issue number, commits reviewed, verdict per commit, files changed, checks run
and their results, the bump you made (or why not), and the standing caveat that the change is
built, not verified on a device. Offer to commit; do not commit unasked.
