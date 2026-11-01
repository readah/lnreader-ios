#!/bin/sh
# Headless benchmark for the paths the library and chapter list hit per frame.
#
# Measures the data work behind the UI at library scale, so a change to the
# library grid, the chapter list, or the counts they read is a number here
# instead of a feeling on a phone. See docs/PERFORMANCE.md for the device side.
#
# Runs on macOS. No simulator, no device, no network.
set -eu
cd "$(dirname "$0")/.."
binary=$(mktemp /tmp/lnreader-perf.XXXXXX)
trap 'rm -f "$binary"' EXIT

xcrun swiftc -O -parse-as-library -swift-version 5 -disable-sandbox \
  Models/Schema/ContentKind.swift \
  Models/Schema/EntryStatus.swift \
  Models/Schema/UpdateStrategy.swift \
  Models/Schema/DownloadState.swift \
  Models/Schema/SchemaV1.swift \
  Models/Schema/SchemaV2.swift \
  Models/Schema/SchemaMigrationPlan.swift \
  Models/UserProfile.swift \
  Services/Sources/SourceKey.swift \
  Features/Entry/ScanlatorRules.swift \
  tests/PerfHotPaths.swift \
  -o "$binary"

"$binary"
