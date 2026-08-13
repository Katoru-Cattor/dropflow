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
# The SHA-256 in the release notes is for the human installing the update: DropFlow is an
# update *notifier*, it hands the .dmg URL to the browser and never downloads, verifies or
# replaces itself. Nothing in the app parses this hash, so keep the line readable.
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

PLIST_BACKUP="$INFO_PLIST.bak"
STAGE=""
PUBLISHED=0
DRAFTED=0

# The version bump is written to the tracked plist BEFORE the build, so any exit before the
# release is actually published must undo it — otherwise the guard above refuses the
# identical re-run that fixing the build failure calls for. `git checkout` is wrong here:
# it would also throw away legitimate uncommitted plist edits.
cleanup() {
    # `if`, not `&&`: a failing test as a bare list would trip `set -e` inside the trap and
    # skip the plist restore below.
    if [[ -n "$STAGE" ]]; then rm -rf "$STAGE"; fi
    # An upload or notes-edit failure between the draft and the un-draft would otherwise leave a
    # previously-public release hidden. /releases/latest skips drafts, so every installed copy would
    # silently see an OLDER version — or none at all — until a human noticed.
    if (( DRAFTED )) && (( ! PUBLISHED )); then
        echo "!! Re-publishing $TAG as non-draft after a failed asset swap."
        gh release edit "$TAG" --repo "$REPO" --draft=false || \
            echo "!! COULD NOT UN-DRAFT $TAG — run: gh release edit $TAG --repo $REPO --draft=false"
    fi
    if [[ -f "$PLIST_BACKUP" ]]; then
        if (( PUBLISHED )); then
            rm -f "$PLIST_BACKUP"
        else
            mv -f "$PLIST_BACKUP" "$INFO_PLIST"
            echo "!! Version bump rolled back — $INFO_PLIST is unchanged, re-run $0 $VERSION when fixed."
        fi
    fi
}
trap cleanup EXIT

echo "==> Bumping version $CURRENT -> $VERSION"
cp "$INFO_PLIST" "$PLIST_BACKUP"
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

**Install**: open the .dmg and drag $APP_NAME.app to /Applications.

**First launch.** $APP_NAME is ad-hoc signed, not notarized, so macOS blocks it once. The old
right-click → Open bypass no longer works on current macOS. Instead:

1. Open $APP_NAME normally and let the block appear, then dismiss it.
2. Go to **System Settings → Privacy & Security**, scroll to the message about $APP_NAME, and click **Open Anyway**.
3. Confirm with Touch ID or your password, then open $APP_NAME again. It launches from then on.

**Updating.** Menu bar → **Check for Updates…** only tells you a release exists and opens this .dmg
in your browser — it never installs anything. Quit the running copy, then drag the new one to
/Applications. Ad-hoc signing also means macOS sees each build as a different app, so re-grant
Accessibility (shake activation) and the Downloads-folder prompt (ZIP) after updating.

**Upgrading from 0.1.0 or 0.2.0:** turn **Launch at Login off before** you replace the app. The
bundle identifier changed in this release, so the old login-item registration can only be removed by
the old binary — replace it first and macOS keeps a stale entry you cannot clear from DropFlow.
Re-enable Launch at Login once the new build is running.

---
**Verify download integrity** (optional — $APP_NAME does not check this for you):
\`\`\`
shasum -a 256 $APP_NAME.dmg
\`\`\`
Expected:
\`\`\`
$SHA
\`\`\`
If the hashes do not match, do **not** open the app."

echo "==> Publishing $TAG to $REPO"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "    Tag $TAG exists — replacing asset and notes."
    # Draft the release while swapping the two: /releases/latest excludes drafts, so an
    # update check landing between the upload and the notes edit cannot see the new .dmg
    # paired with the previous release's SHA-256 and report false tampering.
    gh release edit "$TAG" --repo "$REPO" --draft
    DRAFTED=1
    gh release upload "$TAG" "$DMG_PATH" --repo "$REPO" --clobber
    gh release edit "$TAG" --repo "$REPO" --notes "$FULL_NOTES"
    gh release edit "$TAG" --repo "$REPO" --draft=false
    DRAFTED=0
else
    gh release create "$TAG" "$DMG_PATH" \
        --repo "$REPO" \
        --title "$APP_NAME $VERSION" \
        --notes "$FULL_NOTES"
fi
PUBLISHED=1

echo
echo "==> Done."
echo "    Release: https://github.com/$REPO/releases/tag/$TAG"
echo "    Installed copies will point at this .dmg on their next Check for Updates (notify only)."
echo "    Commit the Packaging/Info.plist version bump so the repo matches the release."
