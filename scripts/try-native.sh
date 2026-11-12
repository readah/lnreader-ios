#!/bin/sh
# Runs native sources against their live sites and prints PASS/FAIL per source.
# Needs network access; not part of the offline check suite.
#
#   scripts/try-native.sh                      every source
#   SOURCES=mangafire,novelfire scripts/try-native.sh
#   QUERY=term                                 change the search term
#   EXTRA="Path/One.swift Path/Two.swift"      app files a source needs beyond the defaults
set -eu
cd "$(dirname "$0")/.."

SWIFTSOUP=$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/LNReader-*/SourcePackages/checkouts/SwiftSoup/Sources 2>/dev/null | head -1)
MODDIR=${MODDIR:-/tmp/lnr-mac}
BIN=$MODDIR/native-live-checks-$$
trap 'rm -f "$BIN"' EXIT

mkdir -p "$MODDIR"
if [ ! -f "$MODDIR/libSwiftSoup.a" ]; then
  xcrun swiftc -emit-library -static -disable-sandbox -module-name SwiftSoup \
    -o "$MODDIR/libSwiftSoup.a" -emit-module-path "$MODDIR/SwiftSoup.swiftmodule" \
    "$SWIFTSOUP"/*.swift
fi

# shellcheck disable=SC2086
xcrun swiftc -parse-as-library -swift-version 5 -disable-sandbox \
  Models/Schema/ContentKind.swift Models/Schema/EntryStatus.swift \
  Services/Sources/SourceKey.swift Services/Sources/SourceModels.swift \
  Services/Sources/SourceFilters.swift Services/Sources/CatalogSource.swift \
  Services/Network/HTTPTypes.swift Services/Network/Interceptors.swift Services/Network/HTTPClient.swift \
  Services/Network/CookieJar.swift \
  Utilities/DateParsing.swift \
  Services/Sources/Native/*.swift ${EXTRA:-} tests/NativeLiveChecks.swift \
  -I "$MODDIR" -L "$MODDIR" -lSwiftSoup -o "$BIN"

"$BIN" | grep -E '^(PASS|FAIL) '
