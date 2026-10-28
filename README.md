# Jot App

A standalone, native macOS menu-bar notepad. Press a shortcut, type, and the note is saved as a plain Markdown file on your Mac. Formatting appears as you write, and **Share** sends a note to Apple Notes, Stickies, a file or the system Share sheet. Jot makes no network connections.

Jot is an independent project. Its source, tests and packaging tools live entirely in this repository. No checkout or installation of another project is required. It began inside the GlassKit suite of menu-bar apps and moved here, unchanged in behavior, as version 3.0.

## Install

[Download Jot.dmg](https://github.com/p3terparker/jot-app/releases/latest/download/Jot.dmg) from the [latest release](https://github.com/p3terparker/jot-app/releases/latest). Open the disk image, drag Jot to Applications, eject the image, and open Jot. Click the note icon in the menu bar or press **Option–Command–J**; the first note explains the rest.

The downloadable preview and local builds are ad-hoc signed and **not notarized**. macOS may require System Settings → Privacy & Security → Open Anyway. Making the source public does not change Gatekeeper requirements. See the [first-run notes](FIRST_RUN.txt).

Requires macOS 13+. Universal builds contain Apple Silicon and Intel slices; actual Intel and macOS 13 acceptance remains pending.

## What it does

- **Type first.** The shortcut opens a small pad with a fresh note. Notes autosave as `.md` files, with optional YAML frontmatter (pin, order, reminder). Frontmatter Jot doesn't own, such as Obsidian tags, is kept untouched.
- **Live Markdown.** Headings, bold, italic, strikethrough, links, `code`, checklists, quotes and tables look formatted as you type, and markers hide except at the caret. A formatting bar with Apple Notes shortcuts toggles each style. ⌘/ shows the plain text.
- **A notes list** that is a drawer over the text on a small pad and docks beside it on a wide one: search (⌥⌘F), pins, multi-select, drag to reorder, Recently Deleted (30 days) and Undo.
- **Share anywhere.** Apple Notes, Stickies, Save As (txt, md, rtf, html, paginated PDF), the system Share sheet, or Copy.
- **Reminders**, native note windows, a welcome note on first run, and a compact Settings window.
- **Private by construction.** No network access (`test.sh` fails if a networking API appears), no account, notes are ordinary files.

The complete list and changelog are in [docs/FEATURES.md](docs/FEATURES.md).

## Build

Build prerequisites: macOS, Xcode Command Line Tools and Python 3.9+ (the system `python3` is enough). No third-party Swift packages, no Xcode project and no network access are required. Python is needed by contributors, not app recipients.

```sh
./check.sh                    # metadata, tooling tests and the Foundation-only regression suite
./build.sh                    # current architecture → build/native/Jot.app
./build.sh --universal        # Apple Silicon + Intel → build/universal/Jot.app
./package.sh                  # tests, universal build, dist/Jot.dmg
./release.sh --dry-run --identity "Developer ID Application: Your Name (TEAMID)" --notary-profile PROFILE
```

Builds never install or launch Jot. An explicit `./build.sh --install` replaces `~/Applications/Jot.app` after you quit it; otherwise use the DMG. Generated artifacts stay in the ignored `build/` and `dist/` directories. The version and bundle metadata live in `Info.plist`; frameworks and entitlements are configured once in `scripts/app.json`.

macOS ties the Accessibility grant Stickies needs (and Automation grants) to the app's code signature, and an ad-hoc signature changes with every build. To keep grants across rebuilds, sign locally with a stable code-signing certificate from your keychain: `./build.sh --identity "Certificate Name"` or set `JOT_SIGNING_IDENTITY`.

Public distribution needs a Developer ID certificate and notarization, which this repository scripts but cannot supply. See [docs/RELEASE.md](docs/RELEASE.md).

## Test

```sh
./check.sh                    # tooling tests + the Swift regression checks (storage, Markdown, edit fuzzing, migrations)
./build.sh && ./preview.sh    # isolated AppKit walkthrough of the built app; requires a macOS GUI session
```

Tests use temporary notes, private preference domains, a private pasteboard and stubbed notification, Apple Notes and Stickies traffic. They never read or change your notes or settings, and the walkthrough writes screenshots to a temporary folder. See [verification](docs/AUDIT.md) for results and the manual checks that remain.

## Project layout

- `Sources/` — the app: editor, storage, sidebar, sharing, settings, and the isolated preview harness
- `Tests/` — Foundation-only logic checks (run by `test.sh`)
- `scripts/` — standalone build, check, packaging and release tooling
- `Info.plist`, `Jot.entitlements`, `AppIcon.icns`, `FIRST_RUN.txt` — bundle metadata, hardened-runtime entitlements, icon, the DMG's Read Me
- [MAP.md](MAP.md) — implementation map
- [Features and changelog](docs/FEATURES.md), [verification](docs/AUDIT.md), [release process](docs/RELEASE.md), [gotchas](GOTCHAS.md)
- [Contributing](CONTRIBUTING.md)

## Compatibility and license

The app keeps the bundle identifier `com.jacob.jot`, its preference keys and its notes folder (`~/Library/Application Support/Jot`) so existing installs keep their notes and settings. New installs use **Option–Command–J**; an install that never chose a shortcut keeps **Control–J**. Those compatibility identifiers do not depend on any other app or repository.

Jot is licensed under the [MIT License](LICENSE). It contains no third-party code.
