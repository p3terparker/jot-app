# Jot — v3.2 (32)
**A quick‑capture notepad that sends notes anywhere.** Hotkey **⌥⌘J** (existing installs keep ⌃J).

**Features**
- Fast editor tuned for **very large** notes (a 200 KB note opens in ~130 ms and a keystroke costs ~8 ms); debounced autosave; one `.md` file per note with optional **YAML frontmatter** (pin, order, folder, reminder — any other keys, comments and CRLF line endings are kept untouched).
- **Live‑preview Markdown** — `#` headings, **bold**, *italic*, ~~strike~~, links, `code` in a rounded chip, quotes and tables render as you type; list bullets are drawn as • and wrapped items line up under their text; markers hide except where the caret is. **View ▸ Show Markdown Syntax (⌘/)** shows every marker. No Rich Text editing mode — RTF is an export format.
- **Formatting bar** (Aa) — `Style ▾ · B · I · bullets · checklist · numbers · link · ⋯ · Raw`, fits the 360 pt pad, every button toggles and lights up at the caret; the same actions are in the Format menu with Apple Notes shortcuts (⇧⌘T / H / J / B, ⌘B ⌘I ⌘K, ⇧⌘7 / 9 / L, ⌘' …). Pasting a URL over selected text makes a link; Return continues lists and quotes; ⌘‑click opens a link.
- **Notes sidebar** — a drawer over the text on a small pad, docked beside it from 560 pt; rows show the plain title, a snippet, a short time and pin / reminder badges; **search (⌥⌘F)** over title and body ignoring case and accents; pins; **folders** (header rows that fold shut; right‑click a note ▸ **Move to Folder**, or drag it onto a header); ⌘/⇧‑click multi‑select; drag to reorder (right‑click ▸ **Reset Manual Order**); a context menu that follows the clicked note(s); each note remembers your caret and scroll position for the session.
- **Interactive checkboxes** (click `[ ]` / `[x]`) and **Markdown tables** (Tab / Shift‑Tab between cells).
- **Reminders** — bell badge by the title; a date picker popover; a macOS notification (title = note title); reconciled on launch and rescheduled when a note is restored or an Undo brings it back; if notifications are off for Jot it says so, with a button to the settings.
- **Open in New Window** — a note can live in its own native window (title bar, Aa · Share · Pin); **a note lives in exactly one editor**.
- **Fresh‑note sessions** — every launch opens a new blank note; reopening after **30 min idle** (with no note windows open) also starts one. Jot keeps exactly one empty scratch note and sweeps up strays.
- **Send a note** via **Share**: **Apple Notes**, **Stickies** (with a guided copy‑and‑paste fallback when Accessibility isn't granted; your own clipboard is restored), **Save As** txt / md / rtf / html / **paginated PDF**, system **Share…**, **Copy as Text**. Failures say what happened and what to do.
- **Delete with Undo** — notes go to **Recently Deleted** (kept 30 days) and a toast offers Undo; Recently Deleted has a visible **Restore**. **Paste Clipboard** into a new note · **Refresh** (right‑click the editor) re‑reads a note edited elsewhere · per‑note undo.
- A **welcome note** on first run, **Settings** (shortcut, open at login, font, background, display mode, spell checking, *start each session on a new note*, Share menu, notes folder) and **About**.
- **Private by construction:** no network access (`test.sh` fails if a networking API appears); notes are plain files on your Mac.

**Known limitations**
- Apple Notes uses Automation (a one‑time macOS prompt); the body is sent as plain lines (`<br>`) — richer HTML is waiting on a verified spike against real Notes. **Stickies** has no working system Service, so Jot drives it by **keystrokes**, which need **Accessibility for Jot** (without it the note is copied and Stickies opens with a hint); that grant only persists under stable code signing.
- Reminders require notification permission (requested on first set). A note that literally starts with `---` and has a closing `---` on a later line could be read as frontmatter.
- Concealed Markdown markers are still read by VoiceOver in Formatted mode; Raw mode (⌘/) reads the text exactly as written.
- The Notion and Drafts integrations and the per‑note colour / priority controls were removed; their old preference keys and frontmatter keys are left inert, not deleted (`defaults delete com.jacob.jot notionToken` removes a stored token).

**Changelog**
- **3.2 · drag the sidebar shut** — drag the docked sidebar's divider all the way to the left (narrower than 100 pt) and it closes; the saved width is left as it was, so reopening gives the width you had. **Build and update:** pushes to a `claude/*` branch are built, tested and walked through on GitHub's Mac and published as one "Current build" pre-release; `scripts/jot-update.sh` installs it on the Mac in place, without a browser download or Gatekeeper dialog (docs/RELEASE.md).
- **3.1 · sidebar folders** — Group notes under folders in the notes list. A folder is a name in the note's frontmatter (`folder: "Work"`), so the files stay flat in the notes folder and nothing else a note says about itself is touched. Unfiled notes stay at the top, exactly as before; each folder follows as a header row (chevron, name, note count) with its notes indented beneath it — pinned first, then dragged order, then newest, as in the rest of the list. **Make and file:** right‑click a note ▸ **Move to Folder ▸** (a folder, **New Folder…**, **Remove from Folder**) — it acts on the whole multi‑selection; the same submenu is in **⋯** for the open note; or drag a note onto a folder's header. Dragging between rows files the note in that group and orders it there. **Fold:** click a header (VoiceOver: press); the choice is remembered. **Rename / remove:** right‑click a header; removing a folder only unfiles its notes. Every move and a folder removal show an Undo toast. Right‑click empty space ▸ **New Folder…** makes an empty one. While you search, the list is flat (all matches, folded folders included) and drag‑reorder is off. ⌥⌘↑ / ⌥⌘↓ walk the visible notes and skip headers. Folder names are cleaned (no `"` or `\`, line breaks become spaces, 60 characters) and matched ignoring case and accents. Folders appear in the order they were made; an empty one is kept in Preferences (`folderOrder`), a folder only some note names (edited outside Jot) follows them alphabetically.
- **3.0 · standalone repository (2026-10-28)** — Jot now lives in its own MIT-licensed repository with its own build, test, packaging and release tooling; it no longer ships as part of the GlassKit suite. No behavior change: the bundle ID, preferences, notes folder and shortcut defaults are unchanged. The isolated preview harness flags are now `--jot-preview`, `--jot-preview-snapshots <dir>` and `--jot-preview-seconds <n>`.
- **3.0** —
  **Removed:** Notion, Drafts sync and the per‑note Rich Text *editing* mode. Legacy `rtfMode` notes are converted to Markdown at launch after a verified byte‑identical backup (`…/Jot/Backups/RTF/<time>/`, plus a plain `.rtf` copy); RTF stays an **export** format. Jot makes **no network requests** (`test.sh` fails if a networking API appears).
  **Editor:** live preview rebuilt on a real Markdown scanner (CommonMark‑style emphasis rules, linear time): `#` headings, bold, italic, ~~strike~~, links, `code` in a rounded chip, tasks; markers hide except at the caret (a span's markers show while the caret is on it or at its edges); selections over 2,000 characters reveal nothing. **View ▸ Show Markdown Syntax (⌘/)** switches to Raw (every marker visible, one font). Fixes: a line after a bare `# ` is no longer a heading; `***x***` hides all six markers.
  **Formatting bar:** `[Style ▾ Title/Heading/Subheading/Body] B I • ☑ 1. 🔗 ⋯ Raw` — fits the 360 pt pad with no scrolling; every button toggles (Bold twice no longer gives `**x******`, Heading twice no longer gives `# # x`), lights up while the caret is in that formatting, and is one ⌘Z. ⋯ holds strikethrough, code, quote, code block, divider, table, indent. A URL on the clipboard becomes a link's destination. Shortcuts follow Apple Notes: ⇧⌘T / H / J / B, ⌘B ⌘I, ⇧⌘X, ⇧⌘M, ⇧⌘7 / ⇧⌘9 / ⇧⌘L, ⌘', ⌘K, ⌘] / ⌘[. Font and size moved to **Preferences ▸ Editor** and View ▸ Bigger / Smaller / **Actual Size (⌘0)**; the per‑note text‑colour well is gone (an existing `textColor:` key still renders and is kept).
  **Keys and windows:** ⌘⌫ deletes to line start while you type (⇧⌘⌫ deletes the open note; ⌘⌫ deletes a note only with the notes list focused); ⌘⇧‑arrows select text again (notes: ⌥⌘↑ / ⌥⌘↓, sidebar: ⌃⌘S); **Esc** and ⌘W hide the pad (the find bar closes first); the hotkey on a visible but unfocused pad focuses it; changing the hotkey registers the new key before releasing the old one; the pad follows you across Spaces and full‑screen apps; opening a note window or Settings puts the tray away unless pinned; Delete acts on the focused editor's note.
  **First run and Settings:** the default shortcut for a new install is **⌥⌘J** (an existing install that never chose one keeps ⌃J; it is decided once and written down, so a later default change can't move anyone's key). A new install opens straight onto a real **"Welcome to Jot" note** — it shows the formatting it describes, with clickable checkboxes and the person's actual shortcut — instead of a separate welcome window. **Open at login is the person's choice** (it was registered silently before); the switch shows the system's real state and points to Login Items if macOS wants approval. **Settings** is one compact window — Shortcut, Startup, Editor (font, size, background swatches Dark / Black / Slate / Paper + a custom colour, show notes as Formatted or Markdown source, spell checking — off by default), Share menu, Notes folder, version — and every control applies at once. **About Jot** says plainly that notes are plain Markdown files and Jot makes no network connections.
  **Data safety:** frontmatter is **patched, never regenerated** — unknown keys, comments and CRLF line endings survive a save.
  **Top bar and Share:** the footer action bar is gone and the header is `sidebar · the note's plain title (with pin and reminder badges) · Aa · Share · New · ⋯` — 48 + 42 pt of chrome instead of 134. **Share** holds Apple Notes, Stickies, Save As ▸ (txt / md / rtf / html / pdf), Share… and Copy as Text (each can be hidden in Preferences). **⋯** holds Keep on Top, Remind Me…, New Note from Clipboard, Open in New Window, Delete Note, Recently Deleted, Show Notes in Finder, Settings…, About and Quit. Messages ("Copied ✓", "Saved to Apple Notes ✓") are **toasts** — one pill at a time, newest wins, never written over the title. Titles everywhere are plain text (no `#`, `**` or link syntax), so "Save As" proposes `Welcome to Jot.md`, not `# Welcome to Jot.md`.
  **Sidebar:** rows show the plain title, a one‑line snippet and a short time (the time today, Yesterday, the weekday, "Sep 27", "9/27/25"), with pin and reminder badges. On a pad narrower than 560 pt the list is a **drawer** over the text — the text keeps its full width (it used to be squeezed to ~14 characters a line), the rest is dimmed, and a click on it, Esc, or picking a note closes the drawer; from 560 pt up it **docks** beside the text with the draggable divider and the text keeps at least 300 pt. Opening and closing slide (Reduce Motion: instantly). **Delete** moves notes to Recently Deleted with an **Undo** toast that restores the name, content, place in the list and reminder; deleting a note you are not editing no longer jumps the editor; in Recently Deleted the header's New button becomes **Restore**. Merely visiting a note no longer rewrites its file, so it doesn't jump to the top of the list. **Search Notes (⌥⌘F)** filters the list by title and body as you type, ignoring case and accents ("resume" finds "Résumé"); Esc clears it, Return opens the first match. The list's right‑click menu is built when it opens (Pin / Unpin, Remind Me… / Change Reminder…, "Delete 3 Notes"); the priority submenu is gone. Rows slide in and out instead of the list reloading, each note remembers your caret and scroll position for the session, switching notes cross‑fades, and holding ↑/↓ in the list loads the note you stop on.
  **Pad window:** it fades and rises in (about 140 ms) and fades out; rapid toggles can't leave it stuck or orphaned; under Reduce Motion it just appears. Size is remembered every time you resize; position only once you drag it away. If the menu‑bar icon is hidden (notch, crowded menu bar) the pad opens at the top centre of the screen the pointer is on, and it is always kept on a screen. **Editing:** Return continues a bullet, number, task or quote (and splits an item at the caret, ends the list on an empty item, never produces `- - x`); Backspace right after a marker removes the marker; Tab / ⇧Tab nest and un‑nest lists; pasting a URL over selected text makes a link. Opening a 200 KB note styles it once (131 ms, was 196) and a keystroke in it costs 8 ms (was 61).
  **Note windows and the editor's look:** a note opened in its own window is now a native window — traffic lights, the note's title centred, Aa · Share · Pin in the title bar — and **a note lives in exactly one editor**: picking a note that has its own window brings that window forward instead of loading it into the pad as well (opening the pad's own note in a window moves the pad on to a blank note). List items and quotes that wrap line up under their text, bullets are drawn as •, ⌘‑click opens a link (http, https and mailto only), and an empty note shows a faint "Start typing…".
  **Sending, reminders and release tooling:** Save As reports a failed save instead of "Saved ✓"; the PDF export flows over as many pages as the note needs (it used to be one very tall page); the HTML export is clean, escaped, semantic HTML; Stickies borrows your clipboard and gives it back, and without Accessibility it copies the note, opens Stickies and says what to press; Apple Notes errors become sentences with an Open Settings button; a reminder that notifications can't deliver says so; Settings can turn off "start each session on a new note". For the signed release: `Jot.entitlements` (Apple Events only), hardened-runtime signing and `./release.sh` (notarize → staple → disk image → notarize → staple, `--dry-run` first) — see [RELEASE.md](RELEASE.md).
- **2.9** — Recoverable deletion/restore reports failed moves and keeps originals; autosave protects removed/unreadable notes; detached editors cannot recreate deleted notes. Quit flushes pending editors and is canceled when saving fails. Drafts read failure is distinct from a successful empty sync. Recently Deleted navigation preserves the prior note. Added isolated storage/snapshot regression checks.
- **2.8** — **Sidebar cleanup.** **Newest notes now sort to the top** — `order: 0` (no manual position) sorts
  *above* dragged notes, fixing the bug where a single drag numbered every note and every note made afterwards
  sank to the bottom. **No more blank-note pile-up** — `openBlankNote()` reuses the empty note that's already
  there instead of creating another, and `pruneBlankNotes(keeping:)` sweeps strays on launch (never touching a
  note that's pinned/prioritised/coloured/has a reminder/is in RTF mode, is open in its own window, or mirrors a
  Draft). **Drag-to-reorder actually works** — `acceptDrop` parsed the file path with `URL(string:)`, which
  returns nil on the space in "Application Support", so every drop silently failed; also fixed the drop-below
  off-by-one. New **Reset Manual Order** context-menu item clears all manual positions. Frontmatter-only writes
  now **preserve the file's modification date**, so reordering no longer scrambles the date sort. Selecting a
  note **scrolls its row into view**. Row titles + metadata are **cached per note** (invalidated by mod date)
  instead of re-reading every file on every sort and redraw.
- **2.7** — **Reverted sidebar to flat `NSTableView`** (folders cancelled — the `NSOutlineView` conversion
  broke multi-select, delete, and right-click). Now a simple flat list with **drag-to-reorder** (reassigns
  `order` frontmatter), **pin/priority context menu** (right-click any note), and all v2.5–2.6 features intact
  (checkboxes, tables, reminders, text colour, keyboard nav, RTF/MD toggle). Removed `FolderItem` class, all
  folder store methods, and the `folder` frontmatter field. **Multi-select fixed** — `tableViewSelectionDidChange`
  now skips editor switch when >1 row selected, preserving ⌘/⇧-click multi-select for bulk delete. **Delete fixed**
  — `saveCurrent()` now guards on file existence (prevents pending autosave from re-creating deleted files);
  all delete paths cancel the autosave timer first. **RTF/MD toggle moved** from the tools bar segmented control
  to the **Format menu** (⌘\\) and **sidebar context menu** (per-note, with checkmark state via `menuNeedsUpdate`).
  **Resizable sidebar** — drag the divider to resize; width persisted in `Prefs.sidebarWidth` (min 120px).
- **2.6** — **Per-note RTF/MD mode toggle**: segmented control in the tools bar switches each note between
  Markdown (live styling, concealed markers) and Rich Text (native bold/italic/colour, spell-check).
  Switching converts content between formats. RTF notes store base64-encoded RTF as the file body (frontmatter
  `rtfMode: true`). Bold/italic formatting bar buttons work in both modes (markdown insertion vs font trait
  toggle). RTF export preserves editor formatting. Undocked windows also support per-note RTF mode.
- **2.5** — **YAML frontmatter** per note (`pin`, `priority`, `order`, `textColor`, `reminder`).
  **Interactive checkboxes** — click `[ ]`/`[x]` to toggle; `[x]` renders green. **Markdown tables**
  — insert via tools bar, Tab/Shift-Tab cell navigation, separator lines styled dim. **Per-note text colour**
  — colour well in the tools bar (stored in frontmatter, reset button). **Reminders** — bell button in the
  header with a date-picker popover; schedules `UNUserNotification` (click to open the note); reconciled on
  launch. **Keyboard navigation** — ⌘⇧ arrows (←/→ sidebar, ↑/↓ notes). **Delete creates a blank note**
  (no longer selects the next note). **New windows position near the current window** (not bottom-left).
  **Pin notes** (sort to top), **priority levels** (coloured dots: High/Medium/Low). **Drag-to-reorder** notes.
- **2.3** — **Undocked note windows** (double‑click a note) gained their own **share menu** (an
  `NSSharingServicePicker` from a `square.and.arrow.up` button), a **pin** button (always‑on‑top), and a
  **bold note title in the header**. The undocked window and the docked list now **two‑way live‑sync** —
  edits in either propagate both ways (fixed a stale‑buffer clobber where switching focus could overwrite
  newer text). **⌘N** from a secondary/undocked window now pops a **fresh** window. (Still no rename — a
  note's title is its first line, by design.)
- **2.2** — **Per‑note undo:** each note keeps its own undo stack, so ⌘Z no longer wipes when you switch
  notes (vended via `undoManager(for:)`; loading a note isn't itself undoable). **Recently Deleted:** a
  trash‑circle header button toggles the sidebar to deleted notes, kept **30 days** then auto‑purged
  (right‑click ▸ Restore / Delete Permanently) — deletes move to `…/Jot/RecentlyDeleted`, not the system
  Trash. **Stickies fix:** the keystroke path targets the correct app for Accessibility (**Jot**, not
  Stickies) and waits for Stickies to be frontmost before pasting; it no longer re‑prompts on every send —
  ad‑hoc signing makes `AXIsProcessTrusted()` read `false` even when access is granted, so it just attempts
  the keystrokes and guides at most once per launch only if they're actually blocked. **Drafts sync**
  (opt‑in, Preferences): mirrors Drafts notes tagged `jot` into the sidebar by reading `DraftStore.sqlite`
  read‑only (copied to temp, queried with the `sqlite3` CLI) and pushes new jots back via `drafts://…&tags=jot`.
  Links the **ApplicationServices** framework (for the Accessibility check).
- **2.1** — Formatting bar is now **toggleable** from the top bar (editor reclaims the space when hidden);
  only everyday text tools show by default (heading **#**, bold, italic, bullet, numbered, checklist, quote) —
  code `</>` and divider `---` are hidden behind an advanced‑tools flag, not removed. **Real bold/italic**:
  the `**`/`*` markers are now concealed (zero‑width glyphs) instead of shown, and reveal automatically only
  on the line your cursor is in — still saves as plain `.md`. Fixed **⌘Z/⌘⇧Z** undo/redo (Edit menu was
  missing standard Undo/Redo items). Sidebar now supports **⌘/⇧‑click multi‑select** with bulk delete.
  **Double‑clicking a note** opens it in its own **undocked, editor‑only window** (no sidebar, **✕** close
  button instead of the tray‑arrow) that stays in sync with the docked list.
- **2.0.2** — Default editor background is now **black** (was dark grey); a **Welcome window** introduces
  the app on first open; menu‑bar/app icon recoloured to a deep **burnt orange**.
- **2.0.1** — Window now **collapses to a very small pad** (min 240×150); the **writing‑tools bar scrolls
  horizontally**, like the export bar, so every tool stays reachable at any width.
- **2.0** — Live markdown styling; size dropdown + ⌘±; Stickies create‑and‑paste; “Paste Clipboard”;
  square window; tiny scrolling action bar; side panel hidden by default.
- **1.x** — Action‑bar export targets, huge‑text editor, Notion integration, editable background.

**Roadmap (ideas, not commitments)**
- Send a note to a specific open Notes or Stickies window; iCloud sync of notes; insert content from a search.
- Deferred past 3.0: Light/Auto appearance, an update mechanism, rendered tables, wikilinks and images, drawn checkboxes, quote bars / rules / code-fence fills, a shared editor pane for the pad and note windows, reminder popover polish, optional macOS 26 glass.
