# PRD: Native macOS File Shelf MVP

## Summary
Build a clean-room macOS utility inspired by the general “temporary drag shelf” workflow, without reverse engineering or copying Dropover. The app is for personal daily use first: one active floating shelf for collecting files/URLs/text, then dragging or acting on them later.

Target stack: native Swift using AppKit/SwiftUI, SwiftPM-first because this machine has Swift 6.3.1 and macOS SDK 26.4.1 via Command Line Tools, but no active full Xcode install. References: [Dropover public site](https://dropoverapp.com/) and [Mac App Store listing](https://apps.apple.com/us/app/dropover-easier-drag-drop/id1355679052?mt=12).

## Product Requirements
- Provide one active floating shelf window that accepts dragged files, folders, URLs, plain text, and images where macOS pasteboard types allow it.
- Store dropped files as references to originals, not temp copies. Persist file references using bookmark data where possible, with URL/path fallback for personal non-sandboxed use.
- Allow users to drag shelf items back out to Finder or compatible apps.
- Show item rows/cards with icon or thumbnail, filename/title, type, and missing-file state if the original can no longer be resolved.
- Activation methods:
  - Global hotkey opens the shelf near the cursor.
  - Menu bar command opens/toggles the shelf.
  - Pointer shake activation is included in v1 and may request Accessibility permission for reliable global tracking.
  - If permission is denied, hotkey and menu bar remain fully usable.
- Recent history:
  - Keep up to 10 recent shelf snapshots locally.
  - Only one shelf can be active at once.
  - Reopening a recent shelf restores resolvable referenced items and marks unavailable items clearly.
- Built-in file basics:
  - Reveal in Finder.
  - Open item.
  - Copy file path or URL/text value.
  - Remove item.
  - Clear shelf.
  - Create ZIP from selected/all file items.

## Implementation Changes
- Create a native macOS app with:
  - `ShelfWindowController` for a borderless/floating utility window.
  - `ShelfStore` for active shelf state, persistence, and recent history.
  - `DragDropView`/AppKit bridge for robust pasteboard reading and dragging items back out.
  - `StatusBarController` for menu bar actions.
  - `HotkeyController` for global shortcut registration.
  - `ShakeDetector` using global mouse/drag movement monitoring, with Accessibility onboarding and fallback behavior.
- Minimum data model:
  - `ShelfItem`: id, kind, displayName, source URL/bookmark or inline text/URL payload, createdAt, lastResolvedState.
  - `ShelfSnapshot`: id, title, items, createdAt, lastOpenedAt.
  - `ShelfAction`: reveal, open, copyPath, remove, clear, zip.
- Keep all data local. No cloud upload, accounts, analytics, licensing, App Store purchase logic, Shortcuts, watched folders, or custom action scripting in v1.
  - Amended after v1: the only outbound request is the update check, which reads the public release list from `api.github.com` at launch, at most once a day, and sends no data about the user or their files. It notifies only — the `.dmg` opens in the browser and is installed by hand.
- Use original branding/name. Do not use Dropover name, UI assets, icons, text, screenshots, or proprietary behavior beyond general public workflow concepts.

## Test Plan
- Drag files, folders, URLs, text, and images into the shelf from Finder/browser/apps.
- Drag items from the shelf back into Finder and another compatible app.
- Verify hotkey, menu bar toggle, and shake activation.
- Test first-run Accessibility permission flow and denied-permission fallback.
- Quit/reopen and confirm recent history restores up to 10 shelf snapshots.
- Move/delete original files and confirm missing-item UI does not crash.
- Run ZIP action on one file, multiple files, folders, and unavailable items.
- Build with SwiftPM on the current Command Line Tools setup.

## Assumptions
- Personal MVP is the priority over public distribution polish.
- macOS 26 is the primary target for now; broader macOS compatibility can be planned later.
- A full Xcode install/signing flow is optional for a later packaging phase.
- Shake activation is useful enough to justify requesting Accessibility permission.
