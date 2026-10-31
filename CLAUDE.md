# Jot App

Quick-capture Markdown notepad that lives in the menu bar. **Current: v3.1 (31)** — a standalone repository (extracted from the GlassKit suite); see `docs/AUDIT.md` ▸ Jot 3.0 part log and `MAP.md`. Local builds are ad-hoc signed; Developer ID signing and notarization are still to do (`./release.sh`, `docs/RELEASE.md`).
Binary `Jot` · bundle `com.jacob.jot` · global hotkey (new installs ⌥⌘J, existing installs keep ⌃J — `Migrations.swift` / `FirstRun.swift`) ·
frameworks: Cocoa, Carbon, ServiceManagement, **ApplicationServices** (Accessibility check for the Stickies keystroke path), **UserNotifications** (reminders).

**What it is now:** one `.md` file per note (optional YAML frontmatter: `pin`, `order`, `folder`, `reminder`, plus legacy keys that are kept but no longer shown); debounced autosave;
live markdown styling (real bold/italic via concealed zero-width markers, `#` headings, `` `code` ``, interactive checkboxes, tables); formatting bar; notes side panel (flat `NSTableView`; **folders** are header rows — `Folders.swift`;
⌘/⇧-click multi-select, drag-reorder, drag-into-folder, pins, ⌃⌘S / ⌥⌘↑↓ navigation); reminders (UserNotifications); undocked editor windows; Recently Deleted (30 days).
**Send a note to:** Apple Notes, Stickies, Save-as (txt/md/rtf/html/pdf — rich text is an *export* format only), system Share, Copy. **No network access** (`test.sh` enforces it).
**Gone in 3.0:** Notion, Drafts sync, and the per-note Rich Text editing mode (legacy RTF notes are converted to Markdown at launch after a byte-identical backup — `LegacyRTF.swift`).

**Gotchas (see GOTCHAS.md):** a table row is not a note index (folder headers are rows) — use `noteURL(atRow:)` / `rowIndex(of:)`, never `notes[row]`. Stickies' system Service has not worked from Jot, so it uses **keystrokes**, which need **Accessibility for Jot** + stable signing to persist. Don't gate on `AXIsProcessTrusted()` (false under ad-hoc signing).
A main-menu key equivalent beats the text view's own keys (⌘⌫ must be handled in `JotTextView.performKeyEquivalent`). Frontmatter is **patched, never regenerated** (Obsidian-style keys survive saves). Any UserNotifications access must go through `notificationCenter()`.

**Build / verify (never against your real notes):**
- `./build.sh` — build only → `build/native/Jot.app` (add `--install` only after quitting the app, with the owner's OK). `--universal` for both architectures.
- `./check.sh` — tooling tests + `test.sh` (Foundation-only checks: storage, frontmatter, ordering, migrations, fixtures, RTF migration, edit fuzzing, network-API guard).
- `./preview.sh` — runs the built bundle's isolated walkthrough (private defaults, temp notes, no hotkey/notifications/senders; PNGs + `walkthrough.txt`; non-zero exit on failure). Add an `expect` there for any new shortcut, window rule or storage behaviour.
- `./package.sh` — universal build + `dist/Jot.dmg` (local preview, not notarized). `./release.sh --dry-run …` prints the Developer ID sequence.

**Records:** feature truth = `docs/FEATURES.md`; per-function code map = `MAP.md`; verification = `docs/AUDIT.md`; release process = `docs/RELEASE.md`; gotchas = `GOTCHAS.md`. Behavior changed → update MAP + FEATURES + version + AUDIT; non-obvious bug solved → GOTCHAS. Keep replies lean and action-oriented.
