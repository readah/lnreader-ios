#!/bin/sh
# release.sh — cut a new LNReader release for the AltStore source.
#
#   ./scripts/release.sh patch              # 2.0.3 -> 2.0.4
#   ./scripts/release.sh minor              # 2.0.3 -> 2.1.0
#   ./scripts/release.sh major              # 2.0.3 -> 3.0.0
#   ./scripts/release.sh patch -m "Fixes the reader jumping on chapter change"
#   ./scripts/release.sh patch --dry-run    # show what would change, touch nothing
#   ./scripts/release.sh patch --no-push    # commit locally, do not push
#
# What it does:
#   1. Bumps CFBundleShortVersionString (by the unit you give) and CFBundleVersion (+1)
#      in Info.plist.
#   2. Commits as "release: v<version>" (the -m text becomes the commit body) and pushes. That
#      prefix is the trigger for .github/workflows/release.yml, which builds the IPA on a macOS
#      runner, publishes a GitHub Release with it and only then adds the entry (with the real
#      size) to altstore/apps.json, the AltStore/SideStore source. A failed build never
#      advertises a version.
#
# Needs: a clean working tree on main that is level with origin/main.
set -eu
cd "$(dirname "$0")/.."

UNIT=""
NOTES=""
DRY=0
PUSH=1
while [ $# -gt 0 ]; do
  case "$1" in
    major|minor|patch) UNIT=$1 ;;
    -m|--message) shift; NOTES=${1:-} ;;
    --dry-run) DRY=1 ;;
    --no-push) PUSH=0 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "release: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$UNIT" ] || { echo "release: say major, minor or patch (try --help)" >&2; exit 2; }

PLIST=Info.plist
REPO=$(git remote get-url origin | sed -E 's#^(git@github.com:|https://github.com/)##; s#\.git$##')

# --- Preconditions -----------------------------------------------------------
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || { echo "release: not on main" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "release: working tree is not clean" >&2; exit 1; }
git fetch -q origin main
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  echo "release: main is not level with origin/main (pull or push first)" >&2
  exit 1
fi

# --- Next version ------------------------------------------------------------
CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
MAJOR=${CURRENT%%.*}; REST=${CURRENT#*.}; MINOR=${REST%%.*}; PATCHV=${REST#*.}
case "$UNIT" in
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCHV=0 ;;
  minor) MINOR=$((MINOR + 1)); PATCHV=0 ;;
  patch) PATCHV=$((PATCHV + 1)) ;;
esac
VERSION="$MAJOR.$MINOR.$PATCHV"
NEW_BUILD=$((BUILD + 1))
TAG="v$VERSION"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1; then
  echo "release: tag $TAG already exists" >&2
  exit 1
fi

echo "==> $CURRENT ($BUILD) -> $VERSION ($NEW_BUILD)"
[ "$DRY" -eq 0 ] || { echo "    dry run: nothing written"; exit 0; }

# --- Write -------------------------------------------------------------------
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"

git add "$PLIST"
if [ -n "$NOTES" ]; then
  git commit -q -m "release: $TAG" -m "$NOTES"
else
  git commit -q -m "release: $TAG"
fi
echo "==> Committed release: $TAG"

if [ "$PUSH" -eq 1 ]; then
  git push origin main
  echo "==> Pushed. Watch the build: https://github.com/$REPO/actions/workflows/release.yml"
else
  echo "==> Not pushed. 'git push origin main' starts the release workflow."
fi
