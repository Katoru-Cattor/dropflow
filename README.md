# DropFlow

DropFlow is a native macOS temporary drag shelf built with SwiftPM and AppKit.

## What It Does

- Lives in the macOS menu bar with an icon-only status item.
- Opens a floating shelf near the cursor.
- Accepts files, folders, URLs, plain text, and pasted images.
- Stores file references locally instead of copying originals into the app.
- Shows Finder-like previews using QuickLook thumbnails.
- Supports two drag-out modes:
  - `Simplify`: compact preview shelf; dragging from the shelf drags all items together.
  - `Advance`: list view; drag individual items, stacks, or selected items.
- Groups multiple files from one drop into a stack.
- Lets you reveal, open, copy, remove, clear, and ZIP shelf items.
- Keeps recent shelf snapshots locally.
- Supports global hotkey: `Command-Shift-Space`.
- Supports pointer shake activation while actively dragging a file.

To change the hotkey without rebuilding:

```sh
defaults write io.github.katoru-cattor.dropflow HotkeyKeyCode -int 49    # virtual key code
defaults write io.github.katoru-cattor.dropflow HotkeyModifiers -int 768 # Carbon cmdKey|shiftKey
```

## Run From Source

```sh
swift run DropFlow
```

## Build App Bundle

```sh
./scripts/build_app_bundle.sh
```

The built app is created at:

```sh
dist/DropFlow.app
```

You can move that app into `/Applications`.

The bundle includes:

- app icon from `Assets/AppIcon.icns`
- `LSUIElement` menu-bar app configuration
- ad-hoc code signing so macOS identifies it as `DropFlow.app`

## First Launch

DropFlow is ad-hoc signed and not notarized, so macOS blocks it the first time. The old
right-click → **Open** bypass no longer works on current macOS:

1. Open DropFlow normally, let the block appear, and dismiss it.
2. Open **System Settings → Privacy & Security**, scroll to the message about DropFlow, and click **Open Anyway**.
3. Confirm with Touch ID or your password, then open DropFlow again. It launches normally from then on.

Because the signature is ad-hoc, macOS treats every new build as a different app for privacy
purposes. After replacing the app you have to re-grant Accessibility (used by shake activation),
and the Downloads-folder prompt reappears the next time you create a ZIP.

## Updates

The menu bar **Check for Updates…** item is a notifier, not an installer. At launch, and at most
once a day, DropFlow asks `api.github.com` for the latest release of this repo and compares versions.
It sends nothing else — no analytics, no accounts, no file data. If a newer release exists, the
`.dmg` opens in your browser and you install it by hand as above. Turn the daily check off with
**Check Automatically** in the same menu.

Because each build is ad-hoc signed, macOS treats it as a different app: re-grant Accessibility
(shake activation) and the Downloads-folder prompt (ZIP) after replacing DropFlow.

If you are upgrading from 0.1.0 or 0.2.0, switch **Launch at Login** off *before* replacing the app.
The bundle identifier changed after 0.2.0, and only the old binary can unregister its own login item —
replace it first and macOS keeps an entry DropFlow can no longer clear.

## Local Data

DropFlow stores local state here:

```sh
~/Library/Application Support/DropFlow
```

It keeps shelf metadata, recent shelf snapshots, and image payloads saved from pasteboard image drops.

Preferences (hotkey override, update timestamps, launch-at-login state) live in the
`io.github.katoru-cattor.dropflow` defaults domain. ZIP archives are written to `~/Downloads`,
which macOS asks permission for the first time.

## Current Verification

Last checked after moving the project folder:

```sh
swift build
```

Result: passed.

## Notes

- Shake activation only triggers while dragging, so normal cursor movement should not open the shelf.
- The app is a personal clean-room utility inspired by the general temporary drag shelf workflow. It does not use Dropover assets, code, branding, or proprietary internals.
- Nothing stops two copies running at once, and both write the same shelf file — the last one to
  save wins. Quit the `/Applications` copy before running a dev build.

## License

MIT — see [LICENSE](LICENSE).
