#!/usr/bin/env bash
# Publish a new DropFlow release that the in-app updater can find.
#
# Usage:  ./scripts/release.sh 0.2.0 "What changed in this release"
#
# Steps:
#   1. bump CFBundleShortVersionString + CFBundleVersion in Packaging/Info.plist
#   2. build dist/DropFlow.app via scripts/build_app_bundle.sh
#   3. package dist/DropFlow.dmg
#   4. gh release create v<version> with the .dmg attached and its SHA-256 in the notes
#
# The SHA-256 line in the release notes is not decoration: UpdateController.swift parses
# it and refuses to install a .dmg whose hash does not match. Do not hand-edit it out.
#
# Requires: gh CLI authenticated (gh auth login), and the repo to be PUBLIC so the
# unauthenticated GitHub API call in the app can read the release.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${1:-}"
NOTES="${2:-Release $VERSION}"
REPO="Katoru-Cattor/dropflow"
APP_NAME="DropFlow"
INFO_PLIST="Packaging/Info.plist"
DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"

if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version> [notes]"
    echo "Example: $0 0.2.0 'shake detection no longer fires on slow drags'"
    exit 1
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "!! Version must be numeric MAJOR.MINOR.PATCH (the in-app comparison parses integers)."
    exit 1
fi

CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
if [[ "$VERSION" == "$CURRENT" ]]; then
    echo "!! Version $VERSION is already the current version. Bump it, or existing installs"
    echo "!! will not see this release as an update."
    exit 1
fi

echo "==> Bumping version $CURRENT -> $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")
NEW_BUILD=$((BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$INFO_PLIST"
echo "    version=$VERSION  build=$NEW_BUILD"

echo "==> Building app bundle"
./scripts/build_app_bundle.sh release >/dev/null
[[ -d "$APP_PATH" ]] || { echo "!! $APP_PATH missing after build"; exit 1; }

BUILT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
if [[ "$BUILT_VERSION" != "$VERSION" ]]; then
    echo "!! Built bundle reports $BUILT_VERSION, expected $VERSION. Aborting before publish."
    exit 1
fi

echo "==> Packaging $DMG_PATH"
STAGE="$(mktemp -d /tmp/dropflow-dmg-stage.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null

SHA=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
echo "==> SHA256: $SHA"

if ! command -v gh >/dev/null 2>&1; then
    echo "!! gh CLI not installed (brew install gh)."
    echo "!! .dmg is built at: $DMG_PATH"
    echo "!! Upload manually to: https://github.com/$REPO/releases/new"
    exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
    echo "!! gh not authenticated. Run: gh auth login"
    exit 1
fi

VISIBILITY=$(gh repo view "$REPO" --json visibility --jq .visibility 2>/dev/null || echo UNKNOWN)
if [[ "$VISIBILITY" != "PUBLIC" ]]; then
    echo "!! WARNING: $REPO is $VISIBILITY. The in-app update check is unauthenticated,"
    echo "!! so installed copies of DropFlow cannot see releases on a non-public repo."
fi

TAG="v$VERSION"
FULL_NOTES="$NOTES

**Install**: open the .dmg and drag DropFlow.app to /Applications. First launch: right-click → **Open** (ad-hoc signed, not notarized).

Already running DropFlow 0.2.0 or newer? Use the menu bar item → **Check for Updates…** instead; it verifies this hash and installs for you.

---
**Verify download integrity** before opening:
\`\`\`
shasum -a 256 $APP_NAME.dmg
\`\`\`
Expected:
\`\`\`
SHA256: $SHA
\`\`\`
If the hashes do not match, do **not** open the app."

echo "==> Publishing $TAG to $REPO"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "    Tag $TAG exists — replacing asset and notes."
    gh release upload "$TAG" "$DMG_PATH" --repo "$REPO" --clobber
    gh release edit "$TAG" --repo "$REPO" --notes "$FULL_NOTES"
else
    gh release create "$TAG" "$DMG_PATH" \
        --repo "$REPO" \
        --title "$APP_NAME $VERSION" \
        --notes "$FULL_NOTES"
fi

echo
echo "==> Done."
echo "    Release: https://github.com/$REPO/releases/tag/$TAG"
echo "    Installed copies will offer this on next Check for Updates."
echo "    Commit the Packaging/Info.plist version bump so the repo matches the release."
