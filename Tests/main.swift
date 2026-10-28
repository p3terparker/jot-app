import Cocoa   // NSAttributedString / NSFont for the RTF migration checks

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("jot-tests-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
var checks = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    checks += 1
}
func expectFailure(_ message: String, _ body: () throws -> Void) {
    do { try body() } catch { checks += 1; return }
    fatalError(message)
}
func makeStore(_ name: String) -> NotesStore {
    NotesStore(dir: root.appendingPathComponent(name).appendingPathComponent("Notes"))
}
func createNote(_ store: NotesStore, _ text: String) throws -> URL {
    let u = store.dir.appendingPathComponent("\(UUID().uuidString).md")
    try text.write(to: u, atomically: true, encoding: .utf8)
    return u
}

// Real move failure: Recently Deleted is a regular file, so no move can succeed there.
let blocked = makeStore("blocked-delete")
let original = try createNote(blocked, "Keep this note")
try fm.removeItem(at: blocked.trashDir)
try Data("blocked".utf8).write(to: blocked.trashDir)
expectFailure("A failed trash move must throw") { try blocked.delete(original) }
check(blocked.readRaw(original) == "Keep this note", "A failed trash move deleted the original")

// Successful delete is recoverable and a late editor autosave cannot resurrect it.
let store = makeStore("round-trip")
let note = try createNote(store, "---\npin: true\npriority: 2\n---\nOriginal body")
try store.saveExisting("Latest editor text", to: note)
check(store.read(note) == "Latest editor text", "Autosave failed to persist edited text")
check(store.readMeta(note).pin && store.readMeta(note).priority == 2, "Autosave dropped metadata")
try store.delete(note)
check(!fm.fileExists(atPath: note.path), "Delete left the live note behind")
expectFailure("A delayed save must fail after deletion") { try store.saveExisting("Stale editor text", to: note) }
check(!fm.fileExists(atPath: note.path), "Delayed save recreated a deleted note")
let deleted = store.trashedAll()
check(deleted.count == 1 && store.read(deleted[0]) == "Latest editor text", "Trash lost the saved editor text")
let restored = try store.restore(deleted[0])
check(store.read(restored) == "Latest editor text" && store.trashedAll().isEmpty, "Restore failed to preserve text")

// Restore cannot silently lose a note if the destination becomes unavailable.
let blockedRestore = makeStore("blocked-restore")
let restoreNote = try createNote(blockedRestore, "Restore me")
try blockedRestore.delete(restoreNote)
let retainedTrash = blockedRestore.trashedAll()[0]
try fm.removeItem(at: blockedRestore.dir)
try Data("blocked".utf8).write(to: blockedRestore.dir)
expectFailure("Failed restore must throw") { _ = try blockedRestore.restore(retainedTrash) }
check(blockedRestore.readRaw(retainedTrash) == "Restore me", "Failed restore removed the recovery copy")

// Read errors cannot be interpreted as blank or overwritten by an autosave.
let invalid = store.dir.appendingPathComponent("invalid-utf8.md")
let invalidBytes = Data([0xff, 0xfe, 0xfd])
try invalidBytes.write(to: invalid)
check(!store.isUndecoratedBlank(invalid), "Unreadable note was classified as blank")
expectFailure("Unreadable note must refuse an editor overwrite") { try store.saveExisting("replacement", to: invalid) }
let unchanged = try Data(contentsOf: invalid)
check(unchanged == invalidBytes, "Unreadable note was overwritten")
var rejectedWrites = 0
store.onWriteError = { _ in rejectedWrites += 1 }
check(!store.writeMeta(NoteMeta(pin: true), to: invalid), "Metadata mutation should reject unreadable content")
check(!store.write("replacement", to: invalid), "Import should reject unreadable existing content")
let stillUnchanged = try Data(contentsOf: invalid)
check(stillUnchanged == invalidBytes && rejectedWrites == 2, "Rejected writes must keep bytes and report failures")
let blank = try createNote(store, " \n\t")
let decorated = try createNote(store, "---\npin: true\n---\n")
check(store.isUndecoratedBlank(blank), "Plain empty scratch note should be reusable")
check(!store.isUndecoratedBlank(decorated), "Decorated blank note should be retained")

// ============================================================================
// 0.3 — frontmatter passthrough: hand-added keys, comments and line endings survive every save.
// ============================================================================
func writeRaw(_ store: NotesStore, _ raw: String) throws -> URL { try createNote(store, raw) }
let fmStore = makeStore("frontmatter")

// Unknown keys, a YAML list, a comment and a blank line are kept verbatim and in order while a known key changes.
let obsidian = try writeRaw(fmStore, "---\ntags: [work, ideas]\n# my comment\npin: true\naliases:\n  - Scratch\n\ncreated: 2026-01-02\n---\nBody line\n")
var obsMeta = fmStore.readMeta(obsidian)
check(obsMeta.pin, "Known key beside unknown keys must still parse")
obsMeta.pin = false; obsMeta.order = 3
check(fmStore.writeMeta(obsMeta, to: obsidian), "Metadata write failed")
check(fmStore.readRaw(obsidian) == "---\ntags: [work, ideas]\n# my comment\naliases:\n  - Scratch\n\ncreated: 2026-01-02\norder: 3\n---\nBody line\n",
      "Unknown frontmatter lines must survive a metadata change in place; got: \(fmStore.readRaw(obsidian).debugDescription)")
try fmStore.saveExisting("Edited body", to: obsidian)
check(fmStore.readRaw(obsidian).hasPrefix("---\ntags: [work, ideas]\n") && fmStore.read(obsidian) == "Edited body", "An autosave must keep hand-added keys")

// A save that changes nothing is byte-for-byte identical, even where Jot would spell a value differently.
let spelled = "---\npin: True\ntextColor: '#fff'\nreminder: 2026-07-15T09:00:00Z\n---\nText\n"
let spelledURL = try writeRaw(fmStore, spelled)
try fmStore.saveExisting("Text\n", to: spelledURL)
check(fmStore.readRaw(spelledURL) == spelled, "An unchanged save must not rewrite the author's frontmatter spelling; got: \(fmStore.readRaw(spelledURL).debugDescription)")

// CRLF files: the closing fence is recognised and the line endings are kept.
let crlf = try writeRaw(fmStore, "---\r\npin: true\r\ntags: [x]\r\n---\r\nBody\r\nline two")
check(fmStore.readMeta(crlf).pin && fmStore.read(crlf) == "Body\r\nline two", "A CRLF note's frontmatter must close and its body stay intact")
try fmStore.saveExisting("New\r\nbody", to: crlf)
check(fmStore.readRaw(crlf) == "---\r\npin: true\r\ntags: [x]\r\n---\r\nNew\r\nbody", "A CRLF note must keep CRLF frontmatter; got: \(fmStore.readRaw(crlf).debugDescription)")

// Nested keys are the author's, not Jot's: an indented `pin:` is never interpreted or rewritten.
let nested = try writeRaw(fmStore, "---\nmeta:\n  pin: yes\n---\nBody\n")
check(!fmStore.readMeta(nested).pin, "An indented key must not be read as Jot's pin")
try fmStore.saveExisting("Body 2\n", to: nested)
check(fmStore.readRaw(nested) == "---\nmeta:\n  pin: yes\n---\nBody 2\n", "Nested YAML must pass through untouched")

// A note whose only content is unknown frontmatter is not a blank scratch note (the sweep must never delete it).
let tagsOnly = try writeRaw(fmStore, "---\ntags: [keep]\n---\n")
check(!fmStore.isUndecoratedBlank(tagsOnly), "A note carrying hand-added frontmatter must never be swept as blank")

// Legacy keys Jot no longer shows (priority, textColor, rtfMode) are still preserved.
let legacy = try writeRaw(fmStore, "---\npriority: 2\ntextColor: \"#FF6B6B\"\nrtfMode: true\n---\nTWVzc2FnZQ==")
var legacyMeta = fmStore.readMeta(legacy)
legacyMeta.pin = true
_ = fmStore.writeMeta(legacyMeta, to: legacy)
check(fmStore.readRaw(legacy) == "---\npriority: 2\ntextColor: \"#FF6B6B\"\nrtfMode: true\npin: true\n---\nTWVzc2FnZQ==", "Legacy keys must survive; got: \(fmStore.readRaw(legacy).debugDescription)")

// Clearing every Jot key from a note that has nothing else removes the fence entirely (as before).
let onlyPin = try writeRaw(fmStore, "---\npin: true\n---\nBody\n")
var onlyPinMeta = fmStore.readMeta(onlyPin); onlyPinMeta.pin = false
_ = fmStore.writeMeta(onlyPinMeta, to: onlyPin)
check(fmStore.readRaw(onlyPin) == "Body\n", "A note left with no frontmatter keys must drop the empty fence; got: \(fmStore.readRaw(onlyPin).debugDescription)")


// ============================================================================
// 0.3 — NoteLibrary: the GOTCHAS-documented ordering and housekeeping rules, as pure functions.
// ============================================================================
func entry(_ name: String, pin: Bool = false, order: Int = 0, age: TimeInterval) -> NoteLibrary.Entry {
    NoteLibrary.Entry(url: URL(fileURLWithPath: "/notes/\(name).md"), pin: pin, order: order, modified: Date(timeIntervalSince1970: 1_000_000 - age))
}
func names(_ urls: [URL]) -> [String] { urls.map { $0.deletingPathExtension().lastPathComponent } }

// Pinned first; then never-dragged notes newest-first; then dragged notes by ascending position.
let sortedNames = names(NoteLibrary.sorted([
    entry("old-unordered", age: 500),
    entry("dragged-2", order: 2, age: 10),
    entry("pinned-old", pin: true, age: 900),
    entry("new-unordered", age: 5),
    entry("dragged-1", order: 1, age: 700),
    entry("pinned-ordered", pin: true, order: 1, age: 50),
]))
check(sortedNames == ["pinned-old", "pinned-ordered", "new-unordered", "old-unordered", "dragged-1", "dragged-2"],
      "Sort order must be pins, then unordered newest-first, then dragged by position; got \(sortedNames)")
// Regression (GOTCHAS 2026-09-03): after one drag numbers every note, a brand-new note still lands on top.
let afterDrag = names(NoteLibrary.sorted([entry("a", order: 1, age: 300), entry("b", order: 2, age: 200), entry("brand-new", age: 1)]))
check(afterDrag.first == "brand-new", "A note created after a drag must sort above the dragged ones")
// Equal keys fall back to the path, so the list never shuffles between launches.
check(names(NoteLibrary.sorted([entry("z", age: 1), entry("a", age: 1)])) == ["a", "z"], "Ties must break deterministically")

// Filtering: every term must match, case- and diacritic-insensitively, in title or body.
check(NoteLibrary.matches("Café notes\nbuy croissants", query: "cafe"), "Diacritics must not matter")
check(NoteLibrary.matches("Meeting NOTES", query: "notes meeting"), "Terms match in any order, any case")
check(!NoteLibrary.matches("Meeting notes", query: "meeting budget"), "Every term must match")
check(NoteLibrary.matches("anything", query: "   "), "A blank query matches everything")

// Housekeeping: which blank notes are strays, and which one is worth reusing.
let urlsOnDisk = ["blank-open", "blank-kept", "blank-stray", "real"].map { URL(fileURLWithPath: "/notes/\($0).md") }
let blankSet: Set<String> = ["blank-open", "blank-kept", "blank-stray"]
let isBlank: (URL) -> Bool = { blankSet.contains($0.deletingPathExtension().lastPathComponent) }
let spared: Set<URL> = [urlsOnDisk[0], urlsOnDisk[1]]
check(names(NoteLibrary.strays(in: urlsOnDisk, spared: spared, isBlank: isBlank)) == ["blank-stray"],
      "Only blank notes that are neither kept nor open in a window are strays")
check(NoteLibrary.reusableBlank(in: urlsOnDisk, inWindows: [urlsOnDisk[0]], isBlank: isBlank) == urlsOnDisk[1],
      "The reusable blank note is the first one not open in its own window")
check(NoteLibrary.reusableBlank(in: [urlsOnDisk[3]], inWindows: [], isBlank: isBlank) == nil, "No blank note → nothing to reuse")

// ============================================================================
// 0.3 — hotkey defaults: a global shortcut is muscle memory, so a default change must never move it.
// ============================================================================
let fresh = HotkeyDefaults.resolve(storedKeyCode: nil, storedCarbon: nil, storedDisplay: nil, hasShownWelcome: false)
check(fresh == HotkeyDefaults.Resolved(keyCode: 38, carbon: 2048 | 256, display: "⌥⌘J", persist: true), "A new install gets ⌥⌘J and writes it down")
let veteran = HotkeyDefaults.resolve(storedKeyCode: nil, storedCarbon: nil, storedDisplay: nil, hasShownWelcome: true)
check(veteran == HotkeyDefaults.Resolved(keyCode: 38, carbon: 4096, display: "⌃J", persist: true), "An existing user who never customised keeps ⌃J, written down")
let custom = HotkeyDefaults.resolve(storedKeyCode: 40, storedCarbon: 2048 | 256, storedDisplay: "⌥⌘K", hasShownWelcome: true)
check(custom == HotkeyDefaults.Resolved(keyCode: 40, carbon: 2048 | 256, display: "⌥⌘K", persist: false), "A stored shortcut always wins and is never rewritten")
let partial = HotkeyDefaults.resolve(storedKeyCode: 40, storedCarbon: nil, storedDisplay: nil, hasShownWelcome: false)
check(partial.keyCode == 40 && partial.carbon == 4096 && !partial.persist, "A partly stored shortcut fills the gaps from the legacy default")
// The second launch of a new install must not look like a veteran: persisting at first launch is what prevents that.
let secondLaunch = HotkeyDefaults.resolve(storedKeyCode: fresh.keyCode, storedCarbon: fresh.carbon, storedDisplay: fresh.display, hasShownWelcome: true)
check(secondLaunch.display == "⌥⌘J" && !secondLaunch.persist, "A new install keeps ⌥⌘J on its second launch")

// ============================================================================
// 0.3 — fixtures: the disposable library the walkthrough and tests share.
// ============================================================================
let fixtureNow = Date(timeIntervalSince1970: 1_800_000_000)
let fixtureRoot = root.appendingPathComponent("fixtures")
let fixtureStore = NotesStore(dir: fixtureRoot.appendingPathComponent("Notes"), trashDir: fixtureRoot.appendingPathComponent("RecentlyDeleted"))
let installed = try Fixtures.install(into: fixtureStore.dir, trash: fixtureStore.trashDir, now: fixtureNow)
check(installed.count == Fixtures.library(now: fixtureNow).count && fixtureStore.all().count == installed.count, "Every fixture note is written")
check(fixtureStore.trashedAll().count == Fixtures.trashLibrary().count, "Trash fixtures are written")
let bigFixture = installed.first { $0.lastPathComponent == Fixtures.id(10) + ".md" }!
let bigBytes = try Data(contentsOf: bigFixture).count
check(bigBytes >= 200_000, "The big fixture is at least 200 KB")
let longFixture = installed.first { $0.lastPathComponent == Fixtures.id(11) + ".md" }!
check(!fixtureStore.read(longFixture).contains("\n") && fixtureStore.read(longFixture).utf8.count >= 50_000, "The long-line fixture is one 50 KB paragraph")
let legacyFixture = installed.first { $0.lastPathComponent == Fixtures.id(8) + ".md" }!
check(fixtureStore.readMeta(legacyFixture).rtfMode && Data(base64Encoded: fixtureStore.read(legacyFixture)) != nil, "The legacy fixture is a base64 RTF body with rtfMode")
let foreignFixture = installed.first { $0.lastPathComponent == Fixtures.id(7) + ".md" }!
check(fixtureStore.readMeta(foreignFixture).hasForeignContent, "The Obsidian-style fixture carries keys Jot doesn't own")
let mtime = (try fixtureRoot.appendingPathComponent("Notes").appendingPathComponent(Fixtures.id(1) + ".md").resourceValues(forKeys: [.contentModificationDateKey])).contentModificationDate!
check(abs(mtime.timeIntervalSince(fixtureNow.addingTimeInterval(-120))) < 1, "Fixture modification dates are stamped relative to now")


// ============================================================================
// 1.2 — legacy rich-text notes convert to Markdown safely: backup first, never lose a byte.
// ============================================================================
let stampDate = Date(timeIntervalSince1970: 1_700_000_000)
let longAgo = Date(timeIntervalSince1970: 1_600_000_000)
let rtfStore = makeStore("legacy-rtf")
let legacyRaw = "---\ntags: [keep]\nrtfMode: true\npin: true\n---\n" + Fixtures.legacyRTFBase64
let legacyNote = try createNote(rtfStore, legacyRaw)
try fm.setAttributes([.modificationDate: longAgo], ofItemAtPath: legacyNote.path)
let plainRaw = "---\npin: true\n---\nJust markdown, **untouched**\n"
let plainNote = try createNote(rtfStore, plainRaw)
let rtfReport = LegacyRTF.migrate(rtfStore, now: stampDate)
// (compare by name: the temp folder is /var/… on one side and /private/var/… on the other)
check(rtfReport.converted.map { $0.lastPathComponent } == [legacyNote.lastPathComponent] && rtfReport.failed.isEmpty, "The legacy note converts and nothing fails")
let migrated = rtfStore.readRaw(legacyNote)
check(migrated.hasPrefix("---\ntags: [keep]\npin: true\n---\n") && !rtfStore.readMeta(legacyNote).rtfMode,
      "rtfMode is dropped and every other frontmatter line kept; got \(migrated.debugDescription)")
check(rtfStore.read(legacyNote).contains("Legacy rich text with **bold** words.") && rtfStore.read(legacyNote).contains("Second line."),
      "The body becomes Markdown with the bold run marked up; got \(rtfStore.read(legacyNote).debugDescription)")
let backupRunFolders = try fm.contentsOfDirectory(at: LegacyRTF.backupRoot(for: rtfStore), includingPropertiesForKeys: nil)
check(backupRunFolders.count == 1, "One timestamped backup folder per run")
let backedUp = try Data(contentsOf: backupRunFolders[0].appendingPathComponent(legacyNote.lastPathComponent))
check(backedUp == Data(legacyRaw.utf8), "The backup is byte-identical to the original file")
check(fm.fileExists(atPath: backupRunFolders[0].appendingPathComponent(legacyNote.deletingPathExtension().lastPathComponent + ".rtf").path),
      "A plain .rtf copy sits next to the backup")
let keptDate = (try legacyNote.resourceValues(forKeys: [.contentModificationDateKey])).contentModificationDate!
check(abs(keptDate.timeIntervalSince(longAgo)) < 1, "The note keeps its modification date (the list order must not move)")
check(rtfStore.readRaw(plainNote) == plainRaw, "A Markdown note is never touched")
check(LegacyRTF.migrate(rtfStore, now: stampDate.addingTimeInterval(60)).isEmpty, "Migrating again does nothing")

// Failures leave the note exactly as it was, and create no backup.
let badStore = makeStore("legacy-rtf-bad")
let undecodable = "---\nrtfMode: true\n---\n%%% not base64 %%%"
let undecodableNote = try createNote(badStore, undecodable)
let badReport = LegacyRTF.migrate(badStore, now: stampDate)
check(badReport.converted.isEmpty && badReport.failed.count == 1 && badStore.readRaw(undecodableNote) == undecodable, "An undecodable body is reported and left untouched")
check(!fm.fileExists(atPath: LegacyRTF.backupRoot(for: badStore).path), "No backup folder for a note that could not be read")
let blockedStore = makeStore("legacy-rtf-blocked")
let blockedRaw = "---\nrtfMode: true\n---\n" + Fixtures.legacyRTFBase64
let blockedNote = try createNote(blockedStore, blockedRaw)
try fm.createDirectory(at: blockedStore.dir.deletingLastPathComponent(), withIntermediateDirectories: true)
try Data("a file where the Backups folder should be".utf8).write(to: blockedStore.dir.deletingLastPathComponent().appendingPathComponent("Backups"))
let blockedReport = LegacyRTF.migrate(blockedStore, now: stampDate)
check(blockedReport.converted.isEmpty && blockedReport.failed.count == 1 && blockedStore.readRaw(blockedNote) == blockedRaw, "If the backup cannot be written, the note is not converted")

// The converter: headings from font size, emphasis kept outside whitespace, links, bold-italic.
let bodyFont = NSFont.systemFont(ofSize: 13)
let boldFont = NSFont.boldSystemFont(ofSize: 13)
let italicFont = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
let boldItalicFont = NSFontManager.shared.convert(boldFont, toHaveTrait: .italicFontMask)
let sample = NSMutableAttributedString()
sample.append(NSAttributedString(string: "Title\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 26)]))
sample.append(NSAttributedString(string: "Some ", attributes: [.font: bodyFont]))
sample.append(NSAttributedString(string: " bold ", attributes: [.font: boldFont]))
sample.append(NSAttributedString(string: "and", attributes: [.font: bodyFont]))
sample.append(NSAttributedString(string: " italic", attributes: [.font: italicFont]))
sample.append(NSAttributedString(string: " both ", attributes: [.font: boldItalicFont]))
sample.append(NSAttributedString(string: "link", attributes: [.font: bodyFont, .link: URL(string: "https://example.com")!]))
sample.append(NSAttributedString(string: ".\n", attributes: [.font: bodyFont]))
let expectedMarkdown = "# Title\nSome  **bold** and *italic* ***both*** [link](https://example.com).\n"
check(LegacyRTF.toMarkdown(sample) == expectedMarkdown, "Headings, emphasis, links convert; got \(LegacyRTF.toMarkdown(sample).debugDescription)")
check(LegacyRTF.toMarkdown(NSAttributedString(string: "")) == "", "An empty document converts to nothing")

runMarkdownScannerChecks()
runMarkdownEditChecks()

// ---- delete + Undo: the note comes back under its own name, with its content and its old modification date --------------------------------
do {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("jot-undo-\(UUID().uuidString)")
    let notesDir = root.appendingPathComponent("Notes"), trashDir = root.appendingPathComponent("Trash")
    try? FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
    let store = NotesStore(dir: notesDir, trashDir: trashDir)
    let original = notesDir.appendingPathComponent("note-a.md")
    let content = "---\npin: true\nreminder: 2030-01-01T09:00:00Z\n---\n# Keep me\nbody\n"
    try? content.write(to: original, atomically: true, encoding: .utf8)
    let old = Date(timeIntervalSince1970: 1_700_000_000)
    try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: original.path)
    let before = store.modificationDate(original)
    var trashURL: URL?
    do { trashURL = try store.delete(original) } catch { check(false, "delete threw \(error)") }
    check(trashURL != nil && !FileManager.default.fileExists(atPath: original.path) && trashURL.map { FileManager.default.fileExists(atPath: $0.path) } == true, "delete reports where the note went and removes the original")
    // The name gets taken while the note is in Recently Deleted.
    let taken = notesDir.appendingPathComponent("note-a.md")
    try? "someone else".write(to: taken, atomically: true, encoding: .utf8)
    if let t = trashURL, let back = try? store.restore(t, as: original, modified: before) {
        check(back.lastPathComponent == "note-a-1.md" && (try? String(contentsOf: back, encoding: .utf8)) == content, "Undo into a taken name uses the next free one and keeps the content byte for byte (\(back.lastPathComponent))")
        check(store.modificationDate(back) == before, "Undo restores the note's old modification date, so it keeps its place in the list")
    } else { check(false, "restore threw") }
    try? FileManager.default.removeItem(at: taken)
    // And into a free name:
    let second = notesDir.appendingPathComponent("note-b.md")
    try? "b".write(to: second, atomically: true, encoding: .utf8)
    if let t = try? store.delete(second), let back = try? store.restore(t, as: second, modified: old) {
        check(back.lastPathComponent == "note-b.md" && store.modificationDate(back) == old, "Undo into a free name restores the same name and date")
    } else { check(false, "second delete/restore threw") }
    try? FileManager.default.removeItem(at: root)
}

// ---- saving unchanged text doesn't touch the file (visiting a note must not reorder the list) ----------------------------------------
do {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("jot-nosave-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = NotesStore(dir: root, trashDir: root.appendingPathComponent("Trash"))
    let u = root.appendingPathComponent("n.md")
    try? "---\npin: true\n---\nsame body".write(to: u, atomically: true, encoding: .utf8)
    let old = Date(timeIntervalSince1970: 1_600_000_000)
    try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: u.path)
    try? store.saveExisting("same body", to: u)
    check(store.modificationDate(u) == old, "saving identical text leaves the file's modification date alone")
    try? store.saveExisting("changed body", to: u)
    let after = (try? String(contentsOf: u, encoding: .utf8)) ?? "<unreadable>"
    check((store.modificationDate(u) ?? old) > old && after == "---\npin: true\n---\nchanged body", "saving changed text writes it (and keeps the frontmatter): \(after.debugDescription)")
    try? FileManager.default.removeItem(at: root)
}

// ---- search: case-, accent- and width-insensitive; every word must appear -----------------------------------------------------------------
do {
    func finds(_ note: String, _ query: String) -> Bool { NoteLibrary.matches(folded: NoteLibrary.fold(note), query: query) }
    check(finds("Résumé — first draft\nbody", "resume"), "search ignores accents")
    check(finds("Résumé — first draft\nbody", "RESUME Draft"), "search ignores case and takes several words in any order")
    check(!finds("Résumé — first draft", "resume zzz"), "every word of the query must appear")
    check(finds("anything", "") && finds("anything", "   "), "an empty query matches every note")
    check(finds("ｶﾀｶﾅ memo", "カタカナ"), "search ignores full-/half-width forms")
    check(finds("日本語のメモ 🎉", "メモ"), "search finds Japanese")
    check(finds("naïve café", "naive cafe"), "search folds several accents")
    check(!finds("alpha beta", "gamma"), "no match for an absent word")
}

// ---- list diff: the removals and insertions always turn the old list into the new one ---------------------------------------------------------
do {
    var seed: UInt64 = 0x1234_5678_9ABC_DEF0
    func random(_ n: Int) -> Int { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return Int(seed % UInt64(n)) }
    var bad = 0
    for _ in 0..<1500 {
        let universe = Array(0..<14)
        var g1 = SeededGenerator(seed: UInt64(random(1_000_000) + 1)), g2 = SeededGenerator(seed: UInt64(random(1_000_000) + 1))
        let old = universe.filter { _ in random(3) != 0 }.shuffled(using: &g1)
        let new = universe.filter { _ in random(3) != 0 }.shuffled(using: &g2)
        guard let change = ListDiff.compute(old: old, new: new) else { bad += 1; continue }
        if ListDiff.apply(change, to: old, producing: new) != new { bad += 1; fputs("list diff broke: \(old) → \(new): \(change)\n", stderr) }
        if change.removed.count + change.inserted.count > old.count + new.count { bad += 1 }
    }
    check(bad == 0, "the list diff turns the old list into the new one in \(1500) random cases (\(bad) failures)")
    let c = ListDiff.compute(old: ["a", "b", "c"], new: ["a", "b", "c"])
    check(c == ListDiff.Change(removed: [], inserted: []), "an unchanged list has an empty diff")
    let add1 = ListDiff.compute(old: ["a", "b"], new: ["n", "a", "b"])
    check(add1 == ListDiff.Change(removed: [], inserted: [0]), "a new note at the top is one insertion: \(String(describing: add1))")
    let del1 = ListDiff.compute(old: ["a", "b", "c"], new: ["a", "c"])
    check(del1 == ListDiff.Change(removed: [1], inserted: []), "a deleted note is one removal: \(String(describing: del1))")
    check(ListDiff.compute(old: Array(0..<2000), new: Array((0..<2000).reversed())) == nil, "lists too large to diff cheaply say so (the caller reloads)")
}
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 { state &+= 0x9E3779B97F4A7C15; var z = state; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
}

// ---- the welcome note --------------------------------------------------------------------------------------------------------------------------
do {
    let body = WelcomeNote.body(hotkey: "⌥⌘J")
    check(MarkdownPlain.title(body) == "Welcome to Jot", "the welcome note's title is plain text")
    check(body.contains("Press ⌥⌘J anywhere") && !body.contains("⌃J"), "the welcome note names the shortcut the person has")
    check(WelcomeNote.body(hotkey: "⌃J").contains("Press ⌃J anywhere"), "…whatever it is")
    check(MarkdownScanner.blocks(body).filter { if case .task = $0.kind { return true }; return false }.count == 3, "the welcome note has three checklist items to click")
    check(MarkdownPlain.snippet(body).hasPrefix("Press ⌥⌘J"), "its sidebar snippet is the first sentence")
}

// ---- Markdown → HTML (Save As ▸ HTML) ---------------------------------------------------------------------------------------------------------
do {
    func html(_ md: String, _ expected: String) {
        let got = MarkdownHTML.body(md)
        check(got == expected, "HTML of \(md.debugDescription): expected \(expected.debugDescription), got \(got.debugDescription)")
    }
    html("# Title", "<h1>Title</h1>\n")
    html("Hello **bold** and *em* and ~~gone~~ and `a<b`", "<p>Hello <strong>bold</strong> and <em>em</em> and <del>gone</del> and <code>a&lt;b</code></p>\n")
    html("one\ntwo\n\nthree", "<p>one<br>\ntwo</p>\n<p>three</p>\n")
    html("- a\n- b", "<ul>\n<li>a</li>\n<li>b</li></ul>\n")
    html("1. a\n2. b", "<ol>\n<li>a</li>\n<li>b</li></ol>\n")
    html("- a\n  - nested\n- b", "<ul>\n<li>a<ul>\n<li>nested</li></ul>\n</li>\n<li>b</li></ul>\n")
    html("- [ ] todo\n- [x] done", "<ul>\n<li class=\"task\">☐ todo</li>\n<li class=\"task\">☑ done</li></ul>\n")
    html("> quoted\n> more", "<blockquote>quoted<br>\nmore</blockquote>\n")
    html("---", "<hr>\n")
    html("```swift\nlet x = 1 < 2\n```", "<pre><code class=\"language-swift\">let x = 1 &lt; 2</code></pre>\n")
    html("[docs](https://example.com/a?b=1&c=2)", "<p><a href=\"https://example.com/a?b=1&amp;c=2\">docs</a></p>\n")
    html("[bad](javascript:alert(1)) ![img](http://x/y.png)", "<p>bad img</p>\n")                      // nothing that could run or load
    html("| a | b |\n|---|---|\n| 1 | 2 |", "<table>\n<tr><th>a</th><th>b</th></tr>\n<tr><td>1</td><td>2</td></tr>\n</table>\n")
    html("a <script>alert(1)</script> & \"q\"", "<p>a &lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;q&quot;</p>\n")
    html("snake_case and 2 * 3 * 4 and \\*not em\\*", "<p>snake_case and 2 * 3 * 4 and *not em*</p>\n")
    html("***both***", "<p><em><strong>both</strong></em></p>\n")
    check(MarkdownHTML.document("# T", title: "T <x>").contains("<title>T &lt;x&gt;</title>") && MarkdownHTML.document("# T", title: "T").contains("<h1>T</h1>"), "the HTML document wraps the body and escapes the title")
}

// ---- what to say when a send fails ------------------------------------------------------------------------------------------------------------
do {
    check(SendErrors.appleNotes(code: -1743).opensAutomationSettings && SendErrors.appleNotes(code: -1743).text.contains("allowed to control Notes"), "a denied Notes send points at the Automation settings")
    check(!SendErrors.appleNotes(code: -600).opensAutomationSettings && SendErrors.appleNotes(code: -600).text.contains("isn't running"), "Notes not running says so")
    check(SendErrors.appleNotes(code: -1744).text.contains("allow it") && SendErrors.appleNotes(code: 12345).text.contains("12345"), "other Notes errors keep their number")
    check(SendErrors.stickies(code: 1002, message: "").opensAccessibilitySettings && SendErrors.stickies(code: 0, message: "System Events got an error: Jot is not allowed to send keystrokes.").opensAccessibilitySettings, "Stickies' Accessibility denial is recognised however AppleScript spells it")
    check(!SendErrors.stickies(code: 5, message: "").opensAccessibilitySettings && SendErrors.stickies(code: 5, message: "").text.contains("error 5"), "any other Stickies error is reported with its number")
}

// ---- sidebar geometry: a sweep over pad widths and saved sidebar widths -------------------------------------------------------------------
do {
    var failures = 0
    for W in stride(from: 360.0, through: 1400.0, by: 8.0) {
        for saved in [120.0, 180.0, 210.0, 312.0, 500.0, 900.0] {
            for shown in [true, false] {
                let g = SidebarGeometry.compute(width: CGFloat(W), bodyHeight: 300, bottom: 42, shown: shown, savedWidth: CGFloat(saved))
                let docked = W >= 560
                var ok = g.docked == docked
                if docked {
                    ok = ok && (!shown || g.editor.width >= 300) && g.list.width >= 180 && g.scrim == .zero
                    ok = ok && (shown ? g.editor.minX == g.list.width + 4 : g.editor.minX == 0 && g.editor.width == CGFloat(W))
                } else {
                    ok = ok && g.editor.width == CGFloat(W) && g.editor.minX == 0            // a drawer never moves or squeezes the text
                    ok = ok && g.list.width <= 280 && g.list.width >= 200 && g.list.width <= CGFloat(W) - 56
                    ok = ok && (shown ? g.list.minX == 0 && g.scrim.minX == g.list.width && g.scrim.maxX == CGFloat(W) : g.list.maxX < 0)   // hidden: fully off to the left
                }
                ok = ok && g.list.minY == 42 && g.editor.minY == 42 && g.editor.height == 300
                if !ok { failures += 1; fputs("sidebar geometry broke at width \(W), saved \(saved), shown \(shown): \(g)\n", stderr) }
            }
        }
    }
    check(failures == 0, "sidebar geometry holds for every pad width and saved sidebar width (\(failures) failures)")
}

// ---- relative times (en_US, UTC, a fixed "now": Wednesday 2026-09-30 15:00) -----------------------------------------------------------
do {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    let us = Locale(identifier: "en_US")
    let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 15, minute: 0))!
    func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 9, _ mi: Int = 5) -> Date { cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))! }
    func rel(_ date: Date) -> String { RelativeTime.short(date, now: now, calendar: cal, locale: us).replacingOccurrences(of: "\u{202F}", with: " ") }   // newer ICU puts a narrow no-break space before PM
    check(rel(at(2026, 9, 30, 14, 59)) == "2:59 PM", "relative time: earlier today shows the clock (\(rel(at(2026, 9, 30, 14, 59))))")
    check(rel(at(2026, 9, 29)) == "Yesterday", "relative time: yesterday (\(rel(at(2026, 9, 29))))")
    check(rel(at(2026, 9, 27)) == "Sun", "relative time: within the week shows the weekday (\(rel(at(2026, 9, 27))))")
    check(rel(at(2026, 9, 23)) == "Sep 23", "relative time: a week ago shows month and day (\(rel(at(2026, 9, 23))))")
    check(rel(at(2026, 2, 3)) == "Feb 3", "relative time: earlier this year (\(rel(at(2026, 2, 3))))")
    check(rel(at(2025, 12, 31)) == "12/31/25", "relative time: last year uses the short date (\(rel(at(2025, 12, 31))))")
    check(rel(at(2026, 9, 30, 15, 30)) == "3:30 PM", "relative time: a clock slightly ahead is treated as now (\(rel(at(2026, 9, 30, 15, 30))))")
}
print("Jot storage, ordering and migration checks: \(checks) passed")
