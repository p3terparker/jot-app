# Jot verification

## 2026-10-31 — Jot 3.2 (32): drag the sidebar shut; CI build and updater

`SidebarDivider` now reports the raw drag width and `AppDelegate` closes the docked sidebar (`hideSidebar`) when it falls below `SidebarGeometry.closeDragThreshold` (100 pt) without touching the saved width. New: `.github/workflows/build.yml` (type-check both architectures, `./check.sh`, `./package.sh`, `./preview.sh`, publish the Current build) and `scripts/jot-update.sh` (Mac-side installer; `bash -n` is covered by the existing script syntax check). Like 3.1 these were written without a Swift toolchain; the first CI run is the first compile — record its result here.

## 2026-10-31 — Jot 3.1 (31): sidebar folders

Scope: group notes in the sidebar under folders (`folder:` frontmatter key; `Sources/Folders.swift`, `NoteLibrary.layout` and friends, row-to-note mapping in `main.swift`/`NoteFilter.swift`/`Sidebar.swift`). The notes folder stays flat; no note is moved, renamed or deleted by any folder operation.

**Verification status — read this:** the change was written in a Linux container with no Swift toolchain or macOS, so it was **not compiled and none of the checks below have been run**. Before relying on 3.1 on the Mac, run `./check.sh` (adds the "folders" block to `Tests/main.swift`: frontmatter round-trip and quoting, name cleaning, layout with/without folders and collapsed, drop targets, reordering) and `./preview.sh` (adds walkthrough step 04f: header rows, selection, fold, filing, rename, remove; the ⋯ menu expectation now lists "Move to Folder"), then record the counts here. Manual checks still owed: dragging a note onto a header and between groups with a real mouse, right-click on a header / empty space, VoiceOver on a header, click-to-fold, Undo toasts.

## 2026-10-28 — Jot 3.0 (30): standalone extraction

Jot now has its own repository: root `Sources/` and `Tests/`, a dedicated `scripts/jot_build.py` (build · check · package · release), app-only metadata (`scripts/app.json`, `Info.plist`, `Jot.entitlements`), its own documentation and the MIT license. It was extracted from the GlassKit suite checkout together with the Jot 3.0 work that was still uncommitted there. No sibling source trees, suite build scripts, credentials, notes, preferences or prior Git history are included; this repository's history starts with the extraction. Behavior, the bundle ID (`com.jacob.jot`), preference keys, the notes folder and the shortcut defaults are unchanged.

The only edits to the code in the move: the isolated-preview flags are now `--jot-preview`, `--jot-preview-snapshots` and `--jot-preview-seconds` (they were `--glasskit-preview…`), temporary-folder prefixes lost their `glasskit-` part, and three comments point at `GOTCHAS.md`. Bundle additions: `NSHumanReadableCopyright`, `LSApplicationCategoryType` (productivity) and the license inside the app (`Contents/Resources/Jot-LICENSE.txt`). The license is MIT, matching the Watch App repository (the owner asked for a license, not a specific one, so confirm it before publishing); Jot contains no third-party code.

### Verification (run from this repository)

- `./check.sh`: 26 tooling tests (replacement safety, metadata, signing command builders, release step order, command-line refusals, a repository-hygiene scan for developer paths and credential files) and **97,623** Swift regression checks pass — the same count as in the suite checkout.
- `./build.sh` compiles with no warnings. `./preview.sh` reports **247 ok** and `PREVIEW WALKTHROUGH OK` on the native build, on the x86_64 slice of the universal build under Rosetta (not real Intel hardware), and on an ad-hoc **hardened-runtime** build with `Jot.entitlements` (`flags=0x10002(adhoc,runtime)`).
- `./build.sh --universal`, `./check.sh --built --universal` and `./package.sh` pass, including under a macOS sandbox policy that denies reads from the original suite checkout, from the newer GlassKit project folder and from the Watch checkout (a control read of each failed with a permission error, confirming the policy was active). The built binary contains no developer paths.
- `dist/Jot.dmg` passes `hdiutil verify`; mounted read-only it holds `Jot.app` (universal, `codesign --verify --deep --strict` passes, version 3.0 (30), `com.jacob.jot`), an `Applications` link and a `Read Me.txt` identical to `FIRST_RUN.txt`.
- `./release.sh --dry-run` prints the eight notarization steps without running any; without credentials it stops before building.
- A fresh `git clone --no-local` into a path containing spaces, with no build output, passed `./check.sh` (26 tooling tests and 97,623 Swift checks), built, and ran the 247-check walkthrough with a clean working tree afterwards. The repository has no object alternates, tracked symlinks or tracked generated files; its Git history starts with the extraction.
- Installer: Jot 3.0 (30), 1,863,918 bytes, SHA-256 `9dffc7769af023e406294214f7f56b2e5977244fa220bcb258cdeeb756aca345`. It is a local preview (ad-hoc, not notarized); Gatekeeper rejects it as expected until the release process in `RELEASE.md` is run with a Developer ID.

### Remaining acceptance boundaries

- Local builds are ad-hoc signed and not notarized (no Developer ID certificate or notarytool profile here); `./release.sh` is ready for them. Open-source publication does not remove Gatekeeper approval requirements.
- Real Intel hardware, macOS 13–15, VoiceOver speech, multi-display and Spaces behavior, real Apple Notes and Stickies delivery (including other languages) and the Login Items approval flow are manual gaps (see the 3.0 log below).
- The installed copy of Jot on the author's Mac is an older 1.0 build; this extraction did not replace or quit it.

## 2026-10-27 — Jot 3.0 (30): polish toward a signed release

Scope: the whole app, part by part (plan: header, toolbar, sidebar, editor, windows, sending, first run, release tooling). No production data, preference, reminder, Apple Notes note or sticky was touched; nothing was installed or launched outside the isolated preview, and the running Jot was never quit. Developer ID signing and notarization are **not done** (no credentials here); `release.sh` is ready for them.

### Method and evidence
- **Isolated preview harness** (`Sources/Preview.swift`, `preview.sh`): private defaults suite, temporary notes folder filled from `Fixtures.swift`, private pasteboard, UserNotifications/AppleScript/URL-open stubbed with call counters, windows parked off-screen, PNG snapshots, `expect` (hard) vs `probe` (observation), non-zero exit on any failure. It launches as a **new install** (no seeded prefs).
- Last run: build 0 warnings · `./check.sh` (tooling tests; `test.sh` 97,623 checks incl. a seeded edit fuzz, a sidebar-geometry sweep, a list-diff fuzz, HTML/search/relative-time/welcome goldens, a network-API grep guard) · walkthrough **247 expects OK**, also against a copy signed with the **hardened runtime + entitlements** (ad-hoc) and against the **x86_64 slice of the universal build under Rosetta** (same result; this is not real Intel hardware). `build.sh --universal`, `check.sh --built --universal` and `package.sh` pass; `dist/Jot.dmg` passes `hdiutil verify`.
- Performance (200 KB note): open 196 → ~135 ms (one styling pass, was 2–3), one keystroke 62 → ~9 ms (non-contiguous layout above 50 KB), 50 KB single line 1,336 → ~60 ms.

### Part log (finding → decision → evidence)
- **Quick wins:** Esc/⌘W hide the pad (find bar first, then a sidebar drawer); ⌘⌫ deletes to line start while typing (it used to trash the whole note) and ⇧⌘⌫ deletes the note; ⌘⇧-arrows select text again; hotkey registers the new key before releasing the old; the pad follows Spaces/full-screen apps. Each is a walkthrough expect.
- **Removed:** Notion, Drafts sync, per-note RTF editing (launch-time migration with a verified byte-identical backup; RTF stays an export), the per-note colour well and priority UI (keys kept). `test.sh` fails if any networking API reappears.
- **Editor:** a real Markdown scanner and a pure, fuzzed edit engine replace regex styling; live preview with caret-aware marker reveal, Raw ⇄ Formatted (⌘/); inline-code chip drawn by `JotLayoutManager`; • bullets, hanging indents, ⌘-click links, placeholder; Return/Backspace/Tab/paste-URL on the touched lines only. The fuzz found two crashes in new code (inverted range; selection past the end).
- **Formatting bar:** toggling buttons that light up at the caret, one undo step each, 338 pt (fits 360); Format menu = Apple Notes shortcuts. Bold twice no longer yields `**x******`.
- **Header, windows, toasts:** 8 controls → 6, footer removed (chrome 134 → 90 pt); Share and ⋯ menus; `ToastCenter` (no more messages written over the title); pad fade/rise with a generation token (rapid toggles can't orphan it) and an `animateWithFallback` timer that guarantees final state when the display is asleep; placement falls back to the pointer's screen when the status item is hidden; native note windows with one editor per note (the two-way sync is gone).
- **Sidebar:** drawer below 560 pt (the text used to be squeezed to 176 pt), dock above; rows with snippet/time/badges; search; diff-animated list; context menu on demand; delete with Undo that restores name, content, date and reminder.
- **Sending:** real multi-page PDF (was one tall page), semantic HTML export, save failures reported instead of "Saved ✓", Stickies keeps/restores your clipboard and falls back to a guided copy, Apple Notes errors mapped to sentences with an Open Settings button.
- **First run and Settings:** `HotkeyDefaults` wired (new installs ⌥⌘J, existing keep ⌃J); welcome note instead of a window; Open at login is opt-in and shows the system's state; one compact Settings window; About.
- **Accessibility:** every control on the pad, the open sidebar and Settings is labelled (an unlabelled notes list was found and fixed); rows read as one phrase; toasts are announced.
- **Release engineering:** version 3.0 (30); `Jot.entitlements` (apple-events only); `codesign_command` / `release_commands` / `release.sh` with `--dry-run`; unit tests for the command builders.

### Bugs found on the way (all fixed; see GOTCHAS.md)
`URL.resourceValues` caches per instance (stale titles; `writeMetaPreservingDate` could stamp an older date) · hand-built key events mis-route shortcuts · `colorAt` drifts · TextKit background/enclosing-rect loss around concealed glyphs · a headless process can't enable spell checking · a saved-note write bumped every visited note to the top of the list.

### Remaining manual gaps (only a person can check)
Real VoiceOver speech; macOS 13–15 visuals (this Mac runs macOS 26); Intel hardware; multi-display, Spaces and notch placement; hover/press appearance and real animation feel; real Apple Notes and Stickies (including other locales); real notarization and a fresh recipient Mac; the Login Items approval flow; hotkey conflicts with other apps (Carbon cannot report them).

### Not done / owner decisions
- **Gated spikes not run:** S2 (Stickies, creates real stickies) and S3 (Apple Notes richer HTML, creates one real note). Until S3, Notes receives plain lines with `<br>`.
- Deferred by plan: Light/Auto appearance, an update mechanism, rendered tables, wikilinks/images. Not built: drawn checkboxes, quote bar / rule / code-fence fill, a shared `EditorPane` for pad and note windows, reminder popover polish and a notification-denied state, optional Tahoe glass.
- Owner items: licence, privacy/support text, copyright line, icon refresh, the Developer ID certificate and notarytool profile, and replacing the old installed 1.0 build (needs the running app quit — not done here).
