#!/bin/sh
# install-release.sh — build a Release LNReader and install it on a paired
# physical iPhone/iPad. Asks which one when more than one is paired.
#
#   ./scripts/install-release.sh            # build, install, launch
#   ./scripts/install-release.sh --no-launch
#   ./scripts/install-release.sh fast       # Debug build (alias: debug): incremental, far quicker than Release
#   ./scripts/install-release.sh --device iPhone   # that device, no question
#
# Works over USB or Wi-Fi (the phone must be on the same network).
# Signs with the project's automatic signing settings, so the
# device must be unlocked, trusted, and have Developer Mode on. Run this from a
# normal terminal; inside an agent sandbox xcodebuild cannot resolve packages.
set -eu
cd "$(dirname "$0")/.."

LAUNCH=1
CONFIG=Release
WANTED=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-launch) LAUNCH=0 ;;
    debug|fast|--debug|--fast) CONFIG=Debug ;;
    --device)
      [ "$#" -ge 2 ] || { echo "install-release: --device needs a name, UDID or device id" >&2; exit 2; }
      WANTED=$2
      shift
      ;;
    *) echo "install-release: unknown option '$1'" >&2; exit 2 ;;
  esac
  shift
done

DERIVED=.build/device
EXTRA=""
# ENABLE_DEBUG_DYLIB=NO: the default Debug build is a stub launcher plus a dylib.
[ "$CONFIG" = Debug ] && EXTRA="ENABLE_DEBUG_DYLIB=NO"

if [ -n "$WANTED" ]; then
  DEVICE=$(./scripts/lib/pick-device.py "$WANTED")
else
  DEVICE=$(./scripts/lib/pick-device.py)
fi

if [ -z "$DEVICE" ]; then
  echo "install-release: no paired physical device." >&2
  echo "Pair it (USB once, then Connect via network in Xcode > Devices), then check:  xcrun devicectl list devices" >&2
  exit 1
fi
DEVICE_ID=$(printf '%s' "$DEVICE" | cut -f1)
DEVICE_NAME=$(printf '%s' "$DEVICE" | cut -f3)

echo "install-release: building $CONFIG for $DEVICE_NAME"
xcodebuild \
  -project LNReader.xcodeproj \
  -scheme LNReader \
  -configuration "$CONFIG" \
  -destination "id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  build $EXTRA

APP="$DERIVED/Build/Products/$CONFIG-iphoneos/LNReader.app"
[ -d "$APP" ] || { echo "install-release: build did not produce $APP" >&2; exit 1; }
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist")

echo "install-release: installing $BUNDLE_ID on $DEVICE_NAME"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"

if [ "$LAUNCH" -eq 1 ]; then
  xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID"
fi
echo "install-release: done"
