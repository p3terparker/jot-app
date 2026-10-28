# Jot — GOTCHAS (solved problems, so we never re-hit them)

Append an entry whenever you solve a **non-obvious** bug or fight macOS and win. Format:

> **<short title>** *(date)*
> **Problem:** what went wrong / the symptom.
> **Cause:** the real root cause.
> **Fix:** what actually worked (with the key API/flag/path).

Keep newest at the top. These are the hard-won ones already paid for — read this before re-debugging
something that smells familiar. (Entries date from when Jot lived inside the GlassKit suite.)

---

> **A new repository silently has no author identity — and Git invents one** *(Jot · 2026-10-28)*
> **Problem:** `git config user.name` printed nothing in a freshly initialised repo (a `&&` chain stopped there without an error), and a commit made
> without a configured identity is stamped with an address derived from the machine's hostname, which then sits in the public history for good.
> **Cause:** on this Mac the global Git config holds only credential helpers; the author name and the GitHub noreply address live in each repository's
> own `.git/config`, so every `git init` or new clone starts with neither.
> **Fix:** set `user.name` and `user.email` (the GitHub `…@users.noreply.github.com` address) **locally before the first commit**, then check with
> `git log --format='%an <%ae>'`. Do the same on any other machine you commit from. If a hostname-style address slips in, fix it while the repository is
> still private; rewriting published history is a separate, deliberate decision.

> **Ad-hoc signing silently drops Accessibility/TCC grants every rebuild** *(Jot · 2026-06-22)*
> **Problem:** Jot kept losing Accessibility permission (Stickies broke) after every rebuild.
> **Cause:** macOS keys TCC grants to the code signature; an ad-hoc signature's cdhash changes on
> every build, so the grant is orphaned each time.
> **Fix:** sign local builds with a **stable code-signing certificate** from your keychain (Keychain Access ▸
> Certificate Assistant ▸ Create a Certificate, type **Code Signing**) and pass it with `./build.sh --identity "Name"`
> or `JOT_SIGNING_IDENTITY`; grant Accessibility once and it persists. Ad-hoc stays the default and is fine for
> anything that needs no TCC grant. Trap when making the certificate by hand: use the **system LibreSSL**
> (`/usr/bin/openssl`) for the `.p12`, because OpenSSL 3's PKCS#12 MAC is rejected by `security import`.

> **New notes sank to the bottom of the sidebar** *(Jot · 2026-09-03)*
> **Problem:** every note created after the first drag-to-reorder appeared at the BOTTOM of the notes list
> instead of the top, no matter how recent.
> **Cause:** `sortNotes` treated the `order` frontmatter field as "has a manual position → sorts first".
> A single drag renumbers **every** note (`order: 1…N`), so from then on new notes (`order: 0`) lost every
> comparison and sank below the whole numbered block.
> **Fix:** `order == 0` now sorts **above** ordered notes (unordered = new = top), with mod-date descending
> inside each group. Added a **Reset Manual Order** context-menu item to clear the numbering entirely, and
> frontmatter-only writes now restore the file's modification date (`writeMetaPreservingDate`) so reordering
> doesn't scramble the date-sorted part of the list.

> **Sidebar filled up with blank "New Note" rows** *(Jot · 2026-09-03)*
> **Problem:** empty notes kept accumulating (11 zero-byte files on disk) and had to be deleted by hand.
> **Cause:** `openBlankNote()` unconditionally called `store.create()`, and it runs on *every* delete, on
> "Open in New Window", and on each fresh dropdown open. Nothing ever collected the empty note it had left
> behind, so each of those actions minted another file.
> **Fix:** `openBlankNote()` now **reuses** an existing blank note (`reusableBlankNote()`) instead of
> creating one, and `pruneBlankNotes(keeping:)` sweeps strays (also at launch). Blank = empty body **and**
> `!meta.isDecorated` — `order` deliberately excluded, since a sort position isn't content. Notes open in an
> undocked window, Drafts mirrors, and anything pinned/coloured/prioritised/with a reminder are never swept.
> Callers must `saveCurrent()` first — an unsaved editor makes a note look blank on disk.

> **Drag-to-reorder in the sidebar never worked** *(Jot · 2026-09-03)*
> **Problem:** dropping a note on a new row did nothing.
> **Cause:** `acceptDrop` did `URL(string: path)` on a POSIX path. Every notes path contains a space
> (`~/Library/Application Support/Jot/Notes/…`), and `URL(string:)` returns **nil** on unencoded spaces —
> the guard bailed on every drop. Plus an off-by-one: `row` is in pre-removal coordinates, so dropping
> below the dragged row landed one slot too low.
> **Fix:** `URL(fileURLWithPath: path)` (never `URL(string:)` for a file path), and `row - 1` when
> `row > srcIdx`.

> **Stickies "Make New Sticky Note" Service is a no-op on current macOS** *(Jot · 2026-06-22)*
> **Problem:** `NSPerformService("Make New Sticky Note", …)` returns false in every context; Stickies has
> no AppleScript dictionary either.
> **Fix:** drive Stickies with **synthetic keystrokes** (⌘N then ⌘V), which require **Accessibility for
> Jot** (denial → AppleScript error 1002). Try the Service first in case Apple revives it, then keystrokes.
> Only works with AX granted **and** stable signing (see the first entry). Note: under ad-hoc signing
> `AXIsProcessTrusted()` reads `false` even when granted, so don't gate on it — just attempt and guide once.

> **Frontmatter vs. horizontal-rule ambiguity** *(Jot · 2026-07-07)*
> **Problem:** a note that starts with `---` (a markdown horizontal rule) could be misinterpreted as YAML
> frontmatter.
> **Cause:** `parseFrontmatter` treats `---\n` at the start as the opening delimiter and scans for a closing
> `---`. A note like `---\nSome text\n---\nMore` would parse `Some text` as a frontmatter key.
> **Fix:** if no closing `---` is found, the whole file is treated as body (no frontmatter). This is standard
> YAML frontmatter behavior — the ambiguity is inherent. Accepted as a known limitation; documented in
> docs/FEATURES.md. Notes created by Jot never start with `---` (they start empty).

> **NSOutlineView broke multi-select, delete, and right-click** *(Jot · 2026-07-07)*
> **Problem:** after converting the sidebar from `NSTableView` to `NSOutlineView` with folders, multi-select
> (⌘/⇧-click), delete, and right-click context menus all stopped working.
> **Cause:** `outlineView(_:menuFor:)` had the wrong selector name (should be `menuForItem`), so the context
> menu never fired. `tableView.item(atRow:)` returned `nil` for folder rows, breaking delete. `notes[row]` no
> longer mapped to outline rows. `captureClipboard` still used the old `notes.insert` pattern without
> `buildSidebarTree()`.
> **Fix:** reverted to a flat `NSTableView` (folders cancelled). All features (pin, priority, drag-reorder,
> reminders, checkboxes, tables, text colour, keyboard nav, RTF/MD toggle) work on the flat list. Lesson:
> don't add hierarchy to a working flat list unless you're prepared to rewrite every row-index-based operation.

> **Pending autosave re-creates deleted notes** *(Jot · 2026-07-12)*
> **Problem:** delete didn't work — the note reappeared immediately after deletion.
> **Cause:** `saveCurrent()` writes `textView.string` to `current`'s file path via `store.write()`, which
> **creates** the file if it doesn't exist (`try? full.write(to: u, atomically:true)`). The 0.7s debounced
> autosave timer (`saveWork`) could fire after `store.delete()` moved the file to trash but before
> `openBlankNote()` replaced the editor content, re-creating the file at the original path.
> **Fix:** (1) `saveCurrent()` now guards `FileManager.default.fileExists(atPath: u.path)` before writing.
> (2) All delete paths call `saveWork?.cancel()` before deleting. (3) `select()` and `openBlankNote()` also
> cancel `saveWork` to prevent stale timers from firing after a note switch.

> **Autosave silently dropped hand-added frontmatter keys; CRLF notes never closed their frontmatter** *(Jot · 2026-09-30)*
> **Problem:** a note edited in Obsidian (`tags: [work]`, `aliases:`, comments, a YAML list) lost those lines the next time
> Jot autosaved it, and a CRLF file's frontmatter showed up as text in the editor.
> **Cause:** `formatFrontmatter` rebuilt the block from the six keys Jot knows. And the closing fence is `---\r` in a CRLF file,
> which `.trimmingCharacters(in: .whitespaces)` doesn't strip (`\r` is a newline character, not whitespace).
> **Fix:** `NoteMeta` keeps the original lines (`rawLines`) and the file's line ending; writes **patch** them — Jot's keys are
> updated in place (a value that didn't change keeps the author's own spelling), a key back at its default is dropped, new keys
> are appended, everything else is kept verbatim and in order. Only column-0 `key:` lines are Jot's, so nested YAML is never
> misread. A note carrying foreign frontmatter counts as "decorated", so the blank-note sweep can't delete it. 12 checks in
> `Tests/main.swift`.

> **`String(nsString.character(at:))` is the character's NUMBER** *(Jot · 2026-09-30)*
> **Problem:** switching a note to Rich Text (and, once RTF export was made formatted, exporting one) turned "Welcome" into
> `87101108…` — `markdownToRichText` appended one `String(ns.character(at: i))` per character. Probably why none of 46 real notes ever
> used RTF mode.
> **Cause:** `character(at:)` returns a `unichar` (`UInt16`) and `String(UInt16)` is its decimal text, not the character.
> **Fix:** copy attributed **runs** (`attributedSubstring(from:)`), which also keeps surrogate pairs intact and avoids an O(n²)
> per-character append. The walkthrough exports a note to RTF and reads it back, asserting the bold run, the large title and the
> absence of `#` — an export that is never read back can be wrong for years.

> **A main-menu key equivalent steals text-editing keys from the editor** *(Jot · 2026-09-30)*
> **Problem:** ⌘⌫ deleted the whole note while typing instead of the line (the menu's "Delete Note" was bound to it), and ⌘⇧←/→/↑/↓
> couldn't select to line/document edges because `JotTextView.keyDown` used them for sidebar navigation.
> **Cause:** AppKit offers a ⌘-key to the window's views first, then the **main menu**, and only then to `keyDown` — so an enabled
> menu item always beats the text view's own key bindings (`deleteToBeginningOfLine:` etc.). The Delete key sends `0x7F` as a
> character while a menu item written with `NSBackspaceCharacter` is `0x08`, so a handler must match `keyCode == 51`, not the character.
> **Fix:** `JotTextView.performKeyEquivalent` takes ⌘⌫ itself when it is first responder (so the menu still deletes a note when the
> notes list has focus, and `validateMenuItem` disables the menu's ⌘⌫ while any text field is editing); ⇧⌘⌫ deletes the open note from
> anywhere; navigation moved to ⌃⌘S and ⌥⌘↑/↓ menu items. The walkthrough routes synthesized events window → menu → `keyDown` and
> asserts who consumed each shortcut — add a line there for any new key equivalent.

> **`RegisterEventHotKey` can't tell you a shortcut is taken by someone else** *(Jot · 2026-09-30)*
> **Problem:** changing the hotkey unregistered the old one first and ignored the result, so a refused key left Jot with no shortcut.
> **Cause:** Carbon reports `eventHotKeyExistsErr` (-9878) only when *this process* (or an *exclusive* registration) already holds the
> combination. System shortcuts and other apps' ordinary hotkeys register "successfully". Recorders can't promise conflict detection.
> **Fix:** `applyHotkey` registers the new key first and releases the old one only on success (re-choosing the current key is a no-op
> success); the Settings recorder keeps a shortcut only if it registered. Be honest in UI copy: "another app or macOS may be using it".

> **A preview/test process shares your real notification center** *(Jot · 2026-09-30)*
> **Problem:** `reconcileReminders()` cancels every pending request whose id isn't one of *its* notes' UUIDs. Pending
> `UNUserNotificationCenter` requests are stored per **bundle ID**, so a second Jot process (a preview, a harness) with
> temporary notes sees every real reminder as stale and removes it.
> **Fix:** all UserNotifications access goes through `notificationCenter()`, which returns `nil` in a preview (and records the
> attempt in `PreviewLog`). Never call `UNUserNotificationCenter.current()` directly; `preview.sh` also runs the preview
> with a throwaway `HOME`, defaults suite, notes folder and pasteboard.

> **`cacheDisplay` snapshots of an off-screen window are transparent where the window background should be** *(Jot · 2026-09-30)*
> **Problem:** the preview PNG of a plain (non-glass) window — Settings — had invisible labels: dark-mode text on transparent
> pixels. A glass window (`NSVisualEffectView`) renders nothing at all under `cacheDisplay`.
> **Fix:** glass windows get a solid stand-in view in snapshot runs (`GlassView`); every snapshot is composited onto
> `window.backgroundColor` resolved under the window's own appearance. Two traps: set `canvas.size` **before** creating the
> `NSGraphicsContext` (it reads the size at creation, or a "full" fill covers a quarter of the bitmap), and draw the rep with an
> explicit `.sourceOver` — `NSBitmapImageRep.draw(in:)` overwrites the fill with the rep's transparent pixels.

> **"Save, then reload from disk" clobbers the outside edit it was meant to pick up** *(Jot · 2026-10-16)*
> **Problem:** editor right-click ▸ Refresh was meant to show an edit made elsewhere, but the note kept its old text and the file was reverted.
> **Cause:** `saveCurrent()` always writes the editor buffer, so calling it before reloading overwrote the external change with the stale buffer.
> **Fix:** flush only when an autosave is actually pending (`saveWork` non-nil and not cancelled; `saveCurrent` cancels it on run), otherwise reload without writing.

> **The inline-code tint vanished in snapshots once markers were concealed** *(Jot · 2026-09-30)*
> **Problem:** `.backgroundColor` on an `` `inline code` `` run drew fine in a bare `NSTextView`, but in the preview PNGs it was missing whenever the
> span sat on a later line of a paragraph whose earlier line had a struck word and the marker glyphs were hidden (`.null` glyphs). Removing the
> strike — or the conceal delegate — made it appear; attribute dumps always showed it present, and so did a loud opaque red, so it was drawing, not styling.
> **Cause (observed, not proven):** in the `cacheDisplay` pass `enumerateEnclosingRects(forGlyphRange:)` for a range ending in a concealed glyph
> returned only a zero-width rect at the end of the previous line, while the on-screen `display()` pass returned the right one. I could not capture the
> real on-screen window here (`CGWindowListCreateImage` returns nil, `screencapture` has no permission), so whether the old path also failed for a
> user is unverified.
> **Fix:** `JotLayoutManager.drawBackground` paints a rounded `.jotChip` run from the positions of the **visible** glyphs only (`location(forGlyphAt:)`,
> one rect per line fragment, `EditorKit.swift`); the styler no longer uses `.backgroundColor`. The walkthrough renders the failing sample and counts
> tinted pixels. Trap on the way: `NSBitmapImageRep.colorAt(x:y:)` converts colour spaces and drifts a few units — read `bitmapData` when asserting a
> colour (a 3,900-pixel chip read as 65).

> **Hand-built key events lie about menu shortcuts** *(Jot · 2026-10-26)*
> **Problem:** a test that fed `NSEvent.keyEvent(…, characters: "b", charactersIgnoringModifiers: "b", …)` to the main menu fired **Body (⇧⌘B)** for ⌘B, and a lowercase-`x` event with ⇧⌘ fired **Cut** — while the same menu is fine with a real keyboard.
> **Cause:** a real event carries `characters` in lower case and `charactersIgnoringModifiers` *shifted* (`"X"` for ⇧⌘X, `"&"` for ⇧⌘7, `"("` for ⇧⌘9). A hand-made event doesn't, and AppKit's key-equivalent matching then lands on the first menu item with that letter.
> **Fix:** build test events from key codes — `CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)`, set `.flags`, wrap with `NSEvent(cgEvent:)` — and route them window views → main menu → `keyDown`. These reproduce real routing (⌘B → Bold, ⇧⌘B → Body, ⇧⌘X → Strikethrough, ⌘X → Cut, ⇧⌘7 → the "7"+shift item). Key codes are physical positions, so the walkthrough skips these checks (with a note) unless key code 11 types "b". Menu items for shifted digits are written as the unshifted key plus the shift mask (`"7"`, `[.command, .shift]`).

> **A `URL` remembers its old modification date** *(Jot · 2026-10-27)*
> **Problem:** after Jot saved a note, its header title and sidebar row kept showing the old first line ("New Note" for a note that now began `# First title`) until the list happened to be rebuilt. Worse, `writeMetaPreservingDate` could stamp a note with an *older* date than it really had, sending it back down the list.
> **Cause:** `URL.resourceValues(forKeys: [.contentModificationDateKey])` caches per `URL` instance. Asked again on the same instance after the file was rewritten, it still returns the first answer (verified: 1600000000 vs the real 1793167464, while `attributesOfItem(atPath:)` and a fresh `URL(fileURLWithPath:)` are right). `noteInfo(url)` — a cache keyed by that date — therefore never saw a change on URLs that stay in `notes`.
> **Fix:** `NotesStore.modificationDate(_:)` / `fileSize(_:)` read `FileManager.attributesOfItem(atPath:)` every time and everything that decides "did this file change?" uses them; `saveCurrent` also drops a note's cached row data outright, since Jot knows it just wrote it. Never use `URL.resourceValues` for change detection on a URL you keep.

> **A headless process can't turn spell checking on** *(Jot · 2026-10-27)*
> **Problem:** a walkthrough check that `NSTextView.isContinuousSpellCheckingEnabled` became true after the Settings switch failed although the code was right.
> **Cause:** with no spelling service available (a preview/CI process) the property stays `false` whatever it is set to — a bare `NSTextView` in a window behaves the same.
> **Fix:** the preview records the `applySpellcheck()` call (`PreviewLog`) and the walkthrough asserts that; the property itself can only be verified in a real session.

> **AppKit animations never complete while the display is asleep** *(Jot · 2026-10-27)*
> **Problem:** a hide-the-pad check that had passed for hours started failing: the window stayed visible at full alpha with `padHiding` stuck `true`, no completion handler ever ran, and window/sidebar/toast animations looked "randomly" broken.
> **Cause:** `NSAnimationContext` completion handlers — and the window-alpha / frame animator itself — are driven by the display; with the screen asleep or locked nothing ticks. A window's final state must therefore never depend on an animation finishing.
> **Fix:** `animateWithFallback(duration:_:done:)` (PadWindow.swift) starts the animation **and** a timer that runs `done` once shortly after the animation should have ended; the pad, the sidebar drawer and toasts all go through it, guarded by a generation token so a stale `done` can't undo a newer show/hide. Previews switch motion off unless a test asks for it. Related: an animator proxy on a *view* updates the model value at once, but on an `NSWindow` it animates the real property, so a window's `alphaValue` is still 1.0 mid-fade (or forever, if nothing ticks).

> **Table rows only animate if `notes` is changed through the diff** *(Jot · 2026-10-27)*
> **Problem:** after switching the sidebar to slide rows in and out, deleting a note left the table with one row too many (13 rows, 12 notes).
> **Cause:** `moveNoteToRecentlyDeleted` removed the URL from the `notes` array itself; the later `rebuildNotes()` then diffed that already-shortened array against the new one, found nothing to do and never told the table.
> **Fix:** `notes` is only ever replaced through `setNotes(_:)`, which diffs old against new (`ListDiff`, a pure LCS) and applies `removeRows` / `insertRows`; if the table's row count ever disagrees with `notes` it falls back to `reloadData()`. Never mutate the data array and rely on a later reload when updates are animated.

> **Small AppKit traps found in the 3.0 chrome** *(Jot · 2026-10-27)*
> • An `NSTitlebarAccessoryViewController` whose view is an Auto Layout `NSStackView` with no frame draws nothing — give the view an explicit frame (`setFrameSize`). • `cacheDisplay` of a window's `contentView` omits its title bar; snapshot `contentView.superview` (the frame view) to include the traffic lights, title and accessory buttons. • Foundation writes file dates with **microsecond** resolution (`setAttributes([.modificationDate:])`), so a restored note's date differs from the original's nanosecond value — compare within a millisecond. • `NSTableView.mouseDown` blocks until the click or drag ends; detect "a plain click" after `super.mouseDown` by comparing the up-event's location with the down-event's. • A key window hides first-responder-dependent behaviour: with a drawer open the list owns the keys, so tests that type into the editor must make it first responder explicitly.
