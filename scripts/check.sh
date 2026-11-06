#!/bin/sh
# check.sh — every headless behaviour check, one entry point.
#
#   ./scripts/check.sh                    list the checks
#   ./scripts/check.sh all                every check that needs no arguments
#   ./scripts/check.sh filters            one check
#   ./scripts/check.sh player <folder>    a check that takes arguments
#
# Why the checks are separate programs at all: there is no XCTest or SwiftPM
# test target here (see the header of typecheck.sh), so each check is a
# standalone executable in tests/ compiled against the few app files it
# touches, then run. The file lists live here instead of in fifteen
# near-identical wrappers.
set -eu
cd "$(dirname "$0")/.."

# Compiles with the flags almost every check wants, then runs the result.
# Usage: compile_and_run <label> <source...>
compile_and_run() {
  label=$1
  shift
  binary=$(mktemp "/tmp/lnreader-$label.XXXXXX")
  trap 'rm -f "$binary"' EXIT
  xcrun swiftc -parse-as-library -swift-version 5 -disable-sandbox "$@" -o "$binary"
  "$binary"
}

# Same, for the checks that compile without -swift-version/-disable-sandbox.
# Usage: compile_and_run_plain <label> <source...>
compile_and_run_plain() {
  label=$1
  shift
  binary=$(mktemp "/tmp/lnreader-$label.XXXXXX")
  trap 'rm -f "$binary"' EXIT
  xcrun swiftc -parse-as-library "$@" -o "$binary"
  "$binary"
}

# The checks that take no arguments, in dependency order: the cheap layers
# first, so a break in the foundation shows up before the expensive ones run.
PLAIN_CHECKS="foundation links schema chapter-sync chapter-order page-pipeline scanlators \
reader-settings haptics filters sorts categories badges offline mihon-backup tts-contracts \
sync migration"

usage() {
  cat <<'USAGE'
Usage: ./scripts/check.sh [check|all]

No argument        list the checks
all                run every check that takes no arguments
<check>            run one check

Checks: foundation links schema chapter-sync chapter-order page-pipeline scanlators
        reader-settings haptics filters sorts categories badges offline mihon-backup
        tts-contracts sync migration native-comments player

Checks needing setup, not part of `all`:
  native-comments   needs the SwiftSoup checkout or network access, and a normal
                    terminal: `swift run` compiles its manifest through
                    sandbox-exec, which fails inside an agent sandbox
  player <folder>   needs a downloaded narration package
USAGE
}

run() {
  case "$1" in
    foundation)
      compile_and_run_plain foundation \
        Models/Schema/ContentKind.swift \
        Models/Schema/EntryStatus.swift \
        Services/Sources/SourceModels.swift \
        Services/Sources/SourceFilters.swift \
        Services/Network/HTTPTypes.swift \
        Services/Network/Interceptors.swift \
        Utilities/DateParsing.swift \
        tests/V2FoundationChecks.swift
      ;;
    links)
      compile_and_run links \
        Models/Schema/ContentKind.swift \
        Models/Schema/EntryStatus.swift \
        Services/Sources/SourceModels.swift \
        Services/Network/HTTPTypes.swift \
        Services/Network/Interceptors.swift \
        Services/EntryLink.swift \
        tests/EntryLinkChecks.swift
      ;;
    schema)
      compile_and_run schema \
        Models/Schema/ContentKind.swift \
        Models/Schema/EntryStatus.swift \
        Models/Schema/UpdateStrategy.swift \
        Models/Schema/DownloadState.swift \
        Models/Schema/SchemaV1.swift \
        Models/Schema/SchemaV2.swift \
        Models/Schema/SchemaMigrationPlan.swift \
        Models/UserProfile.swift \
        Services/Sources/SourceKey.swift \
        tests/V2SchemaChecks.swift
      ;;
    chapter-sync)
      compile_and_run chapter-sync \
        Models/Schema/ContentKind.swift \
        Models/Schema/EntryStatus.swift \
        Models/Schema/UpdateStrategy.swift \
        Models/Schema/DownloadState.swift \
        Models/Schema/SchemaV1.swift \
        Models/Schema/SchemaV2.swift \
        Models/Schema/SchemaMigrationPlan.swift \
        Models/UserProfile.swift \
        Services/Sources/SourceKey.swift \
        Services/Sources/SourceModels.swift \
        Services/Sources/ChapterRecognition.swift \
        Services/ChapterOrder.swift \
        Services/Sources/ChapterSourceSync.swift \
        Services/ChapterVisibility.swift \
        Features/Entry/ScanlatorRules.swift \
        tests/V2ChapterSyncChecks.swift
      ;;
    chapter-order)
      compile_and_run chapter-order \
        Models/Schema/ContentKind.swift \
        Models/Schema/EntryStatus.swift \
        Models/Schema/UpdateStrategy.swift \
        Models/Schema/DownloadState.swift \
        Models/Schema/SchemaV1.swift \
        Models/Schema/SchemaV2.swift \
        Models/Schema/SchemaMigrationPlan.swift \
        Models/UserProfile.swift \
        Services/Sources/SourceKey.swift \
        Services/Sources/SourceModels.swift \
        Services/ChapterOrder.swift \
        tests/ChapterOrderChecks.swift
      ;;
    migration)
      compile_and_run migration \
        Models/Schema/ContentKind.swift \
        Models/Schema/EntryStatus.swift \
        Models/Schema/UpdateStrategy.swift \
        Models/Schema/DownloadState.swift \
        Models/Schema/SchemaV1.swift \
        Models/Schema/SchemaV2.swift \
        Models/Schema/SchemaMigrationPlan.swift \
        Models/UserProfile.swift \
        Services/Sources/SourceKey.swift \
        Services/Sources/SourceModels.swift \
        Services/Sources/ChapterRecognition.swift \
        Services/Sources/ChapterSourceSync.swift \
        Services/ChapterOrder.swift \
        Services/ChapterVisibility.swift \
        Features/Entry/ScanlatorRules.swift \
        Services/EntryMigration.swift \
        tests/MigrationChecks.swift
      ;;
    page-pipeline)
      compile_and_run page-pipeline \
        Models/Schema/ContentKind.swift \
        Models/Schema/EntryStatus.swift \
        Services/Sources/SourceModels.swift \
        Services/Network/HTTPTypes.swift \
        Services/Network/Interceptors.swift \
        Services/Network/HTTPClient.swift \
        Services/Images/ChapterCache.swift \
        Services/Images/PageLoader.swift \
        Features/MangaReader/PagePrefetchPlan.swift \
        Features/MangaReader/MangaProgress.swift \
        tests/V2PagePipelineChecks.swift
      ;;
    scanlators)
      compile_and_run scanlators \
        Features/Entry/ScanlatorRules.swift \
        tests/V2ScanlatorChecks.swift
      ;;
    reader-settings)
      compile_and_run reader-settings \
        Features/MangaReader/MangaReadingMode.swift \
        Features/MangaReader/MangaReaderControls.swift \
        Features/MangaReader/MangaReaderSettings.swift \
        tests/V2ReaderSettingsChecks.swift
      ;;
    haptics)
      compile_and_run haptics \
        Services/ScrollHaptics.swift \
        tests/HapticsChecks.swift
      ;;
    filters)
      compile_and_run filters \
        Models/Enums/LibraryFilter.swift \
        tests/LibraryFilterChecks.swift
      ;;
    sorts)
      compile_and_run sorts \
        Models/Enums/SortOrder.swift \
        Models/Enums/LibraryFilter.swift \
        Models/Enums/LibrarySort.swift \
        tests/LibrarySortChecks.swift
      ;;
    categories)
      compile_and_run categories \
        Models/Enums/DisplayMode.swift \
        Models/Enums/LibraryFilter.swift \
        Models/Enums/CategorySettings.swift \
        tests/CategorySettingsChecks.swift
      ;;
    badges)
      compile_and_run badges \
        Models/Enums/LibraryBadges.swift \
        tests/LibraryBadgeChecks.swift
      ;;
    offline)
      compile_and_run offline \
        Models/Schema/ContentKind.swift \
        Models/Schema/EntryStatus.swift \
        Models/Schema/UpdateStrategy.swift \
        Models/Schema/DownloadState.swift \
        Models/Schema/SchemaV1.swift \
        Models/Schema/SchemaV2.swift \
        Models/UserProfile.swift \
        Services/Sources/SourceKey.swift \
        Services/Sources/SourceModels.swift \
        Services/LibraryBackup.swift \
        Services/ChapterOrder.swift \
        Services/ChapterVisibility.swift \
        Features/Entry/ScanlatorRules.swift \
        Services/OfflineChapters.swift \
        tests/OfflineLibraryChecks.swift
      ;;
    mihon-backup)
      compile_and_run mihon-backup \
        Models/Schema/ContentKind.swift \
        Models/Schema/EntryStatus.swift \
        Models/Schema/UpdateStrategy.swift \
        Models/Schema/DownloadState.swift \
        Models/Schema/SchemaV1.swift \
        Models/Schema/SchemaV2.swift \
        Models/Schema/SchemaMigrationPlan.swift \
        Models/UserProfile.swift \
        Services/Sources/SourceKey.swift \
        Services/Sources/Native/NativeSourceIDs.swift \
        Services/Backup/ProtobufReader.swift \
        Services/Backup/ProtobufWriter.swift \
        Services/Backup/MihonBackup.swift \
        Services/Sources/SourceModels.swift \
        Services/ChapterOrder.swift \
        Services/ChapterVisibility.swift \
        Features/Entry/ScanlatorRules.swift \
        Utilities/Gzip.swift \
        tests/MihonBackupChecks.swift
      ;;
    tts-contracts)
      compile_and_run_plain tts-contracts \
        Models/TTSAudio.swift \
        Features/Reader/ReaderTTSJavaScript.swift \
        Features/Reader/ReaderContentBridge.swift \
        Services/TTSChapterSource.swift \
        tests/TTSContractChecks.swift
      ;;
    sync)
      compile_and_run sync \
        Models/Schema/ContentKind.swift \
        Models/Schema/EntryStatus.swift \
        Models/Schema/UpdateStrategy.swift \
        Models/Schema/DownloadState.swift \
        Models/Schema/SchemaV1.swift \
        Models/Schema/SchemaV2.swift \
        Models/Schema/SchemaMigrationPlan.swift \
        Models/UserProfile.swift \
        Services/Sources/SourceKey.swift \
        Services/Sources/SourceModels.swift \
        Utilities/DateParsing.swift \
        Services/SyncApply.swift \
        Services/ChapterOrder.swift \
        Services/ChapterVisibility.swift \
        Features/Entry/ScanlatorRules.swift \
        tests/SyncApplyChecks.swift
      ;;
    player)
      shift
      if [ $# -lt 1 ]; then
        echo "check.sh player: needs a downloaded package folder" >&2
        echo "usage: ./scripts/check.sh player <complete-package-folder> [stream-parts-folder]" >&2
        exit 2
      fi
      binary=$(mktemp /tmp/lnreader-player.XXXXXX)
      trap 'rm -f "$binary"' EXIT
      xcrun swiftc -parse-as-library \
        Models/TTSAudio.swift \
        Services/ReaderTTSManager.swift \
        tests/TTSPlayerChecks.swift \
        -o "$binary"
      "$binary" "$@"
      ;;
    native-comments)
      # SwiftSoup is a package dependency, so this one builds a throwaway
      # SwiftPM package instead of calling swiftc directly.
      check_dir=$(mktemp -d /tmp/lnreader-native-comments.XXXXXX)
      trap 'rm -rf "$check_dir"' EXIT
      mkdir -p "$check_dir/Sources/Checks"
      cp Services/NovelFireCommentsService.swift Services/CommentSite.swift \
        tests/NativeCommentsChecks.swift "$check_dir/Sources/Checks/"
      python3 - "$check_dir/Package.swift" <<'PY'
import json, os, sys
checkout = os.environ.get('SWIFTSOUP_CHECKOUT')
dependency = '.package(path: ' + json.dumps(checkout) + ')' if checkout else '.package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.14.3")'
open(sys.argv[1], 'w').write('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "NativeCommentChecks", platforms: [.macOS(.v14)], dependencies: [''' + dependency + '''], targets: [.executableTarget(name: "Checks", dependencies: [.product(name: "SwiftSoup", package: "SwiftSoup")])])
''')
PY
      swift run --package-path "$check_dir" --scratch-path /tmp/lnreader-native-comment-checks-build Checks
      ;;
    *)
      echo "check.sh: unknown check '$1'" >&2
      echo >&2
      usage >&2
      exit 2
      ;;
  esac
}

case "${1:-}" in
  '')
    usage
    ;;
  all)
    for name in $PLAIN_CHECKS; do
      echo "==> $name"
      run "$name"
    done
    echo "==> all $(( $(echo $PLAIN_CHECKS | wc -w) )) checks passed"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "==> $1"
    run "$@"
    ;;
esac
