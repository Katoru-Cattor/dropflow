# DropFlow

DropFlow is a native macOS temporary drag shelf built with SwiftPM and AppKit.

Status: done for now / personal MVP complete.

## Project Location

```sh
/Users/weihao/Documents/My Tool/FLOW APP/DropFlow
```

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
- Supports global hotkey: `Command-Option-Space`.
- Supports pointer shake activation while actively dragging a file.

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

## Local Data

DropFlow stores local state here:

```sh
~/Library/Application Support/DropFlow
```

It keeps shelf metadata, recent shelf snapshots, and image payloads saved from pasteboard image drops.

## Current Verification

Last checked after moving the project folder:

```sh
swift build
```

Result: passed.

## Notes

- Shake activation only triggers while dragging, so normal cursor movement should not open the shelf.
- The app is a personal clean-room utility inspired by the general temporary drag shelf workflow. It does not use Dropover assets, code, branding, or proprietary internals.
- If the app is copied to `/Applications`, replace that copy after every rebuild.
