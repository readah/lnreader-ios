#!/bin/sh
# profile-device.sh — build a Release LNReader, install it on a paired
# iPhone/iPad (USB or Wi-Fi; asks which one when more than one is paired),
# launch it under Instruments, record, and open the trace.
#
#   ./scripts/profile-device.sh                 # build + install + record 30 s
#   ./scripts/profile-device.sh 60              # record 60 s
#   ./scripts/profile-device.sh --no-install    # reuse what is already installed
#
# Records "Animation Hitches" (dropped and late frames, which is what scroll
# jank is) together with Time Profiler (what the main thread was doing during
# them). Release, not Debug: a Debug build's scroll numbers are not the app's.
#
# The app launches when recording starts; reproduce the problem straight away
# (open a chapter, scroll). Keep the phone unlocked. Run this from a normal
# terminal; inside an agent sandbox xcodebuild cannot resolve packages.
#
# The headless benchmark (`profile-hotpaths.sh`) covers data work only.
set -eu
cd "$(dirname "$0")/.."

DURATION=30
INSTALL=1
for argument in "$@"; do
  case "$argument" in
    --no-install) INSTALL=0 ;;
    ''|*[!0-9]*) echo "profile-device: unknown option '$argument'" >&2; exit 2 ;;
    *) DURATION=$argument ;;
  esac
done

DEVICE=$(./scripts/lib/pick-device.py)
if [ -z "$DEVICE" ]; then
  echo "profile-device: no paired physical device." >&2
  echo "Pair it (USB once, then Connect via network in Xcode > Devices), then check:  xcrun devicectl list devices" >&2
  exit 1
fi
DEVICE_ID=$(printf '%s' "$DEVICE" | cut -f1)
UDID=$(printf '%s' "$DEVICE" | cut -f2)
DEVICE_NAME=$(printf '%s' "$DEVICE" | cut -f3)
[ -n "$UDID" ] || { echo "profile-device: $DEVICE_NAME reported no UDID" >&2; exit 1; }

if [ "$INSTALL" -eq 1 ]; then
  # The device is already chosen: asking again could install onto another one,
  # and then the trace would record a phone that is not the one being used.
  ./scripts/install-release.sh --no-launch --device "$DEVICE_ID"
fi

APP=.build/device/Build/Products/Release-iphoneos/LNReader.app
[ -d "$APP" ] || { echo "profile-device: no build at $APP; run without --no-install" >&2; exit 1; }
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist")

# A paired device over Wi-Fi is listed as offline to xctrace until a command
# opens the tunnel; installing does, and so does this.
xcrun devicectl device info details --device "$DEVICE_ID" >/dev/null 2>&1 || true

mkdir -p perf
OUT="perf/scroll-$(date +%Y%m%d-%H%M%S).trace"

echo "profile-device: recording ${DURATION}s of $BUNDLE_ID on $DEVICE_NAME -> $OUT"

# --launch must be last: everything after `--` is the process to start.
xcrun xctrace record \
  --template 'Animation Hitches' \
  --instrument 'Time Profiler' \
  --device "$UDID" \
  --time-limit "${DURATION}s" \
  --no-prompt \
  --output "$OUT" \
  --launch -- "$BUNDLE_ID"

echo ""
echo "profile-device: wrote $OUT"
open "$OUT"
echo ""
echo "In Instruments:"
echo "  1. Hitches track: how many, how long, and whether they line up with page"
echo "     boundaries (the reported once-per-page jitter)."
echo "  2. Select a hitch, then the Time Profiler track at the same moment."
echo "     Call Tree -> 'Hide System Libraries' + 'Invert Call Tree' shows which of"
echo "     our symbols the main thread was in."
echo "  3. 'Commit' vs 'Render' hitches: commit is main-thread work (ours to fix);"
echo "     render is the GPU or Core Animation (image size, offscreen passes)."
