import Cocoa
import Carbon
import PDFKit

// ============================================================================
// Runtime, isolation and the preview walkthrough.
//
// `Jot --jot-preview` runs the real UI against a disposable world: its own defaults suite, a
// temporary notes folder filled with fixtures, a private pasteboard, and no hotkey, login item,
// status item, notifications, Apple Notes/Stickies traffic or focus stealing. It never
// touches the real notes, preferences, reminders or clipboard. `--jot-preview-snapshots <dir>`
// runs the scripted walkthrough, writes PNGs + walkthrough.txt, and exits non-zero on any failure.
// Run it through `./preview.sh`, which also points HOME at a throwaway folder.
// ============================================================================

enum Runtime {
    static let isPreview = CommandLine.arguments.contains("--jot-preview")
    static let bundleID = "com.jacob.jot"
    static let previewDomain = bundleID + ".preview"
    /// `--jot-preview-snapshots <dir>`: run the scripted walkthrough, write PNGs there, then quit.
    static let snapshotDirectory: URL? = {
        let args = CommandLine.arguments
        guard isPreview, let i = args.firstIndex(of: "--jot-preview-snapshots"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }()
    /// `--jot-preview-seconds <n>`: quit a plain preview by itself (clean-launch checks).
    static let previewLifetime: TimeInterval? = {
        let args = CommandLine.arguments
        guard isPreview, let i = args.firstIndex(of: "--jot-preview-seconds"), i + 1 < args.count else { return nil }
        return TimeInterval(args[i + 1])
    }()

    static let previewRoot = FileManager.default.temporaryDirectory.appendingPathComponent(previewDomain, isDirectory: true)
    static var notesDirectory: URL { isPreview ? previewRoot.appendingPathComponent("Notes", isDirectory: true) : jotDir }
    static var trashDirectory: URL { isPreview ? previewRoot.appendingPathComponent("RecentlyDeleted", isDirectory: true) : jotDir.deletingLastPathComponent().appendingPathComponent("RecentlyDeleted") }
    /// The glass can't be captured by `cacheDisplay`, so snapshot runs draw a solid stand-in.
    static var opaqueChrome: Bool { snapshotDirectory != nil }
    /// A preview must never read or clobber the real clipboard.
    static var pasteboard: NSPasteboard { isPreview ? NSPasteboard(name: NSPasteboard.Name(previewDomain)) : .general }

    /// Wipes any leftovers, installs fixtures and seeds the private defaults. Must run before `AppDelegate()`.
    static func prepareIfPreview() {
        guard isPreview else { return }
        resetPreviewState()
        // (No seeded prefs: a preview launches as a NEW INSTALL — shortcut ⌥⌘J, never welcomed, nothing registered at login.)
        do { try Fixtures.install(into: notesDirectory, trash: trashDirectory) }
        catch { FileHandle.standardError.write(Data("preview fixtures failed: \(error)\n".utf8)); exit(2) }
    }

    static func resetPreviewState() {
        guard isPreview else { return }
        UserDefaults(suiteName: previewDomain)?.removePersistentDomain(forName: previewDomain)
        NSPasteboard(name: NSPasteboard.Name(previewDomain)).clearContents()
        try? FileManager.default.removeItem(at: previewRoot)
    }
}

/// Things a preview intercepted instead of doing (notifications, sends, alerts). Production never records.
enum PreviewLog {
    private(set) static var events: [(kind: String, detail: String)] = []
    static func record(_ kind: String, _ detail: String = "") { events.append((kind, detail)) }
    static func count(_ kind: String) -> Int { events.filter { $0.kind == kind }.count }
}

/// Every Jot window. Snapshot runs park windows off-screen, so AppKit must not pull them back.
final class JotWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        Runtime.snapshotDirectory != nil ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

/// The translucent window background, with a solid stand-in that snapshot runs can capture.
final class GlassView: NSVisualEffectView {
    private let solid = NSBox()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .sidebar
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .vibrantDark)
        solid.boxType = .custom
        solid.borderWidth = 0
        solid.contentViewMargins = .zero
        solid.fillColor = NSColor(srgbRed: 0.15, green: 0.15, blue: 0.165, alpha: 1)
        solid.frame = bounds
        solid.autoresizingMask = [.width, .height]
        solid.isHidden = !Runtime.opaqueChrome
        addSubview(solid, positioned: .below, relativeTo: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

extension AppDelegate {
    /// Plain preview shows the pad on screen near the top centre (there is no status item to anchor to);
    /// snapshot runs park it off-screen so nothing ever appears on the owner's display.
    func positionForPreview() {
        var frame = dropdown.frame
        if Runtime.snapshotDirectory != nil {
            frame.origin = NSPoint(x: -4000, y: 200)
        } else if let vis = NSScreen.main?.visibleFrame {
            frame.origin = NSPoint(x: vis.midX - frame.width / 2, y: vis.maxY - frame.height - 12)
        }
        dropdown.setFrame(frame, display: false)
    }

    func startPreview() {
        if let dir = Runtime.snapshotDirectory { PreviewWalkthrough(app: self, directory: dir).run(); return }
        DispatchQueue.main.async { self.presentDropdown() }
        if let seconds = Runtime.previewLifetime {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        }
    }
}

// ============================================================================
// MARK: - Walkthrough: a scripted run of the real UI with fixtures, rendered to PNGs.
// `expect` is a hard check (any failure → non-zero exit). `probe` records an observation without
// failing — used for baseline measurements of known problems, later turned into `expect`s.
// ============================================================================

final class PreviewWalkthrough {
    private let app: AppDelegate
    private let directory: URL
    private var steps: [Step] = []
    private var log: [String] = []
    private var failures: [String] = []
    private var probes: [String] = []

    private enum Step {
        case after(TimeInterval, () -> Void)
        case until(TimeInterval, String, () -> Bool)
    }

    init(app: AppDelegate, directory: URL) { self.app = app; self.directory = directory }

    private func expect(_ condition: Bool, _ what: String) { condition ? log.append("ok: \(what)") : failures.append(what) }
    private func probe(_ name: String, _ observed: String) { probes.append("PROBE \(name): \(observed)") }
    private func add(_ delay: TimeInterval, _ action: @escaping () -> Void) { steps.append(.after(delay, action)) }

    // MARK: key-event helpers (a real key press is routed: window views → main menu → keyDown)
    private func key(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: app.dropdown.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }
    private func arrow(_ f: Int) -> String { String(UnicodeScalar(UInt32(f))!) }
    /// Returns who consumed the key, in AppKit's order.
    private func route(_ e: NSEvent) -> String {
        if app.dropdown.performKeyEquivalent(with: e) { return "a view's performKeyEquivalent" }
        if NSApp.mainMenu?.performKeyEquivalent(with: e) == true { return "the main menu" }
        let responder = app.dropdown.firstResponder
        responder?.keyDown(with: e)
        return "keyDown on \(responder.map { String(describing: type(of: $0)) } ?? "nothing")"
    }

    private func url(_ n: Int) -> URL { app.store.dir.appendingPathComponent(Fixtures.id(n) + ".md") }
    private func park(_ w: NSWindow, _ size: NSSize? = nil) {
        app.suppressMoveSave = true
        var f = w.frame
        f.origin = NSPoint(x: -4000, y: 200)
        if let size = size { f.size = size }
        w.setFrame(f, display: true)
        app.suppressMoveSave = false
    }

    // MARK: script
    func run() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let a = app
        let tv = a.textView!

        // --- isolation: hard checks -------------------------------------------------------------
        expect(Prefs.d !== UserDefaults.standard, "preferences use the private preview suite")
        expect(a.store.dir.path.hasPrefix(Runtime.previewRoot.path), "notes live under the temporary preview tree")
        expect(a.store.trashDir.path.hasPrefix(Runtime.previewRoot.path), "Recently Deleted lives under the temporary preview tree")
        expect(a.store.all().count >= Fixtures.library().count - 1, "fixture library installed (\(a.store.all().count) notes)")
        expect(NSApp.activationPolicy() == .accessory, "runs as an accessory app (no Dock icon, no menu bar)")

        // --- Jot 3: no network code, no RTF editing mode, legacy rich-text notes converted with a verified backup ----
        let legacyURL = url(8)
        expect(!a.store.readMeta(legacyURL).rtfMode && a.store.read(legacyURL).contains("**bold**"), "the legacy rich-text fixture was converted to Markdown at launch")
        let backups = (try? FileManager.default.contentsOfDirectory(at: LegacyRTF.backupRoot(for: a.store), includingPropertiesForKeys: nil)) ?? []
        let originalRaw = Fixtures.library().first { $0.id == Fixtures.id(8) }!.raw
        expect(backups.count == 1 && (try? Data(contentsOf: backups[0].appendingPathComponent(Fixtures.id(8) + ".md"))) == Data(originalRaw.utf8),
               "its byte-identical backup exists")
        expect(PreviewLog.count("rtf-migration") == 1, "the migration was announced exactly once")
        let allMenuTitles = (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }.map { $0.title } + a.listContextMenu().items.map { $0.title }
        expect(!allMenuTitles.contains("Rich Text Mode"), "no Rich Text Mode item remains in any menu")
        // Right-click ▸ Refresh pulls an edit made outside Jot into the docked editor.
        let click = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        expect(click.flatMap { a.textView.menu(for: $0) }?.items.contains { $0.title == "Refresh" } == true, "the editor's right-click menu offers Refresh")
        if let cur = a.current, !a.viewingTrash {
            let marker = "refresh-check-\(UUID().uuidString.prefix(6))"
            let raw = a.store.readRaw(cur)
            try? (raw + "\n" + marker).write(to: cur, atomically: true, encoding: .utf8)
            a.refreshActiveNote()
            expect(a.textView.string.contains(marker), "Refresh re-reads the note from disk")
            try? raw.write(to: cur, atomically: true, encoding: .utf8)
            a.refreshActiveNote()
        }
        // RTF is still an export format, now with the note's formatting (bold, headings) instead of plain text.
        let exportURL = Runtime.previewRoot.appendingPathComponent("export-check.rtf")
        do { try a.writeNote(Fixtures.tourBody, to: exportURL, ext: "rtf") } catch { failures.append("RTF export threw: \(error)") }
        if let data = try? Data(contentsOf: exportURL), let exported = NSAttributedString(rtf: data, documentAttributes: nil) {
            let ns = exported.string as NSString
            let boldAt = ns.range(of: "bold")
            let titleAt = ns.range(of: "Welcome to Jot")
            let boldFont = boldAt.location != NSNotFound ? exported.attribute(.font, at: boldAt.location, effectiveRange: nil) as? NSFont : nil
            let titleFont = titleAt.location != NSNotFound ? exported.attribute(.font, at: titleAt.location, effectiveRange: nil) as? NSFont : nil
            probe("RTF export details", "starts \(exported.string.prefix(40).debugDescription); title font \(titleFont.map { "\($0.fontName) \($0.pointSize)" } ?? "nil"); bold font \(boldFont.map { "\($0.fontName) \($0.pointSize)" } ?? "nil")")
            expect(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) == true && (titleFont?.pointSize ?? 0) > 16 && !exported.string.hasPrefix("#"),
                   "RTF export carries the note's formatting (bold run, large title, no # marker)")
        } else { failures.append("RTF export could not be read back") }
        try? FileManager.default.removeItem(at: exportURL)
        // Save As: every format writes; the PDF is paginated; a write that fails is reported, never swallowed.
        do {
            let folder = Runtime.previewRoot.appendingPathComponent("export-formats", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for ext in ["txt", "md", "rtf", "html", "pdf"] {
                let u = folder.appendingPathComponent("tour.\(ext)")
                do { try a.writeNote(Fixtures.tourBody, to: u, ext: ext) } catch { failures.append("Save As .\(ext) threw \(error)") }
                expect(((try? Data(contentsOf: u))?.count ?? 0) > 100, "Save As .\(ext) writes a file")
            }
            let html = (try? String(contentsOf: folder.appendingPathComponent("tour.html"), encoding: .utf8)) ?? ""
            expect(html.contains("<h1>Welcome to Jot</h1>") && html.contains("<strong>bold</strong>") && html.contains("<title>Welcome to Jot</title>"), "the HTML export is clean semantic HTML with the note's title")
            let long = (1...400).map { "Line \($0) of a long note, with enough words in it to take up some room on the page" }.joined(separator: "\n\n")
            let pdf = a.pdfData(from: long).flatMap { PDFDocument(data: $0) }
            let last = pdf.flatMap { $0.page(at: max(0, $0.pageCount - 1))?.string } ?? ""
            expect((pdf?.pageCount ?? 0) >= 8 && (pdf?.page(at: 0)?.string ?? "").contains("Line 1 ") && last.contains("Line 400"),
                   "a long note exports as a multi-page PDF, first line on page 1 and the last on the last (\(pdf?.pageCount ?? 0) pages)")
            let short = a.pdfData(from: "# Short\nOne line.").flatMap { PDFDocument(data: $0) }
            expect(short?.pageCount == 1 && (short?.page(at: 0)?.string ?? "").contains("Short"), "a short note is a one-page PDF")
            do { try a.writeNote("x", to: URL(fileURLWithPath: "/System/jot-cannot-write-here.txt"), ext: "txt"); failures.append("writing into /System should have failed") }
            catch { expect(true, "a failed Save As throws, so the app can say so instead of \"Saved ✓\"") }
            try? FileManager.default.removeItem(at: folder)
        }

        // --- 01 default pad -----------------------------------------------------------------------
        add(0.1) { a.presentDropdown(); a.reloadNotes(selectFirst: false); a.select(self.url(1)) }
        add(0.5) {
            self.snap("01-tour-default-440x440")
            // The formatting bar's controls must fit the smallest pad (360 pt) without a scroll view.
            let bar = a.toolsBar as? FormattingBar
            self.expect((bar?.requiredWidth ?? 999) <= 344 && bar?.subviews.contains { $0 is NSScrollView } == false,
                        "the formatting bar needs \(Int(bar?.requiredWidth ?? 0)) pt (≤ 344, so it fits the 360 pt pad with no scrolling)")
            self.expect((bar?.widestStyleTitle ?? 999) <= (bar?.styleButtonWidth ?? 0) - 8,
                        "every Style title fits its button (\(Int(bar?.widestStyleTitle ?? 0)) pt of \(Int(bar?.styleButtonWidth ?? 0)))")
            let headerStack = a.sidebarToggle.superview as? NSStackView
            let visibleControls = headerStack?.arrangedSubviews.filter { !$0.isHidden }.count ?? 0
            self.expect(visibleControls <= 6, "the top bar shows \(visibleControls) controls (it had 8): sidebar, title, Aa, Share, New, ⋯")
            self.expect(a.statusLabel.stringValue == "Welcome to Jot", "the header shows the note's plain title (\(a.statusLabel.stringValue.debugDescription))")
            self.probe("chrome", "header \(Int(JotUI.headerHeight)) + formatting bar \(Int(JotUI.toolsHeight)) = \(Int(JotUI.headerHeight + JotUI.toolsHeight)) pt of a \(Int(a.dropdown.frame.height)) pt window (2.9 had 48 + 42 + 44 = 134 with a footer)")
            let menuTitles = (a.shareMenu(anchor: a.shareButton).items.map { $0.title })
            self.expect(menuTitles == ["Apple Notes", "Stickies", "", "Save As", "Share…", "Copy as Text"], "the Share menu holds every destination: \(menuTitles)")
            let moreTitles = a.noteActionsMenu().items.map { $0.title }.filter { !$0.isEmpty }
            self.expect(moreTitles == ["Keep on Top", "Remind Me…", "New Note from Clipboard", "Open in New Window", "Move to Folder", "Delete Note", "Recently Deleted", "Show Notes in Finder", "Settings…", "About Jot", "Quit Jot"],
                        "the ⋯ menu holds the occasional actions: \(moreTitles)")
            self.expect(a.pinButton?.isHidden == true && a.reminderButton?.isHidden == true, "pin and reminder badges are hidden until they apply")
            // Every SF Symbol the UI names must exist on this macOS (a missing one is an invisible button).
            let names = ["arrow.up.right.square", "sidebar.left", "textformat", "bell", "pin", "ellipsis", "square.and.pencil", "trash.circle",
                         "number", "bold", "italic", "list.bullet", "list.number", "checkmark.square", "tablecells", "text.quote", "link",
                         "arrow.counterclockwise", "doc.text", "doc.plaintext", "circle.fill", "pin.fill", "trash", "bell.fill", "arrow.up.forward",
                         "square.and.arrow.down", "square.and.arrow.up", "doc.on.doc", "macwindow", "doc.on.clipboard", "gearshape",
                         "folder", "folder.badge.plus", "folder.badge.minus", "chevron.right", "chevron.down", "pencil"]
            let missing = names.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
            self.expect(missing.isEmpty, "all \(names.count) SF Symbols used by the UI exist on this macOS" + (missing.isEmpty ? "" : ": missing \(missing)"))
            self.auditAccessibility(a.dropdown.contentView!, label: "pad")
        }

        // --- 02 blank note ------------------------------------------------------------------------
        add(0.1) { a.newNote() }
        add(0.4) { self.snap("02-blank-note") }

        // --- 03 the owner's own configuration (black background, 14 pt, formatting bar off) ----------
        add(0.1) {
            Prefs.editorBGHex = "000000"; Prefs.fontSize = 14
            a.toolsShown = false; Prefs.toolsShown = false
            a.applyFontSize(); a.applyEditorBG(); a.applyToolsVisibility()
            a.select(self.url(1))
        }
        add(0.4) { self.snap("03-tour-owner-config") }

        // --- 04 sidebar (5.3): a DRAWER over the text on a small pad, DOCKED beside it on a wide one -----------------------------
        add(0.1) { a.sidebarWidth = 312; a.showSidebar() }
        add(0.4) {
            let W = a.dropdown.contentView!.bounds.width
            self.expect(!a.sidebarDocks && a.editorScroll.frame.width == W && a.editorScroll.frame.minX == 0,
                        "on a \(Int(W)) pt pad the sidebar is a drawer: the text keeps its full \(Int(a.editorScroll.frame.width)) pt (it was squeezed to 176 pt)")
            self.expect(a.listScroll.frame.minX == 0 && a.listScroll.frame.width <= 280 && !a.drawerScrim.isHidden && !a.drawerBackdrop.isHidden,
                        "the drawer is open at \(Int(a.listScroll.frame.width)) pt (the saved 312 is capped at 280) with the text dimmed behind it")
            self.expect(a.dropdown.firstResponder === a.tableView, "while the drawer is open the notes list has the keys")
            self.snap("04-sidebar-drawer-440")
        }
        add(0.1) {
            // Esc closes the drawer first; a second Esc hides the pad.
            let esc = self.key("\u{1b}", code: 53)
            let who = self.route(esc)
            self.expect(!a.sidebarShown && a.dropdown.isVisible && a.dropdown.firstResponder === tv, "Esc closes an open drawer first (pad still up, caret back in the text) [\(who); sidebarShown \(a.sidebarShown); visible \(a.dropdown.isVisible); responder \(a.dropdown.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")]")
            // Choosing a note closes it; so does a click on the dimmed text.
            a.showSidebar()
            a.sidebarRowPicked(0)
            self.expect(!a.sidebarShown && a.dropdown.firstResponder === tv, "picking a note closes the drawer and puts the caret in the text")
            a.showSidebar()
            a.drawerScrim.onClick?()
            self.expect(!a.sidebarShown, "a click on the dimmed text closes the drawer")
            a.showSidebar()
            self.expect(a.sep.isDraggable == false, "a drawer's edge is not a resize handle")
            a.hideSidebar()
        }
        // Wide pad: docked beside the text, with the draggable divider, and the text never narrower than 300 pt.
        add(0.1) { self.park(a.dropdown, NSSize(width: 700, height: 440)) }
        add(0.4) {
            a.sidebarWidth = 312; a.showSidebar()
        }
        add(0.4) {
            let W = a.dropdown.contentView!.bounds.width
            self.expect(a.sidebarDocks && a.drawerScrim.isHidden && a.sep.isDraggable, "on a \(Int(W)) pt pad the sidebar docks beside the text, with its draggable divider")
            self.expect(a.listScroll.frame.width == 312 && a.editorScroll.frame.minX == 316 && a.editorScroll.frame.width == W - 316 && a.editorScroll.frame.width >= 300,
                        "…the list at its saved 312 pt and a \(Int(a.editorScroll.frame.width)) pt text column")
            self.expect(a.dropdown.firstResponder !== a.tableView, "…and the keys stay in the text")
            self.snap("04-sidebar-docked-700")
            self.park(a.dropdown, NSSize(width: 440, height: 440))      // shrink across the threshold with the sidebar open
        }
        add(0.4) {
            self.expect(!a.sidebarDocks && a.sidebarShown && a.editorScroll.frame.width == a.dropdown.contentView!.bounds.width && !a.drawerScrim.isHidden,
                        "shrinking the pad below 560 pt turns the open sidebar into a drawer")
            a.hideSidebar()
            self.expect(a.editorScroll.frame.width == 440 && a.listScroll.isHidden, "closing it leaves the full-width text and hides the list")
        }
        add(0.1) { a.toolsShown = true; Prefs.toolsShown = true; a.applyToolsVisibility() }

        // --- 04b filter field (5.4): title and body, ignoring case and accents -----------------------------------------------------------
        add(0.2) {
            a.rebuildNotes(); a.tableView.reloadData()
            let total = a.notes.count
            a.focusSearch()
            self.expect(a.sidebarShown && a.searchField.currentEditor() != nil, "⌥⌘F opens the sidebar and puts the caret in the search field")
            func search(_ query: String) -> [String] {
                a.searchField.stringValue = query; a.filterChanged(a.searchField)
                return a.notes.map { a.titleForNote($0) }
            }
            let byBody = search("frontmatter")
            self.expect(byBody == ["Obsidian-style note"], "search looks in the body, not just the title: \(byBody)")
            let byAccent = search("COMBINING e")
            self.expect(byAccent.count == 1 && byAccent[0].hasPrefix("日本語"), "search ignores case and accents (\"combining e\" finds \"combining é\"): \(byAccent)")
            self.expect(search("welcome jot").contains("Welcome to Jot"), "several words match in any order")
            let none = search("zzzzqq")
            self.expect(none.isEmpty && !a.filterEmptyLabel.isHidden, "a search with no match says so")
            self.expect(a.tableView(a.tableView, writeRowsWith: IndexSet(integer: 0), to: NSPasteboard(name: NSPasteboard.Name("jot-preview-drag"))) == false, "reordering is off while filtering")
            _ = a.control(a.searchField, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
            self.expect(a.searchField.stringValue.isEmpty && a.notes.count == total && a.filterEmptyLabel.isHidden && a.sidebarShown, "Esc clears the filter first (all \(total) notes back, sidebar still open)")
            _ = search("welcome")
            _ = a.control(a.searchField, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
            self.expect(a.current.map { a.titleForNote($0) } == "Welcome to Jot" && !a.sidebarShown, "Return opens the first match and closes the drawer")
            a.searchField.stringValue = "left over"; a.filterChanged(a.searchField)
            a.presentDropdown()
            self.expect(a.searchField.stringValue.isEmpty && a.notes.count == total, "opening the pad always starts with an empty filter")
            a.hideSidebar()
            a.select(self.url(1))
        }

        // --- 04d per-note caret and scroll (5.2): leave a note and come back, and you are where you were --------------------------------------
        add(0.2) {
            a.select(self.url(1))
            let ns = tv.string as NSString
            let target = ns.range(of: "Tasks").location
            tv.setSelectedRange(NSRange(location: target, length: 5))
            tv.scrollRangeToVisible(NSRange(location: target, length: 5))
            let scrolledTo = a.editorScroll.contentView.bounds.origin.y
            a.select(self.url(2))
            self.expect(tv.selectedRange().length == 0 && a.editorScroll.contentView.bounds.origin.y == 0, "a note you haven't been in this session opens at the top, caret at the start")
            a.select(self.url(1))
            self.expect(tv.selectedRange() == NSRange(location: target, length: 5) && abs(a.editorScroll.contentView.bounds.origin.y - scrolledTo) < 1,
                        "coming back to a note restores its selection and scroll (\(tv.selectedRange()), y \(Int(a.editorScroll.contentView.bounds.origin.y)) vs \(Int(scrolledTo)))")
            self.expect(a.editorScroll.alphaValue == 1, "the editor is fully opaque after a switch")
        }

        // --- 04e list motion (5.2): rows slide in and out instead of the list reloading; the table always ends up matching `notes` ----------------
        add(0.2) { AppDelegate.previewAnimations = true; a.showSidebar() }
        add(0.4) {
            let before = a.notes.count
            let u = try! a.store.create(); try! "# Added by the walkthrough\nbody".write(to: u, atomically: true, encoding: .utf8)
            a.rebuildNotes()
            self.expect(a.tableView.numberOfRows == before + 1 && a.notes.contains { $0.lastPathComponent == u.lastPathComponent }, "a new note is inserted as one row (\(before) → \(a.tableView.numberOfRows))")
        }
        add(0.5) {
            let title = a.notes.first(where: { a.titleForNote($0) == "Added by the walkthrough" })
            self.expect(title != nil, "…and the new row shows its title")
            if let u = title { a.deleteNotes([u]) }
        }
        add(0.5) {
            self.expect(a.tableView.numberOfRows == a.notes.count && !a.notes.contains { a.titleForNote($0) == "Added by the walkthrough" }, "deleting it removes exactly that row (\(a.tableView.numberOfRows) rows, \(a.notes.count) notes)")
            for u in a.store.trashedAll() where (try? String(contentsOf: u, encoding: .utf8))?.contains("Added by the walkthrough") == true { try? FileManager.default.removeItem(at: u) }
            AppDelegate.previewAnimations = false
            a.hideSidebar()
        }

        // --- 04c the notes list's right-click menu (5.5): built when it opens, titles follow the clicked note(s) ------------------------------------
        add(0.2) {
            a.rebuildNotes(); a.tableView.reloadData()
            let pinned = a.notes.firstIndex { a.noteInfo($0).meta.pin } ?? 0
            let plain = a.notes.firstIndex { !a.noteInfo($0).meta.pin } ?? 0
            func titles(_ rows: [Int]) -> [String] { let m = NSMenu(); a.populateListMenu(m, rows: rows); return m.items.map { $0.title }.filter { !$0.isEmpty } }
            let onPinned = titles([pinned]), onPlain = titles([plain])
            self.expect(onPinned.contains("Unpin") && !onPinned.contains("Pin") && onPlain.contains("Pin") && !onPlain.contains("Unpin"), "the menu says Unpin for a pinned note and Pin for a plain one: \(onPinned) / \(onPlain)")
            self.expect(!onPlain.contains(where: { $0.hasPrefix("Priority") }) && onPlain.contains("Delete Note") && onPlain.contains("Open in New Window"), "the retired Priority submenu is gone: \(onPlain)")
            let withReminder = a.notes.firstIndex { a.noteInfo($0).meta.reminder != nil }
            if let r = withReminder { let t = titles([r]); self.expect(t.contains("Change Reminder…") && t.contains("Clear Reminder"), "a note with a reminder offers Change and Clear: \(t)") }
            let many = titles([0, 1, 2])
            self.expect(many.contains("Delete 3 Notes") && many.contains("Open 3 in New Windows") && !many.contains("Remind Me…"), "a multi-selection says how many it acts on and drops single-note items: \(many)")
            let tableMenu = a.tableView.menu
            self.expect(tableMenu?.delegate === a, "the list's menu is filled in when it opens")
        }

        // --- 04f folders: file a note under a header, fold it, drag between groups, rename, remove (a scratch note; the fixtures stay put) ----------------
        var folderScratch: URL!
        add(0.2) {
            a.rebuildNotes(); a.tableView.reloadData()
            let isHeader: (SidebarItem) -> Bool = { if case .folder = $0 { return true } else { return false } }
            self.expect(Prefs.folderOrder.isEmpty && !a.sidebarItems.contains(where: isHeader) && a.sidebarItems.count == a.notes.count, "with no folders the list is just the notes — no headers, no change")
            let u = try! a.store.create(); try! "# Filed by the walkthrough\nbody".write(to: u, atomically: true, encoding: .utf8)
            folderScratch = u
            a.rebuildNotes(); a.tableView.reloadData()
            a.moveNotes([u], toFolder: "  Walk \"Folder\" ")
            self.expect(a.store.readMeta(u).folder == "Walk 'Folder'" && Prefs.folderOrder == ["Walk 'Folder'"], "filing a note writes folder: (name cleaned) and remembers the folder: \(Prefs.folderOrder)")
            self.expect(a.store.readRaw(u).contains("folder: \"Walk 'Folder'\""), "the folder is stored quoted in the note's frontmatter")
            let n = a.sidebarItems.count
            self.expect(n >= 2 && a.folderName(atRow: n - 2) == "Walk 'Folder'" && a.noteURL(atRow: n - 1)?.lastPathComponent == u.lastPathComponent, "the folder's header sits above its note, after the unfiled notes")
            self.expect(a.tableView.numberOfRows == n, "the table has a row per header and per note (\(a.tableView.numberOfRows) rows)")
            self.expect(!a.tableView(a.tableView, shouldSelectRow: n - 2) && a.tableView(a.tableView, shouldSelectRow: n - 1), "a header can't be selected; its note can")
            self.expect(a.tableView(a.tableView, heightOfRow: n - 2) == JotUI.folderRowHeight && a.tableView(a.tableView, heightOfRow: n - 1) == a.tableView.rowHeight, "a header row is shorter than a note row")
            let cell = a.tableView(a.tableView, viewFor: nil, row: n - 2) as? FolderHeaderCell
            self.expect(cell?.accessibilityLabel() == "Walk 'Folder' folder, 1 note, expanded", "a header is read as one phrase: \(String(describing: cell?.accessibilityLabel()))")
            let headerTitles: (String) -> [String] = { name in let m = NSMenu(); a.populateFolderMenu(m, folder: name); return m.items.map { $0.title }.filter { !$0.isEmpty } }
            self.expect(headerTitles("Walk 'Folder'") == ["Collapse", "Rename Folder…", "Remove Folder", "New Folder…"], "a header's menu: \(headerTitles("Walk 'Folder'"))")
            let sub = a.folderSubmenu(for: [u]).items.map { $0.title }.filter { !$0.isEmpty }
            self.expect(sub == ["Walk 'Folder'", "New Folder…", "Remove from Folder"], "Move to Folder lists the folders, New Folder…, and Remove from Folder for a filed note: \(sub)")
            let empty = NSMenu(); a.populateListMenu(empty, rows: [])
            self.expect(empty.items.map { $0.title } == ["New Folder…"], "right-clicking empty space offers New Folder…")
        }
        add(0.2) {
            let u = folderScratch!
            a.setFolder("Walk 'Folder'", collapsed: true)
            self.expect(!a.notes.contains { $0.lastPathComponent == u.lastPathComponent } && a.allNotes.contains { $0.lastPathComponent == u.lastPathComponent }
                        && a.sidebarItems.last == .folder("Walk 'Folder'") && a.layout.counts["Walk 'Folder'"] == 1, "folding a folder hides its notes but keeps the header, its count, and the note in allNotes")
            self.expect(a.tableView.numberOfRows == a.sidebarItems.count, "…and the table follows (\(a.tableView.numberOfRows) rows)")
            a.toggleFolder(atRow: a.sidebarItems.count - 1)
            self.expect(a.notes.contains { $0.lastPathComponent == u.lastPathComponent } && Prefs.collapsedFolders.isEmpty, "unfolding brings the note back")
            a.setFolder("Walk 'Folder'", collapsed: true)
            a.dropNote(u, onto: .into("Walk 'Folder'"))
            self.expect(Prefs.collapsedFolders.isEmpty && a.store.readMeta(u).folder == "Walk 'Folder'", "filing into a folded folder opens it")
        }
        add(0.2) {
            let u = folderScratch!
            a.moveNotes([u], toFolder: "")
            self.expect(a.store.readMeta(u).folder.isEmpty && a.notes.first(where: { $0.lastPathComponent == u.lastPathComponent }).flatMap { a.rowIndex(of: $0) }.map { NoteLibrary.folder(atRow: $0, in: a.sidebarItems).isEmpty } == true, "Remove from Folder puts the note back among the unfiled ones")
            self.expect(a.tableView.numberOfRows == a.sidebarItems.count, "the empty folder stays as a header (\(a.tableView.numberOfRows) rows)")
            self.expect(Array(a.sidebarItems.suffix(1)) == [.folder("Walk 'Folder'")] && a.layout.counts["Walk 'Folder'"] == 0, "…with no notes in it")
            let found = NoteLibrary.dropTarget(row: a.sidebarItems.count - 1, onRow: true, items: a.sidebarItems, collapsed: [])
            self.expect(found == .into("Walk 'Folder'"), "dropping on that header files into it")
            if let found = found { a.dropNote(u, onto: found) }
            self.expect(a.store.readMeta(u).folder == "Walk 'Folder'", "…and does")
        }
        add(0.2) {
            let u = folderScratch!
            a.renameFolder("Walk 'Folder'", to: "Renamed")
            self.expect(a.store.readMeta(u).folder == "Renamed" && Prefs.folderOrder == ["Renamed"] && a.layout.folders == ["Renamed"], "renaming a folder renames it on every note in it and in the folder list")
            a.renameFolder("Renamed", to: "renamed")
            self.expect(Prefs.folderOrder == ["renamed"] && a.store.readMeta(u).folder == "renamed", "a rename that only changes case is allowed")
            a.createFolder("RENAMED")
            self.expect(Prefs.folderOrder == ["renamed"], "a new folder can't share a name (ignoring case) with an existing one")
            a.removeFolder("renamed")
            self.expect(a.store.readMeta(u).folder.isEmpty && Prefs.folderOrder.isEmpty && !a.sidebarItems.contains(where: { if case .folder = $0 { return true } else { return false } }),
                        "removing a folder unfiles its notes (none deleted) and the list is plain again")
            self.expect(FileManager.default.fileExists(atPath: u.path), "…the note itself is still there")
            try? FileManager.default.removeItem(at: u)
            a.infoCache[u] = nil
            a.rebuildNotes(); a.tableView.reloadData()
        }

        // --- 05 small window ------------------------------------------------------------------------
        add(0.1) { self.park(a.dropdown, NSSize(width: 360, height: 240)) }
        add(0.4) {
            self.snap("05-small-360x240")
            if let bar = a.toolsBar as? FormattingBar, !bar.isHidden {
                self.expect(bar.bounds.width <= 361 && !bar.spillsOut, "at 360 pt wide every formatting control sits inside the bar (\(Int(bar.bounds.width)) pt, needs \(Int(bar.requiredWidth)))")
            }
        }
        add(0.1) { self.park(a.dropdown, NSSize(width: 440, height: 440)) }

        // --- 06 key routing & window behaviour (Phase Q). Destructive steps use scratch notes, never fixtures. -----
        var scratch: URL!
        func newScratch(_ text: String) {
            scratch = try! a.store.create()
            a.rebuildNotes(); a.tableView.reloadData()
            a.select(scratch)
            tv.insertText(text, replacementRange: NSRange(location: 0, length: tv.string.utf16.count))
        }
        func present() { if !a.dropdown.isVisible { a.presentDropdown() } }
        add(0.2) {
            // Calibration: ⌘N is bound in the main menu, so the router must report the menu.
            let who = self.route(self.key("n", code: 45, flags: [.command]))
            self.expect(who == "the main menu", "calibration: ⌘N is consumed by the main menu (\(who))")
            self.expect(tv.isAutomaticTextCompletionEnabled == false, "automatic text completion is off in the pad")
            self.expect(a.dropdown.collectionBehavior.contains(.fullScreenAuxiliary) && a.dropdown.collectionBehavior.contains(.moveToActiveSpace),
                        "the pad can appear over a full-screen app")
        }
        // ⌘⌫ belongs to the text while you type (either character the Delete key may send)…
        add(0.2) {
            newScratch("hello world note")
            let trash0 = a.store.trashedAll().count
            for chars in ["\u{7F}", "\u{8}"] {
                tv.string = "hello world note"; tv.setSelectedRange(NSRange(location: 6, length: 0))
                a.dropdown.makeFirstResponder(tv)
                let who = self.route(self.key(chars, code: 51, flags: [.command]))
                self.expect(who == "a view's performKeyEquivalent" && tv.string == "world note" && a.store.trashedAll().count == trash0,
                            "⌘⌫ with the caret in the text deletes to the line start, not the note (0x\(String(chars.unicodeScalars.first!.value, radix: 16))): consumed by \(who), text \"\(tv.string)\"")
            }
        }
        // …and to the notes list when that has focus; ⇧⌘⌫ deletes the open note from anywhere.
        add(0.2) {
            let trash0 = a.store.trashedAll().count
            a.dropdown.makeFirstResponder(a.tableView)
            let who = self.route(self.key("\u{8}", code: 51, flags: [.command]))
            self.expect(who == "the main menu" && a.store.trashedAll().count == trash0 + 1, "⌘⌫ with the notes list focused deletes the note (\(who))")
            newScratch("another scratch note")
            a.dropdown.makeFirstResponder(tv)
            let trash1 = a.store.trashedAll().count
            let who2 = self.route(self.key("\u{8}", code: 51, flags: [.command, .shift]))
            self.expect(who2 == "the main menu" && a.store.trashedAll().count == trash1 + 1, "⇧⌘⌫ deletes the open note even while typing (\(who2))")
        }
        // ⌘⇧← is the native "extend selection to line start" again, and the sidebar is untouched.
        add(0.2) {
            newScratch("hello world note")
            a.sidebarWidth = 312; a.showSidebar()
            a.dropdown.makeFirstResponder(tv)                    // (a drawer hands the keys to its list; here the user clicked back into the text)
            tv.setSelectedRange(NSRange(location: 6, length: 5))
            let before = tv.selectedRange()
            tv.keyDown(with: self.key(self.arrow(NSLeftArrowFunctionKey), code: 123, flags: [.command, .shift]))
            self.expect(tv.selectedRange() != before && a.sidebarShown, "⌘⇧← extends the selection to the line start and leaves the sidebar alone (\(before) → \(tv.selectedRange()))")
            a.hideSidebar()
        }
        // View menu: ⌃⌘S toggles the sidebar; ⌥⌘↑/↓ move between notes.
        add(0.2) {
            let before = a.sidebarShown
            let who = self.route(self.key("s", code: 1, flags: [.control, .command]))
            self.expect(who == "the main menu" && a.sidebarShown != before, "⌃⌘S toggles the sidebar (\(who))")
            a.hideSidebar()
            a.reloadNotes(selectFirst: true)
            let first = a.current
            let down = self.route(self.key(self.arrow(NSDownArrowFunctionKey), code: 125, flags: [.command, .option]))
            let second = a.current
            let up = self.route(self.key(self.arrow(NSUpArrowFunctionKey), code: 126, flags: [.command, .option]))
            self.expect(down == "the main menu" && up == "the main menu" && second != first && a.current == first, "⌥⌘↓ / ⌥⌘↑ step to the next / previous note")
        }
        // Esc: the find bar first, then the pad. ⌘W closes the pad too.
        add(0.2) {
            present()
            a.dropdown.makeFirstResponder(tv)
            a.editorScroll.isFindBarVisible = true
            a.dropdown.makeFirstResponder(tv)
            _ = self.route(self.key("\u{1B}", code: 53))
            self.expect(!a.editorScroll.isFindBarVisible && a.dropdown.isVisible, "Esc closes an open find bar first and leaves the pad up")
            let who = self.route(self.key("\u{1B}", code: 53))
            self.expect(!a.dropdown.isVisible, "Esc then hides the pad (\(who))")
            present()
            let closed = self.route(self.key("w", code: 13, flags: [.command]))
            self.expect(closed == "the main menu" && !a.dropdown.isVisible, "⌘W hides the pad (\(closed))")
            present()
            a.dropdown.makeFirstResponder(tv)
        }
        // The hotkey brings a visible-but-unfocused pad forward instead of hiding it.
        add(0.2) {
            present()
            a.toggleTray(fromHotkey: true)
            self.expect(a.dropdown.isVisible, "the hotkey on a visible-but-unfocused pad focuses it instead of hiding it")
            a.toggleDropdown()
            self.expect(!a.dropdown.isVisible, "clicking the menu-bar icon is still a plain toggle")
            present()
        }
        // Hotkey registration: the new key is claimed before the old is released; a refused key keeps the old one.
        add(0.1) {
            let mods = UInt32(controlKey | optionKey | cmdKey | shiftKey)
            let one = UInt32(kVK_F19), two = UInt32(kVK_F18)
            self.expect(a.applyHotkey(keyCode: one, carbonModifiers: mods), "a new shortcut registers")
            self.expect(a.applyHotkey(keyCode: one, carbonModifiers: mods), "choosing the same shortcut again is a harmless success")
            self.expect(a.applyHotkey(keyCode: two, carbonModifiers: mods), "switching to another shortcut works")
            var probeRef: EventHotKeyRef?
            let freed = RegisterEventHotKey(one, mods, EventHotKeyID(signature: OSType(0x54455354), id: 9), GetApplicationEventTarget(), 0, &probeRef)
            self.expect(freed == noErr, "the previous shortcut was released after the switch")
            if let r = probeRef { UnregisterEventHotKey(r) }
            // A key somebody (here: this same process) already holds is refused, and the working shortcut stays.
            var holder: EventHotKeyRef?
            _ = RegisterEventHotKey(one, mods, EventHotKeyID(signature: OSType(0x54455354), id: 10), GetApplicationEventTarget(), 0, &holder)
            self.expect(!a.applyHotkey(keyCode: one, carbonModifiers: mods) && a.registeredHotkey?.keyCode == two,
                        "a refused shortcut is reported and the working one is kept")
            if let h = holder { UnregisterEventHotKey(h) }
            if let r = a.hotKeyRef { UnregisterEventHotKey(r) }
            a.hotKeyRef = nil; a.registeredHotkey = nil
        }
        // Opening a note window or Settings puts the tray away — unless it's pinned.
        var padOwnedNote: URL?
        add(0.2) {
            present()
            newScratch("note to open in a window")
            padOwnedNote = scratch
            let u = try! a.store.create(); try! "window note".write(to: u, atomically: true, encoding: .utf8)
            let nc = a.openWindow(for: u)
            self.park(nc.window)
            self.expect(!a.dropdown.isVisible, "opening a note window puts the tray away")
            // Delete acts on the focused editor's note, not the pad's.
            present()
            a.select(padOwnedNote!)
            let trash0 = a.store.trashedAll().count
            a.deleteNote(inWindow: nc.window)
            self.expect(a.store.trashedAll().count == trash0 + 1 && !FileManager.default.fileExists(atPath: u.path) && a.current == padOwnedNote
                        && !a.noteWindows.contains { $0 === nc }, "Delete in a note window removes that note and leaves the pad's note alone")
            present()
            a.openSettings()
            self.expect(!a.dropdown.isVisible, "opening Settings puts the tray away")
            a.settingsController?.window.orderOut(nil)
            present()
            a.togglePin(nil)
            a.openSettings()
            self.expect(a.dropdown.isVisible, "a pinned pad stays up when Settings opens")
            a.settingsController?.window.orderOut(nil)
            a.togglePin(nil)
        }
        // ---- window motion (4.2): fade and rise in, fade out; rapid toggles never leave the pad stuck or orphaned -----------------------
        var restFrame = NSRect.zero
        add(0.2) {
            AppDelegate.previewAnimations = true
            present()
            restFrame = a.dropdown.frame
            a.hidePad()
        }
        add(0.4) {
            self.expect(!a.dropdown.isVisible && a.dropdown.alphaValue == 1 && !a.padHiding, "the pad is gone after its fade, and its opacity is reset for the next show [visible \(a.dropdown.isVisible), alpha \(a.dropdown.alphaValue), hiding \(a.padHiding), animates \(a.animatesPad), reduceMotion \(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion), generation \(a.padGeneration)]")
            a.presentDropdown()
            // (An animator proxy updates the model value at once, so the fade itself can't be sampled here.)
            self.expect(a.dropdown.isVisible && a.suppressMoveSave, "while the pad moves into place its own motion is not mistaken for a drag")
        }
        add(0.45) {
            self.expect(a.dropdown.alphaValue == 1 && !a.suppressMoveSave && abs(a.dropdown.frame.origin.y - restFrame.origin.y) < 0.5 && abs(a.dropdown.frame.origin.x - restFrame.origin.x) < 0.5,
                        "…and settles at full opacity exactly where it belongs (\(a.dropdown.frame.origin) vs \(restFrame.origin))")
        }
        add(0.1) { a.toggleTray(fromHotkey: false); a.toggleTray(fromHotkey: false) }       // hide, then show again before the fade ends
        add(0.5) {
            self.expect(a.dropdown.isVisible && a.dropdown.alphaValue == 1 && !a.padHiding, "hide then show within a frame ends shown — the old fade never orders out a pad that was shown again")
            a.hidePad()
        }
        add(0.4) {
            self.expect(!a.dropdown.isVisible, "hidden again")
            a.toggleTray(fromHotkey: false); a.toggleTray(fromHotkey: false)                 // show, then hide before the rise ends
        }
        add(0.6) {
            self.expect(!a.dropdown.isVisible && a.dropdown.alphaValue == 1, "show then hide within a frame ends hidden, with its opacity reset (\(a.dropdown.isVisible), \(a.dropdown.alphaValue))")
            AppDelegate.previewAnimations = false
            a.presentDropdown()
            self.expect(a.dropdown.isVisible && a.dropdown.alphaValue == 1, "with motion off the pad appears at once")
        }
        // Placement: always inside a screen, even if the saved spot is gone; a status item that isn't on a screen falls back to the pointer's screen.
        add(0.1) {
            let screens = NSScreen.screens
            let wild = NSRect(x: -90_000, y: 90_000, width: 440, height: 440)
            let inside = a.fitted(wild)
            self.expect(screens.contains { $0.visibleFrame.contains(inside) }, "a frame that lies off every screen is moved back inside one: \(inside)")
            self.expect(a.fitted(NSRect(x: 100, y: 100, width: 440, height: 440), on: nil).size == NSSize(width: 440, height: 440), "fitting a frame never resizes it")
        }
        // ---- the formatting bar (3.1): every button toggles, lights up while the caret is in that formatting, and is one undo step ----
        add(0.1) {
            newScratch("x")
            func roundTrip(_ name: String, _ text: String, _ selection: NSRange, on: String, _ press: () -> Void) {
                tv.string = text; tv.setSelectedRange(selection)
                press()
                let applied = tv.string
                press()
                self.expect(applied == on && tv.string == text, "\(name) toggles \(text.debugDescription) → \(on.debugDescription) and back (second press gave \(tv.string.debugDescription))")
            }
            let word = NSRange(location: 0, length: 1), caret = NSRange(location: 0, length: 0)
            roundTrip("Bold", "x", word, on: "**x**", a.tBold)                  // used to give "**x******" the second time
            roundTrip("Italic", "x", word, on: "*x*", a.tItalic)
            roundTrip("Strikethrough", "x", word, on: "~~x~~", a.tStrike)
            roundTrip("Code", "x", word, on: "`x`", a.tCode)
            roundTrip("Title", "x", caret, on: "# x", a.tTitle)
            roundTrip("Heading", "x", caret, on: "## x", a.tHeading)           // used to give "# # x"
            roundTrip("Subheading", "x", caret, on: "### x", a.tSubheading)
            roundTrip("Bulleted list", "x", caret, on: "- x", a.tBullet)
            roundTrip("Numbered list", "x", caret, on: "1. x", a.tNumbered)
            roundTrip("Checklist", "x", caret, on: "- [ ] x", a.tCheckbox)
            roundTrip("Quote", "x", caret, on: "> x", a.tQuote)
            roundTrip("Code block", "x", caret, on: "```\nx\n```", a.tCodeBlock)
            roundTrip("Link", "x", word, on: "[x](url)", a.tLink)
            tv.string = "## x"; tv.setSelectedRange(caret); a.tBody()
            self.expect(tv.string == "x", "Body turns a heading back into plain text")
            tv.string = "x"; tv.setSelectedRange(caret); a.tIndent()
            let indented = tv.string
            a.tOutdent()
            self.expect(indented == "  x" && tv.string == "x", "Increase / Decrease Indent move a line by two spaces and back")
            // A destination on the clipboard becomes the link's URL.
            Runtime.pasteboard.clearContents(); Runtime.pasteboard.setString("https://example.com/a", forType: .string)
            tv.string = "see x"; tv.setSelectedRange(NSRange(location: 4, length: 1)); a.tLink()
            self.expect(tv.string == "see [x](https://example.com/a)", "Link uses a URL from the clipboard as its destination (\(tv.string.debugDescription))")
            Runtime.pasteboard.clearContents()
            tv.string = "para"; tv.setSelectedRange(NSRange(location: 4, length: 0)); a.tDivider()
            self.expect(tv.string == "para\n\n---\n", "Divider goes on its own line below a blank one (\(tv.string.debugDescription))")
            tv.string = "para"; tv.setSelectedRange(NSRange(location: 4, length: 0)); a.tTable()
            self.expect(tv.string.hasPrefix("para\n\n| Col1 | Col2 | Col3 |\n|------|"), "Table inserts a three-column skeleton below the line")
            // One undo step per formatting action.
            tv.string = "x"; tv.setSelectedRange(word)
            tv.undoManager?.removeAllActions()
            a.tBold()
            tv.undoManager?.undo()
            self.expect(tv.string == "x", "one ⌘Z undoes a whole formatting step (\(tv.string.debugDescription))")
            // Formatting never touches a note that can't be edited.
            tv.string = "x"; tv.setSelectedRange(word); tv.isEditable = false; a.tBold()
            self.expect(tv.string == "x", "a read-only editor ignores format commands")
            tv.isEditable = true
        }
        add(0.1) {
            // The bar lights up for the formatting at the caret.
            guard let bar = a.toolsBar as? FormattingBar else { self.failures.append("the pad has no FormattingBar"); return }
            tv.string = "# Title\nplain **bold** and *it*\n- item\n> quote"
            tv.setSelectedRange(NSRange(location: 17, length: 0))     // inside "bold"
            self.expect(bar.activeLabels == ["Bold"], "the caret inside bold lights only Bold: \(bar.activeLabels)")
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            self.expect(bar.styleLabel.hasPrefix("Title") && bar.activeLabels.isEmpty, "on a # line the Style button says Title: \(bar.styleLabel)")
            tv.setSelectedRange(NSRange(location: 38, length: 0))
            self.expect(bar.activeLabels == ["Bulleted list"] && bar.styleLabel.hasPrefix("Body"), "on a list item the list button is lit: \(bar.activeLabels)")
            tv.setSelectedRange(NSRange(location: 46, length: 0))
            self.expect(bar.activeLabels == ["More formatting"], "inside a quote the ⋯ button is lit: \(bar.activeLabels)")
            tv.string = "a **b** c"; tv.setSelectedRange(NSRange(location: 4, length: 0))
            let beforeRaw = bar.activeLabels
            a.toggleDisplayMode()
            self.expect(Prefs.rawMode && bar.activeLabels.contains("Show Markdown syntax") && bar.activeLabels.contains("Bold"), "Raw mode lights its button and keeps the state lit: \(bar.activeLabels) (was \(beforeRaw))")
            a.toggleDisplayMode()
            self.expect(!Prefs.rawMode && !bar.activeLabels.contains("Show Markdown syntax"), "…and turns it off again")
            tv.string = "# Title\nSome **bold** words here"
            tv.setSelectedRange(NSRange(location: 18, length: 0))
            bar.previewHover("Italic")     // Bold is on, Italic is under the mouse
            self.snap("10-format-bar-bold-active")
            bar.previewHover(nil)
        }
        // ---- Format-menu shortcuts reach their actions through AppKit's real routing (window views → main menu → keyDown) ------------
        // Events come from CGEvent key codes, not NSEvent.keyEvent(characters:…): a hand-built event can carry characters a real
        // keyboard never produces (it made ⌘B land on ⇧⌘B and ⇧⌘X on Cut), so only the CGEvent form is a faithful test.
        add(0.1) {
            newScratch("x")
            func realKey(_ code: CGKeyCode, _ flags: CGEventFlags) -> NSEvent? {
                guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) else { return nil }
                cg.flags = flags
                return NSEvent(cgEvent: cg)
            }
            guard realKey(11, [])?.characters == "b" else {
                self.probe("keyboard layout", "key code 11 is not \"b\" here (not US QWERTY): shortcut routing checks skipped")
                return
            }
            func press(_ name: String, _ code: CGKeyCode, _ flags: CGEventFlags, from text: String, _ selection: NSRange, becomes expected: String) {
                tv.string = text; tv.setSelectedRange(selection)
                guard let event = realKey(code, flags) else { self.failures.append("could not build a key event for \(name)"); return }
                let who = self.route(event)
                self.expect(who == "the main menu" && tv.string == expected, "\(name) is taken by the main menu and formats the text (\(who); \(tv.string.debugDescription))")
            }
            let word = NSRange(location: 0, length: 1), caret = NSRange(location: 0, length: 0)
            let cmd = CGEventFlags.maskCommand, cs: CGEventFlags = [.maskCommand, .maskShift]
            press("⌘B", 11, cmd, from: "x", word, becomes: "**x**")
            press("⌘I", 34, cmd, from: "x", word, becomes: "*x*")
            press("⇧⌘X", 7, cs, from: "x", word, becomes: "~~x~~")
            press("⇧⌘M", 46, cs, from: "x", word, becomes: "`x`")
            press("⇧⌘T", 17, cs, from: "x", caret, becomes: "# x")
            press("⇧⌘H", 4, cs, from: "x", caret, becomes: "## x")
            press("⇧⌘J", 38, cs, from: "x", caret, becomes: "### x")
            press("⇧⌘B", 11, cs, from: "## x", caret, becomes: "x")
            press("⇧⌘7", 26, cs, from: "x", caret, becomes: "- x")
            press("⇧⌘9", 25, cs, from: "x", caret, becomes: "1. x")
            press("⇧⌘L", 37, cs, from: "x", caret, becomes: "- [ ] x")
            press("⌘'", 39, cmd, from: "x", caret, becomes: "> x")
            press("⌘]", 30, cmd, from: "x", caret, becomes: "  x")
            press("⌘[", 33, cmd, from: "  x", caret, becomes: "x")
            press("⌘K", 40, cmd, from: "x", word, becomes: "[x](url)")
            // No Format item steals a standard editing shortcut: ⌘X, ⌘C, ⌘V, ⌘Z, ⌘A stay with the Edit menu.
            let everyItem = (NSApp.mainMenu?.items ?? []).compactMap { $0.submenu }.flatMap { $0.items }
            func owners(_ key: String, _ mask: NSEvent.ModifierFlags) -> [String] { everyItem.filter { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == mask }.map { $0.title } }
            self.expect(owners("x", [.command]) == ["Cut"] && owners("c", [.command]) == ["Copy"] && owners("v", [.command]) == ["Paste"] && owners("a", [.command]) == ["Select All"],
                        "⌘X ⌘C ⌘V ⌘A each belong to exactly one Edit item: \(owners("x", [.command])) \(owners("c", [.command])) \(owners("v", [.command])) \(owners("a", [.command]))")
            // Every shortcut is bound once: no two enabled menu items share a key and modifier.
            var seen: [String: String] = [:], clashes: [String] = []
            for i in everyItem where !i.keyEquivalent.isEmpty {
                let id = "\(i.keyEquivalent)|\(i.keyEquivalentModifierMask.rawValue)"
                if let other = seen[id], other != i.title { clashes.append("\(other) / \(i.title)") } else { seen[id] = i.title }
            }
            self.expect(clashes.isEmpty, "no two menu items share a shortcut" + (clashes.isEmpty ? "" : ": \(clashes)"))
            // Format commands are dimmed while something other than an editable editor is the target.
            let item = NSApp.mainMenu?.items.compactMap { $0.submenu }.flatMap { $0.items }.first { $0.title == "Bold" }
            self.expect(item.map { a.validateMenuItem($0) } == true, "Format ▸ Bold is enabled while the editor is the target")
            a.textView.isEditable = false
            self.expect(item.map { a.validateMenuItem($0) } == false, "…and disabled when the editor can't be edited")
            a.textView.isEditable = true
        }
        // ---- editing behaviours (2.4): Return, Backspace, Tab and paste go through MarkdownEdit -----------------------------------------
        add(0.1) {
            newScratch("x")
            func type(_ name: String, _ marked: String, _ action: () -> Void, becomes expected: String) {
                let (text, sel) = parseMarkedForWalkthrough(marked)
                tv.string = text; tv.setSelectedRange(sel)
                action()
                let got = renderMarkedForWalkthrough(tv.string, tv.selectedRange())
                self.expect(got == expected, "\(name): \(marked.debugDescription) → \(got.debugDescription)" + (got == expected ? "" : " (expected \(expected.debugDescription))"))
            }
            let ret = { tv.insertNewline(nil) }, back = { tv.deleteBackward(nil) }, tab = { tv.insertTab(nil) }, backtab = { tv.insertBacktab(nil) }
            type("Return continues a bullet", "- item¦", ret, becomes: "- item\n- ¦")
            type("Return numbers the next item", "1. one¦", ret, becomes: "1. one\n2. ¦")
            type("Return starts an unchecked task", "- [x] done¦", ret, becomes: "- [x] done\n- [ ] ¦")
            type("Return in a quote continues it", "> quote¦", ret, becomes: "> quote\n> ¦")
            type("Return splits an item at the caret", "- ab¦cd", ret, becomes: "- ab\n- ¦cd")
            type("Return on an empty item ends the list", "- ¦", ret, becomes: "¦")
            type("Return left of the marker opens a line above (it used to give \"- - x\")", "¦- x", ret, becomes: "\n¦- x")
            type("Return in a paragraph is an ordinary newline", "plain¦", ret, becomes: "plain\n¦")
            type("Return inside a fenced block is an ordinary newline", "```\n- x¦\n```", ret, becomes: "```\n- x\n¦\n```")
            type("Backspace after a bullet marker removes the marker", "- ¦item", back, becomes: "¦item")
            type("Backspace after a heading marker removes it", "## ¦Title", back, becomes: "¦Title")
            type("Backspace elsewhere is an ordinary delete", "- it¦em", back, becomes: "- i¦em")
            type("Tab nests a list item", "- a¦", tab, becomes: "  - a¦")
            type("⇧Tab un-nests it", "  - a¦", backtab, becomes: "- a¦")
            type("Tab on an empty line inserts the indent", "¦", tab, becomes: "  ¦")
            type("Tab moves between table cells", "| a | b |\n|---|---|\n| ¦c | d |", tab, becomes: "| a | b |\n|---|---|\n| c |¦ d |")
            // A URL on the clipboard pasted over selected text makes a link of it.
            Runtime.pasteboard.clearContents(); Runtime.pasteboard.setString("https://example.com", forType: .string)
            type("Pasting a URL over selected text links it", "see ‹docs› now", { tv.paste(nil) }, becomes: "see [docs](https://example.com)¦ now")
            type("Pasting a URL with nothing selected pastes it as text", "go ¦", { tv.paste(nil) }, becomes: "go https://example.com¦")
            Runtime.pasteboard.clearContents(); Runtime.pasteboard.setString("not a url", forType: .string)
            type("Pasting ordinary text over a selection replaces it", "see ‹docs› now", { tv.paste(nil) }, becomes: "see not a url¦ now")
            Runtime.pasteboard.clearContents()
            // One ⌘Z undoes a whole Return-continuation.
            tv.string = "- item"; tv.setSelectedRange(NSRange(location: 6, length: 0)); tv.undoManager?.removeAllActions()
            tv.insertNewline(nil); tv.undoManager?.undo()
            self.expect(tv.string == "- item", "one ⌘Z undoes a list continuation (\(tv.string.debugDescription))")
        }
        // ---- editor polish (2.2b/2.2d/2.3): hanging indents, • bullets, ⌘-click links, the empty-note placeholder ----------------------------------------
        add(0.2) {
            if Prefs.rawMode { a.toggleDisplayMode() }
            newScratch("x")
            let long = "- a long list item that keeps going and going until it has to wrap onto a second and third line of text\n1. a numbered item that also runs long enough to wrap onto another line of this narrow pad\n> a quote that is long enough that it too must wrap onto a following line in the editor\nplain"
            tv.string = long
            tv.setSelectedRange(NSRange(location: (long as NSString).length, length: 0))
            func headIndent(_ i: Int) -> CGFloat { (tv.textStorage?.attribute(.paragraphStyle, at: i, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 0 }
            let base = editorFont()
            let dash = ("- " as NSString).size(withAttributes: [.font: base]).width
            self.expect(abs(headIndent(0) - dash) < 0.5 && headIndent(2) > 0, "a wrapped bullet lines up under its text (hang \(headIndent(0)) pt ≈ the width of \"- \" = \(dash))")
            let ns = tv.string as NSString
            self.expect(headIndent(ns.range(of: "1. a numbered").location) > dash && headIndent(ns.range(of: "> a quote").location) > 0 && headIndent(ns.range(of: "plain").location) == 0,
                        "numbered items and quotes hang too, plain paragraphs don't")
            // The bullet is drawn as •; the text is still "-" (Raw mode shows it as typed).
            func glyph(of c: unichar) -> CGGlyph { var ch = c, g: CGGlyph = 0; _ = CTFontGetGlyphsForCharacters(base as CTFont, &ch, &g, 1); return g }
            if let lm = tv.layoutManager {
                lm.ensureLayout(for: tv.textContainer!)
                self.expect(lm.cgGlyph(at: 0) == glyph(of: 0x2022) && tv.string.hasPrefix("- "), "a bullet list's marker is drawn as • while the text stays \"-\"")
                a.toggleDisplayMode()
                lm.ensureLayout(for: tv.textContainer!)
                self.expect(lm.cgGlyph(at: 0) == glyph(of: 0x2D), "Raw mode shows the marker as typed")
                a.toggleDisplayMode()
            }
            self.snap("12-lists-wrapped")
        }
        add(0.1) {
            let text = "see [docs](https://example.com/a) and [bad](javascript:alert(1)) and [mail](mailto:a@b.c)\n```\n[in code](https://example.com/c)\n```"
            tv.string = text
            let ns = text as NSString
            let https = tv.linkURL(at: ns.range(of: "docs").location + 1), onAddress = tv.linkURL(at: ns.range(of: "example.com/a").location + 2)
            self.expect(https?.absoluteString == "https://example.com/a" && onAddress?.absoluteString == "https://example.com/a", "⌘-click targets a Markdown link's text or its address: \(String(describing: https))")
            self.expect(tv.linkURL(at: ns.range(of: "bad").location + 1) == nil, "only http, https and mailto links open — a javascript: link does nothing")
            self.expect(tv.linkURL(at: ns.range(of: "mail").location + 1)?.scheme == "mailto", "mailto links open")
            self.expect(tv.linkURL(at: 0) == nil && tv.linkURL(at: ns.range(of: "in code").location + 1) == nil, "plain text and links inside a code block do nothing")
            let opened0 = PreviewLog.count("open-url")
            _ = tv.openLink(at: ns.range(of: "docs").location + 1)
            self.expect(PreviewLog.count("open-url") == opened0 + 1, "a ⌘-click opens the link (a preview records it instead of launching anything)")
        }
        add(0.1) {
            // An empty note shows "Start typing…" (drawn, not typed); a note with text does not.
            func inkPixels() -> Int {
                tv.display()
                let rect = NSRect(x: 0, y: 0, width: 360, height: 70)
                guard let rep = tv.bitmapImageRepForCachingDisplay(in: rect) else { return 0 }
                tv.cacheDisplay(in: rect, to: rep)
                guard let data = rep.bitmapData, let bg = tv.backgroundColor.usingColorSpace(.sRGB) else { return 0 }
                let br = Int((bg.redComponent * 255).rounded()), bgc = Int((bg.greenComponent * 255).rounded()), bb = Int((bg.blueComponent * 255).rounded())
                var n = 0
                for i in 0..<(rep.pixelsWide * rep.pixelsHigh) {
                    let o = i * rep.samplesPerPixel
                    if abs(Int(data[o]) - br) + abs(Int(data[o + 1]) - bgc) + abs(Int(data[o + 2]) - bb) > 24 { n += 1 }
                }
                return n
            }
            tv.string = ""
            let empty = inkPixels()
            tv.string = "x"
            let one = inkPixels()
            self.expect(empty > 150 && one < empty / 2, "an empty note shows a faint \"Start typing…\" and a note with text doesn't (\(empty) vs \(one) ink pixels)")
        }
        // ---- the live-preview styler (2.2a): what is concealed, revealed, styled ----------------------------------------------------
        func concealed(_ i: Int) -> Bool { tv.textStorage?.attribute(.jotConceal, at: i, effectiveRange: nil) != nil }
        func font(_ i: Int) -> NSFont? { tv.textStorage?.attribute(.font, at: i, effectiveRange: nil) as? NSFont }
        func hiddenIndices(_ n: Int) -> [Int] { (0..<n).filter(concealed) }
        add(0.1) {
            if Prefs.rawMode { a.toggleDisplayMode() }
            let base = editorFont().pointSize
            tv.string = "# \nHello"
            tv.setSelectedRange(NSRange(location: 8, length: 0))
            self.expect((font(3)?.pointSize ?? 0) <= base + 0.5, "the line after a bare \"# \" is body text, not a heading (the old regex crossed newlines)")
            tv.string = "# Title\nbody"
            tv.setSelectedRange(NSRange(location: 11, length: 0))
            self.expect(concealed(0) && concealed(1) && (font(2)?.pointSize ?? 0) > base * 1.4, "a heading's # is hidden and its text enlarged while the caret is elsewhere")
            tv.setSelectedRange(NSRange(location: 3, length: 0))
            self.expect(!concealed(0) && !concealed(1), "…and the # is shown while the caret is on that line")
            tv.string = "***x***\nother"
            tv.setSelectedRange(NSRange(location: 12, length: 0))
            self.expect(hiddenIndices(7) == [0, 1, 2, 4, 5, 6], "***x*** hides all six markers when the caret is elsewhere: \(hiddenIndices(7))")
            let xFont = font(3)?.fontDescriptor.symbolicTraits
            self.expect(xFont?.contains(.bold) == true && xFont?.contains(.italic) == true, "…and x is bold italic")
            tv.setSelectedRange(NSRange(location: 3, length: 0))
            self.expect(hiddenIndices(7).isEmpty, "…and shows them all while the caret is inside")
        }
        add(0.1) {
            // Inclusive edges: the markers show when the caret is right before, inside, or right after the span — not one further.
            tv.string = "a **b** c d"
            var states: [Int: Bool] = [:]
            for caret in [0, 1, 2, 5, 7, 8, 9] { tv.setSelectedRange(NSRange(location: caret, length: 0)); states[caret] = concealed(2) }
            self.expect(states[0] == true && states[1] == true && states[2] == false && states[5] == false && states[7] == false && states[8] == true && states[9] == true,
                        "a span's markers show for a caret on it or at its edges only: concealed by caret \(states.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" })")
            tv.string = "x ~~gone~~ and `code` here"
            tv.setSelectedRange(NSRange(location: 25, length: 0))
            let strike = tv.textStorage?.attribute(.strikethroughStyle, at: 5, effectiveRange: nil) as? Int
            let chip = tv.textStorage?.attribute(.jotChip, at: 17, effectiveRange: nil)
            self.expect((strike ?? 0) != 0 && chip != nil && concealed(2) && concealed(15), "strikethrough and inline code are styled and their markers hidden")
        }
        add(0.1) {
            // The inline-code chip is painted by JotLayoutManager. TextKit's own background went missing for a code span
            // on a later line when an earlier line of the paragraph carried a struck word and markers were concealed.
            let sample = "A quick **bold** word, some *italic*, ~~struck~~ text and `inline code`."
            let view = EditorKit.makeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
            let styler = MarkdownStyler(); styler.baseFont = { editorFont() }; styler.textColor = { .white }
            view.backgroundColor = NSColor(srgbRed: 0.11, green: 0.114, blue: 0.125, alpha: 1)
            view.textContainerInset = JotUI.editorInset
            view.textStorage?.delegate = styler
            view.layoutManager?.delegate = concealLayoutDelegate
            view.string = sample
            let scroll = NSScrollView(frame: view.frame); scroll.documentView = view
            let win = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 400, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = scroll; win.orderFrontRegardless()
            view.layoutManager?.ensureLayout(for: view.textContainer!)
            view.display()
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            var tinted = 0
            if let data = rep.bitmapData, rep.bitsPerSample == 8 {   // raw bytes: colorAt(x:y:) converts colour spaces and drifts
                for i in 0..<(rep.pixelsWide * rep.pixelsHigh) {
                    let o = i * rep.samplesPerPixel
                    if abs(Int(data[o]) - 51) <= 2, abs(Int(data[o + 1]) - 52) <= 2, abs(Int(data[o + 2]) - 55) <= 2 { tinted += 1 }
                }
            }
            let codeAt = (sample as NSString).range(of: "inline code")
            let rects = (view.layoutManager as? JotLayoutManager)?.runRects(characters: codeAt) ?? []
            self.expect(tinted > 1000 && rects.count == 1 && rects[0].width > 80 && rects[0].width < 100,
                        "the inline-code chip is painted after a struck word on an earlier wrapped line (\(tinted) tinted pixels, rects \(rects))")
            win.orderOut(nil)
        }
        add(0.1) {
            // A fence changes what the lines after it are: deleting the opening fence turns the code line into a heading, and back.
            let base = editorFont().pointSize
            tv.string = "```\n# h\n```\nx"
            tv.setSelectedRange(NSRange(location: 13, length: 0))
            self.expect((font(5)?.pointSize ?? 0) <= base + 0.5, "inside a fence a # line is code, not a heading")
            tv.replaceCharacters(in: NSRange(location: 0, length: 4), with: "")
            self.expect((font(1)?.pointSize ?? 0) > base * 1.3, "removing the opening fence restyles the lines after it (the # line becomes a heading)")
            tv.replaceCharacters(in: NSRange(location: 0, length: 0), with: "```\n")
            self.expect((font(5)?.pointSize ?? 0) <= base + 0.5, "adding the fence back turns it into code again")
        }
        add(0.1) {
            // Raw mode: every marker visible and dimmed, one font.
            let base = editorFont().pointSize
            tv.string = "# Title\n**bold** and *it*\n- [ ] task"
            tv.setSelectedRange(NSRange(location: 30, length: 0))
            a.toggleDisplayMode()
            self.expect(Prefs.rawMode && hiddenIndices(tv.string.utf16.count).isEmpty && (font(2)?.pointSize ?? 0) <= base + 0.5, "Raw mode shows every marker in one uniform font")
            a.toggleDisplayMode()
            self.expect(!Prefs.rawMode && concealed(0), "…and Formatted mode hides them again")
        }
        add(0.1) {
            tv.string = ""
            tv.setSelectedRange(NSRange(location: 0, length: 0))
        }
        // Messages are toasts: one at a time, newest wins, never over the note's title, gone after a few seconds.
        add(0.1) { ToastCenter.duration = 0.8; a.flash("first") }
        add(0.3) { a.flash("second") }
        add(0.3) {
            let toast = ToastCenter.shared.toast(in: a.dropdown)
            self.expect(toast?.label.stringValue == "second" && a.dropdown.contentView?.subviews.filter { $0 is ToastView }.count == 1, "a second message replaces the first (one toast on screen)")
            self.expect(a.statusLabel.stringValue == a.titleForNote(a.current!), "a message never replaces the note's title (\(a.statusLabel.stringValue.debugDescription))")
            self.snap("11-toast")
        }
        add(1.3) { self.expect(ToastCenter.shared.toast(in: a.dropdown) == nil, "the toast is gone after its time") }
        add(0.1) {
            // State badges next to the title: pinned and reminder-set appear only when they apply; the title follows the first line.
            newScratch("# First title\nbody")
            _ = a.saveCurrent(reloadRow: true)
            self.expect(a.statusLabel.stringValue == "First title", "the header title follows the note's first line, without its # (\(a.statusLabel.stringValue.debugDescription))")
            let pinnedBefore = a.isPinned
            if !pinnedBefore { a.togglePin(nil) }
            self.expect(a.pinButton?.isHidden == false, "a pinned pad shows its pin badge")
            a.togglePin(nil)
            self.expect(a.pinButton?.isHidden == true, "…and hides it again")
            a.currentMeta.reminder = Date().addingTimeInterval(3600); a.updateHeaderBadges()
            self.expect(a.reminderButton?.isHidden == false, "a note with a reminder shows its bell badge")
            a.currentMeta.reminder = nil; a.updateHeaderBadges()
            self.expect(a.reminderButton?.isHidden == true, "…and hides it when the reminder is gone")
            let viewTitles = NSApp.mainMenu?.items.compactMap { $0.submenu }.flatMap { $0.items }.map { $0.title } ?? []
            self.expect(viewTitles.contains("Show/Hide Formatting Bar"), "View has Show/Hide Formatting Bar (⌥⌘T)")
        }
        add(0.1) {
            // Toast with an action; the action runs once and dismisses it.
            var undone = 0
            a.flash("Moved to Recently Deleted", actionTitle: "Undo") { undone += 1 }
            ToastCenter.shared.toast(in: a.dropdown)?.actionButton?.performClick(nil)
            self.expect(undone == 1 && ToastCenter.shared.toast(in: a.dropdown) == nil, "a toast's Undo button runs its action once and dismisses the toast")
            ToastCenter.duration = 4
        }
        // ---- delete + Undo (5.6): Recently Deleted, an Undo toast, nothing jumps, a visible Restore -------------------------------------
        add(0.2) {
            newScratch("# Doomed note\nbody text")
            guard let url = a.current else { self.failures.append("no scratch note for the delete check"); return }
            var meta = a.store.readMeta(url); meta.reminder = Date().addingTimeInterval(7200); a.store.writeMeta(meta, to: url)
            _ = a.saveCurrent()
            let bodyBefore = a.store.readRaw(url)
            let modified = a.store.modificationDate(url)
            let trash0 = a.store.trashedAll().count
            a.deleteNotes([url])
            self.expect(!FileManager.default.fileExists(atPath: url.path) && a.store.trashedAll().count == trash0 + 1, "Delete moves the note to Recently Deleted")
            let toast = ToastCenter.shared.toast(in: a.dropdown)
            self.expect(toast?.label.stringValue == "Moved to Recently Deleted" && toast?.actionButton?.title == "Undo", "…and offers Undo in a toast")
            let unAfterDelete = PreviewLog.count("UN")
            toast?.actionButton?.performClick(nil)
            self.expect(FileManager.default.fileExists(atPath: url.path) && a.store.readRaw(url) == bodyBefore && a.store.trashedAll().count == trash0,
                        "Undo puts the note back under its own name with its content intact")
            self.expect(a.current == url && tv.string.hasPrefix("# Doomed note"), "…selects it again")
            // (Foundation sets file dates with microsecond resolution, so "the same date" means within a millisecond.)
            self.expect(abs((a.store.modificationDate(url) ?? .distantPast).timeIntervalSince(modified ?? .distantFuture)) < 0.001, "…with its old modification date, so it keeps its place in the list")
            self.expect(PreviewLog.count("UN") > unAfterDelete, "…and schedules its reminder again")
        }
        add(0.2) {
            // A note that isn't open can be deleted without the editor moving; several at once share one toast.
            func make(_ text: String) -> URL { let u = try! a.store.create(); try! text.write(to: u, atomically: true, encoding: .utf8); return u }
            let other = make("other note"), d = make("note d"), e = make("note e")
            newScratch("the note I am editing")
            let open = a.current, textBefore = tv.string
            a.deleteNotes([other])
            self.expect(a.current == open && tv.string == textBefore && !FileManager.default.fileExists(atPath: other.path),
                        "deleting a note that isn't open leaves the editor exactly where it was")
            a.deleteNotes([d, e])
            let toast = ToastCenter.shared.toast(in: a.dropdown)
            self.expect(toast?.label.stringValue == "2 notes moved to Recently Deleted" && a.current == open, "deleting two notes makes one toast and still doesn't move the editor")
            toast?.actionButton?.performClick(nil)
            self.expect(FileManager.default.fileExists(atPath: d.path) && FileManager.default.fileExists(atPath: e.path) && a.current == open, "…and one Undo brings both back without moving the editor")
        }
        add(0.2) {
            // Recently Deleted: the header's New becomes a visible Restore.
            let u = try! a.store.create(); try! "to restore".write(to: u, atomically: true, encoding: .utf8)
            a.rebuildNotes(); a.tableView.reloadData()
            a.deleteNotes([u])
            a.toggleTrashView()
            self.expect(a.viewingTrash && a.newButton.title == "Restore", "in Recently Deleted the header's New button becomes Restore")
            a.tableView.deselectAll(nil); a.updateTrashChrome()
            self.expect(!a.newButton.isEnabled, "…dimmed while no deleted note is selected")
            if let row = a.trashed.firstIndex(where: { $0.lastPathComponent == u.lastPathComponent }) { a.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            self.expect(a.newButton.isEnabled, "…and enabled once one is selected")
            let before = a.trashed.count
            a.restoreSelectedTrashed()
            self.expect(a.trashed.count == before - 1 && FileManager.default.fileExists(atPath: a.store.dir.appendingPathComponent(u.lastPathComponent).path), "Restore takes the selected note out of Recently Deleted and back into the notes")
            a.toggleTrashView()
            a.hideSidebar()
            self.expect(!a.viewingTrash && a.newButton.title == "New", "leaving Recently Deleted turns the button back into New")
        }
        // A programmatic move must not turn the tray into a "detached" window.
        add(0.1) {
            present()
            Prefs.detached = false
            a.dropdown.setFrameOrigin(NSPoint(x: -3900, y: 210))
            self.expect(!Prefs.detached, "a programmatic move of the pad does not detach it (only a mouse drag does)")
            AppDelegate.previewMouseDown = true                       // …and with the button down, the same move is a drag
            a.dropdown.setFrameOrigin(NSPoint(x: -3880, y: 230))
            self.expect(Prefs.detached, "a move with the left button down detaches the pad")
            AppDelegate.previewMouseDown = false
            Prefs.detached = false
            Prefs.detached = false
            self.park(a.dropdown)
            tv.string = ""   // leave the scratch note empty; sweep it away
            a.reloadNotes(selectFirst: false)
            a.select(self.url(1))
            for u in a.store.all() where !Fixtures.library().contains(where: { u.lastPathComponent == $0.fileName }) { try? FileManager.default.removeItem(at: u) }
            a.reloadNotes(selectFirst: false)
            a.select(self.url(1))
        }

        // --- 07 big notes: timings and styling passes ----------------------------------------------------
        add(0.2) {
            let passes0 = MarkdownStyler.styleAllCount
            let t0 = CFAbsoluteTimeGetCurrent()
            a.select(self.url(10))
            let t1 = CFAbsoluteTimeGetCurrent()
            if let lm = tv.layoutManager, let tc = tv.textContainer { lm.ensureLayout(forBoundingRect: tv.visibleRect, in: tc) }
            let t2 = CFAbsoluteTimeGetCurrent()
            self.probe("open the 200 KB note", "select \(Int((t1 - t0) * 1000)) ms + first-screen layout \(Int((t2 - t1) * 1000)) ms (budget 150 ms)")
            self.expect(MarkdownStyler.styleAllCount - passes0 == 1, "opening a note styles it in ONE full pass (\(MarkdownStyler.styleAllCount - passes0); it used to be 2–3)")
            // Where an open goes: set the text, style it once, lay out what's on screen.
            do {
                let big = a.store.read(self.url(10))
                a.mdStyler.isSuspended = true
                let u0 = CFAbsoluteTimeGetCurrent(); tv.string = big
                let u1 = CFAbsoluteTimeGetCurrent(); a.mdStyler.isSuspended = false
                if let ts = tv.textStorage { a.mdStyler.styleAll(ts) }
                let u2 = CFAbsoluteTimeGetCurrent()
                if let lm = tv.layoutManager, let tc = tv.textContainer { lm.ensureLayout(forBoundingRect: tv.visibleRect, in: tc) }
                let u3 = CFAbsoluteTimeGetCurrent()
                self.probe("open the 200 KB note, step by step", "set text \(Int((u1 - u0) * 1000)) ms · style \(Int((u2 - u1) * 1000)) ms · first-screen layout \(Int((u3 - u2) * 1000)) ms")
            }
            tv.setSelectedRange(NSRange(location: 100_000, length: 0))
            let t3 = CFAbsoluteTimeGetCurrent()
            tv.insertText("x", replacementRange: tv.selectedRange())
            self.probe("type one character in the middle of the 200 KB note", "\(Int((CFAbsoluteTimeGetCurrent() - t3) * 1000)) ms")
            let t4 = CFAbsoluteTimeGetCurrent()
            a.select(self.url(11))
            self.probe("open the 50 KB single-line note", "\(Int((CFAbsoluteTimeGetCurrent() - t4) * 1000)) ms")
        }

        // --- 08 other windows ------------------------------------------------------------------------------
        var noteWindow: NoteWindowController?
        add(0.2) {
            a.select(self.url(5))
            let nc = a.openWindow(for: self.url(1))
            self.park(nc.window, NSSize(width: 440, height: 440))
            noteWindow = nc
        }
        add(0.5) {
            if let w = noteWindow?.window { self.snap("06-undocked-note-window", window: w, includeTitleBar: true) }
            // 4.3: native chrome, and one editor per note.
            if let nc = noteWindow {
                let w = nc.window
                self.expect(w.standardWindowButton(.closeButton)?.isHidden == false && w.standardWindowButton(.miniaturizeButton)?.isHidden == false && w.titleVisibility == .visible,
                            "an undocked note window has real traffic lights and a visible title")
                self.expect(w.title == "Welcome to Jot", "…titled with the note's plain title (\(w.title.debugDescription))")
                self.expect(w.titlebarAccessoryViewControllers.count == 1 && [nc.toolsToggle, nc.shareButton, nc.pinButton].allSatisfy { ($0?.accessibilityLabel() ?? "").count > 3 },
                            "…with labelled Aa, Share and Pin buttons in the title bar")
                self.expect(nc.editorScroll.frame.maxY <= nc.window.contentView!.bounds.height - (nc.window.contentView!.bounds.height - nc.window.contentLayoutRect.height) + 0.5,
                            "…and its text sits below the title bar")
                // The note that is open in a window is raised, not loaded into the pad a second time.
                a.select(self.url(2))
                let padNote = a.current
                a.openOrSelect(nc.url)
                self.expect(a.current == padNote && a.noteWindows.contains { $0 === nc }, "picking a note that has its own window brings that window forward and leaves the pad where it was")
                // Opening the pad's own note in a window moves the pad on to a blank note.
                let mine = a.current!
                let second = a.openWindow(for: mine)
                self.park(second.window)
                self.expect(a.current != mine && a.noteWindows.contains { $0 === second }, "opening the pad's own note in a window moves the pad on to another note (one editor per note)")
                second.window.close()
            }
            noteWindow?.window.close()
        }
        // --- 08 first run (8.1/8.2) and Settings (8.3) ------------------------------------------------------------------------------------------
        add(0.2) {
            // The Carbon constants HotkeyDefaults (Foundation-only) spells out must match the real ones.
            self.expect(HotkeyDefaults.current.keyCode == Int(kVK_ANSI_J) && HotkeyDefaults.legacy.keyCode == Int(kVK_ANSI_J)
                        && HotkeyDefaults.legacy.carbon == Int(controlKey) && HotkeyDefaults.current.carbon == Int(optionKey | cmdKey),
                        "HotkeyDefaults' Carbon constants match the real ones")
            // This launch was a new install: ⌥⌘J, written down. Opening at login was never registered behind the person's back.
            self.expect(Prefs.hotkeyDisplay == "⌥⌘J" && Prefs.hotkeyKeyCode == 38 && Prefs.hotkeyCarbon == UInt32(optionKey | cmdKey), "a new install's default shortcut is ⌥⌘J (\(Prefs.hotkeyDisplay))")
            self.expect(PreviewLog.count("login-item") == 0 && !a.loginItemEnabled, "Jot did not register itself to open at login")
            // An existing install (welcomed before, no shortcut stored) keeps ⌃J — and it is written down so a later default change can't move it.
            let saved = (Prefs.d.object(forKey: "hotkeyKeyCode"), Prefs.d.object(forKey: "hotkeyCarbon"), Prefs.d.object(forKey: "hotkeyDisplay"), Prefs.hasShownWelcome)
            for key in ["hotkeyKeyCode", "hotkeyCarbon", "hotkeyDisplay"] { Prefs.d.removeObject(forKey: key) }
            Prefs.hasShownWelcome = true
            let veteran = a.resolveHotkeyDefaults()
            self.expect(veteran.display == "⌃J" && Prefs.hotkeyDisplay == "⌃J" && Prefs.hotkeyCarbon == UInt32(controlKey), "an existing install that never chose a shortcut keeps ⌃J (\(Prefs.hotkeyDisplay))")
            for key in ["hotkeyKeyCode", "hotkeyCarbon", "hotkeyDisplay"] { Prefs.d.removeObject(forKey: key) }
            Prefs.hasShownWelcome = false
            self.expect(a.resolveHotkeyDefaults().display == "⌥⌘J" && Prefs.hotkeyDisplay == "⌥⌘J", "a brand-new install gets ⌥⌘J and it is written down")
            if let k = saved.0 { Prefs.d.set(k, forKey: "hotkeyKeyCode") }; if let c = saved.1 { Prefs.d.set(c, forKey: "hotkeyCarbon") }; if let d = saved.2 { Prefs.d.set(d, forKey: "hotkeyDisplay") }
            Prefs.hasShownWelcome = saved.3
            // The welcome note: seeded only into an empty library, naming the live shortcut.
            let root = Runtime.previewRoot.appendingPathComponent("welcome-check")
            try? FileManager.default.createDirectory(at: root.appendingPathComponent("n"), withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: root.appendingPathComponent("t"), withIntermediateDirectories: true)
            let empty = NotesStore(dir: root.appendingPathComponent("n"), trashDir: root.appendingPathComponent("t"))
            Prefs.hasShownWelcome = false
            let seeded = a.seedWelcomeNoteIfNeeded(into: empty)
            self.expect(seeded != nil && empty.read(seeded!).hasPrefix("# Welcome to Jot") && empty.read(seeded!).contains("Press ⌥⌘J anywhere") && Prefs.hasShownWelcome, "a new install's first note is the welcome note, naming its shortcut")
            Prefs.hasShownWelcome = false
            self.expect(a.seedWelcomeNoteIfNeeded(into: a.store) == nil, "a library that already has notes is never given a welcome note")
            Prefs.hasShownWelcome = saved.3
            if let u = seeded {                                              // show it once, as a first-time person would see it
                let body = empty.read(u)
                newScratch(body)
                self.snap("08-welcome-note")
                tv.string = ""; _ = a.saveCurrent()
            }
            try? FileManager.default.removeItem(at: root)
        }
        var settings: SettingsController?
        add(0.2) {
            let s = SettingsController(app: a)
            self.park(s.window); s.window.orderFrontRegardless()
            settings = s
        }
        add(0.5) {
            guard let s = settings else { return }
            self.snap("07-settings", window: s.window)
            self.expect(s.recorder.title == Prefs.hotkeyDisplay, "Settings shows the live shortcut (\(s.recorder.title))")
            self.expect(s.chosenBackgroundName == "Black" || s.chosenBackgroundName == "Dark" || s.chosenBackgroundName == nil, "Settings marks the current background preset (\(s.chosenBackgroundName ?? "custom"))")
            s.choose(background: "Paper")
            self.expect(Prefs.editorBGHex.uppercased() == "F6F2E9" && s.chosenBackgroundName == "Paper", "choosing the Paper swatch sets the background everywhere (\(Prefs.editorBGHex))")
            s.choose(background: "Dark")
            s.set(rawMode: true)
            self.expect(Prefs.rawMode, "Settings can open notes as Markdown source")
            s.set(rawMode: false)
            self.expect(!Prefs.rawMode, "…and back to formatted")
            s.set(spellCheck: true)
            // (A headless process has no spelling service, so NSTextView reports false whatever it is told; what can be checked is the call.)
            self.expect(Prefs.spellcheck && PreviewLog.events.last { $0.kind == "spellcheck" }?.detail == "on", "the spell-checking switch is applied to the editors")
            s.set(spellCheck: false)
            self.expect(!Prefs.spellcheck && PreviewLog.events.last { $0.kind == "spellcheck" }?.detail == "off", "…and turned off again (off by default)")
            s.set(loginItem: true)
            self.expect(PreviewLog.count("login-item") == 1, "the login-item switch calls the system once (stubbed in a preview)")
            self.expect(s.window.frame.height < 680 && s.window.frame.height > 300, "the Settings window fits its content (\(Int(s.window.frame.height)) pt tall)")
            s.window.orderOut(nil)
        }

        // --- 08b sending (6.1/6.2): the clipboard you had comes back; failures say what to do ------------------------------------------------------
        add(0.2) {
            let pb = Runtime.pasteboard
            pb.clearContents(); pb.setString("what you had copied", forType: .string)
            let item = NSPasteboardItem(); item.setString("<b>rich</b>", forType: .html)
            pb.writeObjects([item])
            let saved = AppDelegate.snapshotPasteboard(pb)
            pb.clearContents(); pb.setString("the note, borrowed for a paste", forType: .string)
            AppDelegate.restorePasteboard(pb, saved)
            self.expect(pb.string(forType: .html) == "<b>rich</b>" && pb.string(forType: .string) != "the note, borrowed for a paste", "borrowing the clipboard for Stickies gives back what was on it, every type")
            pb.clearContents()
            let before = PreviewLog.count("open-settings")
            AppDelegate.openAutomationSettings()
            self.expect(PreviewLog.count("open-settings") == before + 1, "the failure toast's Open Settings… goes to Privacy & Security ▸ Automation (a preview only records it)")
        }

        // --- 08d reminders and sessions (7): a reminder that can't ring says so; the fresh-note habit is a choice -------------------------------------
        add(0.2) {
            a.reminderNotAuthorized()
            let toast = ToastCenter.shared.toast(in: a.dropdown)
            self.expect((toast?.label.stringValue ?? "").contains("Notifications are off") && toast?.actionButton?.title == "Open Settings…", "a reminder that notifications will not deliver says so, with a way to fix it")
            let before = PreviewLog.count("open-settings")
            toast?.actionButton?.performClick(nil)
            self.expect(PreviewLog.count("open-settings") == before + 1, "…and the button opens the notification settings (recorded, not launched, in a preview)")
            let lastActivity = a.lastActivity
            a.lastActivity = nil
            Prefs.startOnNewNote = true
            self.expect(a.shouldOpenFresh(), "by default the first open of a session starts on a new note")
            Prefs.startOnNewNote = false
            self.expect(!a.shouldOpenFresh(), "…unless Settings ▸ Start each session on a new note is off")
            Prefs.startOnNewNote = true
            a.lastActivity = lastActivity
        }

        // --- 08c accessibility (9): labels on every surface, rows that read well, states that are spoken --------------------------------------------
        add(0.2) {
            a.rebuildNotes(); a.tableView.reloadData()
            a.sidebarWidth = 280; a.showSidebar()
            self.auditAccessibility(a.dropdown.contentView!, label: "pad with the sidebar open")
            if let cell = a.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NoteListCell {
                let spoken = cell.accessibilityLabel() ?? ""
                self.expect(spoken.contains(a.titleForNote(a.notes[0])) && spoken.contains(","), "a sidebar row is read as one phrase — title, state, snippet, time: \(spoken.debugDescription)")
            }
            self.expect(a.searchField.accessibilityLabel() == "Search notes", "the search field says what it is")
            self.expect(a.sidebarToggle.accessibilityValue() as? String == "shown", "the sidebar button says whether the list is shown")
            a.hideSidebar()
            let s = SettingsController(app: a)
            self.park(s.window); s.window.orderFrontRegardless()
            s.show()
            self.auditAccessibility(s.window.contentView!, label: "Settings window")
            s.window.orderOut(nil)
            a.flash("Accessibility check")
            if let toast = ToastCenter.shared.toast(in: a.dropdown) { self.expect((toast.accessibilityLabel() ?? "") == "Accessibility check" && toast.isAccessibilityElement(), "a toast is an accessibility element carrying its message") }
            if let item = a.statusItem?.button { self.expect(item.image?.isTemplate == true, "the menu-bar icon is a template image") } else { self.probe("menu-bar icon", "none in a preview") }
        }

        // --- 09 nothing escaped the sandbox ---------------------------------------------------------------
        add(0.2) {
            self.expect(PreviewLog.count("notes") == 0 && PreviewLog.count("stickies") == 0, "no Apple Notes / Stickies traffic")
            self.probe("intercepted notification calls", "\(PreviewLog.count("UN")) (stubbed; none reached the real notification center)")
            self.probe("intercepted storage errors", "\(PreviewLog.count("storage-error"))")
            self.finish()
        }
        next()
    }

    private func next() {
        guard !steps.isEmpty else { return }
        switch steps.removeFirst() {
        case .after(let delay, let action):
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { action(); self.next() }
        case .until(let timeout, let what, let condition):
            poll(Date().addingTimeInterval(timeout), what, condition)
        }
    }
    private func poll(_ deadline: Date, _ what: String, _ condition: @escaping () -> Bool) {
        if condition() { next(); return }
        if Date() > deadline { failures.append("timed out waiting for \(what)"); next(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.poll(deadline, what, condition) }
    }

    /// Every control a VoiceOver user can reach must say what it is.
    private func auditAccessibility(_ root: NSView, label: String) {
        var unlabeled: [String] = [], checked = 0
        func visit(_ v: NSView) {
            if !v.isHiddenOrHasHiddenAncestor, let control = v as? NSControl, !(control is NSScroller),
               !((control as? NSTextField).map { !$0.isEditable } ?? false) {
                checked += 1
                var names: [String] = [control.accessibilityLabel() ?? ""]
                if let button = control as? NSButton { names.append(button.title) }
                if let field = control as? NSTextField { names.append(field.placeholderString ?? "") }
                if names.allSatisfy({ $0.isEmpty }) {
                    unlabeled.append("\(type(of: control)) in \(control.superview.map { String(describing: type(of: $0)) } ?? "-")")
                }
            }
            v.subviews.forEach(visit)
        }
        visit(root)
        expect(unlabeled.isEmpty && checked > 0, "every visible control in the \(label) is labelled for VoiceOver (\(checked) checked)\(unlabeled.isEmpty ? "" : ": unlabelled \(unlabeled)")")
    }

    private func snap(_ name: String, window: NSWindow? = nil, includeTitleBar: Bool = false) {
        let w = window ?? app.dropdown!
        // The title bar (traffic lights, title, accessory buttons) belongs to the window's frame view, one level above the content.
        guard let view = includeTitleBar ? (w.contentView?.superview ?? w.contentView) : w.contentView else { return }
        view.layoutSubtreeIfNeeded(); view.display()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        // cacheDisplay skips the window's own background; composite onto it so plain windows are legible.
        guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        canvas.size = view.bounds.size   // points, so drawing below is in view coordinates (the context reads this at creation)
        guard let context = NSGraphicsContext(bitmapImageRep: canvas) else { return }
        var background = NSColor.windowBackgroundColor.cgColor
        w.effectiveAppearance.performAsCurrentDrawingAppearance { background = w.backgroundColor.cgColor }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.setFillColor(background)
        context.cgContext.fill(CGRect(origin: .zero, size: view.bounds.size))
        rep.draw(in: NSRect(origin: .zero, size: view.bounds.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        if let png = canvas.representation(using: .png, properties: [:]) {
            try? png.write(to: directory.appendingPathComponent(name + ".png"))
            log.append("snapshot: \(name)")
        }
    }

    private func finish() {
        let verdict = failures.isEmpty ? "PREVIEW WALKTHROUGH OK" : "PREVIEW WALKTHROUGH FAILED"
        let report = (log + probes + failures.map { "FAILED: \($0)" } + [verdict]).joined(separator: "\n") + "\n"
        try? report.write(to: directory.appendingPathComponent("walkthrough.txt"), atomically: true, encoding: .utf8)
        FileHandle.standardError.write(Data(report.utf8))
        Runtime.resetPreviewState()
        exit(failures.isEmpty ? 0 : 1)
    }
}

// ‹selection› and ¦caret¦ notation for the walkthrough's typing checks (the unit tests have the same helpers).
func parseMarkedForWalkthrough(_ s: String) -> (String, NSRange) {
    var text = "", start = -1, end = -1, caret = -1, len = 0
    for ch in s {
        switch ch {
        case "‹": start = len
        case "›": end = len
        case "¦": caret = len
        default: text.append(ch); len += ch.utf16.count
        }
    }
    if caret >= 0 { return (text, NSRange(location: caret, length: 0)) }
    return (text, NSRange(location: max(start, 0), length: max(end - max(start, 0), 0)))
}
func renderMarkedForWalkthrough(_ text: String, _ sel: NSRange) -> String {
    let ns = text as NSString
    if sel.length == 0 { return ns.substring(to: sel.location) + "¦" + ns.substring(from: sel.location) }
    return ns.substring(to: sel.location) + "‹" + ns.substring(with: sel) + "›" + ns.substring(from: NSMaxRange(sel))
}
