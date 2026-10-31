// ============================================================================
// Jot — a tiny macOS menu-bar capture pad
// ----------------------------------------------------------------------------
// A note pad in the menu bar (note icon). Click it (or press the global shortcut) to drop
// down a dark "liquid glass" window: a fast editor that handles huge text, a notes list,
// and a bottom ACTION BAR that sends the note anywhere — Apple Notes, Stickies,
// Save-as-any-format, the system Share sheet, or Copy.
//
// Reuses the suite's chrome (resizable hidden-titlebar dropdown that anchors under
// the icon until moved then remembers its place, pin/always-on-top, minimize,
// configurable global hotkey, launch at login, first-click fix). See MAP.md.
// ============================================================================

import Cocoa
import Carbon
import ServiceManagement
import ApplicationServices   // AXIsProcessTrusted — Accessibility check for the Stickies keystroke path
import UserNotifications     // Reminders for jots

// ----------------------------------------------------------------------------
// MARK: - Settings (persisted in UserDefaults)
// ----------------------------------------------------------------------------
enum Prefs {
    static let d: UserDefaults = Runtime.isPreview ? UserDefaults(suiteName: Runtime.previewDomain)! : .standard
    static var hotkeyKeyCode: UInt32 {
        get { UInt32((d.object(forKey: "hotkeyKeyCode") as? Int) ?? Int(kVK_ANSI_J)) }
        set { d.set(Int(newValue), forKey: "hotkeyKeyCode") }
    }
    static var hotkeyCarbon: UInt32 {
        get { UInt32((d.object(forKey: "hotkeyCarbon") as? Int) ?? Int(controlKey)) }
        set { d.set(Int(newValue), forKey: "hotkeyCarbon") }
    }
    static var hotkeyDisplay: String {
        get { d.string(forKey: "hotkeyDisplay") ?? "⌃J" }
        set { d.set(newValue, forKey: "hotkeyDisplay") }
    }
    static var fontSize: Double {
        get { let v = d.double(forKey: "fontSize"); return v == 0 ? 13 : v }
        set { d.set(newValue, forKey: "fontSize") }
    }
    static var sidebarShown: Bool { get { d.object(forKey: "sidebarShown") as? Bool ?? false } set { d.set(newValue, forKey: "sidebarShown") } }
    static var sidebarWidth: CGFloat { get { CGFloat(d.object(forKey: "sidebarWidth") as? Double ?? 210) } set { d.set(Double(newValue), forKey: "sidebarWidth") } }
    static var editorBGHex: String { get { d.string(forKey: "editorBGHex") ?? "1C1D20" } set { d.set(newValue, forKey: "editorBGHex") } }
    static var fontFamily: String { get { d.string(forKey: "fontFamily") ?? "" } set { d.set(newValue, forKey: "fontFamily") } }
    static var detached: Bool { get { d.bool(forKey: "detached") } set { d.set(newValue, forKey: "detached") } }   // moved/pinned → normal window
    static var startOnNewNote: Bool { get { d.object(forKey: "startOnNewNote") as? Bool ?? true } set { d.set(newValue, forKey: "startOnNewNote") } }   // a new blank note on launch and after 30 idle minutes
    static var spellcheck: Bool { get { d.bool(forKey: "spellcheck") } set { d.set(newValue, forKey: "spellcheck") } }      // off by default: a notepad full of names and code
    static var hasShownWelcome: Bool { get { d.bool(forKey: "hasShownWelcome") } set { d.set(newValue, forKey: "hasShownWelcome") } }
    // Formatted (live preview: markers hidden except where you're editing) or raw Markdown.
    static var rawMode: Bool { get { d.string(forKey: "displayMode") == "raw" } set { d.set(newValue ? "raw" : "formatted", forKey: "displayMode") } }
    // Sidebar folders: the names in the order they were made (a folder with no notes yet still shows), and which are folded shut.
    static var folderOrder: [String] { get { d.stringArray(forKey: "folderOrder") ?? [] } set { d.set(newValue, forKey: "folderOrder") } }
    static var collapsedFolders: [String] { get { d.stringArray(forKey: "collapsedFolders") ?? [] } set { d.set(newValue, forKey: "collapsedFolders") } }
    static var toolsShown: Bool { get { d.object(forKey: "toolsShown") as? Bool ?? true } set { d.set(newValue, forKey: "toolsShown") } }   // formatting bar visible?

    // Which action-bar buttons are shown (all on by default).
    static func show(_ id: String) -> Bool { d.object(forKey: "show.\(id)") as? Bool ?? true }
    static func setShow(_ id: String, _ on: Bool) { d.set(on, forKey: "show.\(id)") }
}

func carbonModifiers(from f: NSEvent.ModifierFlags) -> UInt32 {
    var m: UInt32 = 0
    if f.contains(.command) { m |= UInt32(cmdKey) }
    if f.contains(.option)  { m |= UInt32(optionKey) }
    if f.contains(.control) { m |= UInt32(controlKey) }
    if f.contains(.shift)   { m |= UInt32(shiftKey) }
    return m
}
func keyName(_ keyCode: UInt16, _ chars: String?) -> String {
    let map: [UInt16: String] = [49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑"]
    if let n = map[keyCode] { return n }
    if let c = chars, !c.isEmpty, c != " " { return c.uppercased() }
    return "Key\(keyCode)"
}
func shortcutDisplay(_ f: NSEvent.ModifierFlags, _ keyCode: UInt16, _ chars: String?) -> String {
    var s = ""
    if f.contains(.control) { s += "⌃" }
    if f.contains(.option)  { s += "⌥" }
    if f.contains(.shift)   { s += "⇧" }
    if f.contains(.command) { s += "⌘" }
    return s + keyName(keyCode, chars)
}

func pinFill(_ child: NSView, in parent: NSView) {
    child.removeFromSuperview()
    child.translatesAutoresizingMaskIntoConstraints = false
    parent.addSubview(child)
    NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
        child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        child.topAnchor.constraint(equalTo: parent.topAnchor),
        child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
    ])
}
func makeGlassContentView() -> NSVisualEffectView { GlassView() }   // Preview.swift: also supplies a solid stand-in for snapshots

// Activates Jot — never in a snapshot run, which must not steal focus from whatever you're doing.
func jotActivate() {
    if Runtime.snapshotDirectory != nil { return }
    NSApp.activate(ignoringOtherApps: true)
}

// The one doorway to UserNotifications. A preview must never see (or clear) your real pending
// reminders: they're stored per bundle ID, and this process shares Jot's.
func notificationCenter() -> UNUserNotificationCenter? {
    if Runtime.isPreview { PreviewLog.record("UN"); return nil }
    return UNUserNotificationCenter.current()
}

// Shared, quiet chrome for the capture pad and detached editors.
enum JotUI {
    static let headerHeight: CGFloat = 48
    static let toolsHeight: CGFloat = 42
    static let folderRowHeight: CGFloat = 30       // a folder's header row in the notes list (a note's row is 52)
    static let editorInset = NSSize(width: 22, height: 20)

    static func button(_ symbol: String, label: String, target: AnyObject, action: Selector) -> NSButton {
        let b = NSButton(title: "", image: sym(symbol), target: target, action: action)
        b.bezelStyle = .texturedRounded
        b.isBordered = false
        b.imageScaling = .scaleProportionallyDown
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = label
        b.setAccessibilityLabel(label)
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 28),
            b.heightAnchor.constraint(equalToConstant: 28),
        ])
        return b
    }

    // A small state badge next to the note's title (pinned, reminder set): hidden unless it applies; a click opens its control.
    static func badge(_ symbol: String, label: String, tint: NSColor, target: AnyObject, action: Selector) -> NSButton {
        let b = NSButton(title: "", image: sym(symbol), target: target, action: action)
        b.isBordered = false
        b.imageScaling = .scaleProportionallyDown
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        b.contentTintColor = tint
        b.toolTip = label
        b.setAccessibilityLabel(label)
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant: 20), b.heightAnchor.constraint(equalToConstant: 28)])
        return b
    }

    static func divider() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return line
    }
}

// A sidebar row: the note's plain title (with pin / reminder badges), then a one-line snippet and when it was last touched.
final class NoteListCell: NSTableCellView {
    let snippet = NSTextField(labelWithString: "")
    let time = NSTextField(labelWithString: "")
    let pinBadge = NSImageView()
    let bellBadge = NSImageView()
    private var titleLeading: NSLayoutConstraint!       // 12 pt in, or 26 pt inside a folder

    override init(frame: NSRect) {
        super.init(frame: frame)
        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        snippet.font = .systemFont(ofSize: 11.5)
        snippet.textColor = .secondaryLabelColor
        time.font = .systemFont(ofSize: 11)
        time.textColor = .tertiaryLabelColor
        time.alignment = .right
        time.setContentHuggingPriority(.required, for: .horizontal)
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        for field in [title, snippet] {
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        }
        pinBadge.image = sym("pin.fill"); pinBadge.contentTintColor = .controlAccentColor
        bellBadge.image = sym("bell.fill"); bellBadge.contentTintColor = .systemOrange
        for badge in [pinBadge, bellBadge] {
            badge.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            badge.setContentHuggingPriority(.required, for: .horizontal)
            badge.isHidden = true
        }
        let badges = NSStackView(views: [pinBadge, bellBadge])
        badges.orientation = .horizontal; badges.spacing = 3
        for view in [title, snippet, time, badges] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textField = title
        titleLeading = title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12)
        NSLayoutConstraint.activate([
            titleLeading,
            title.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            badges.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 6),
            badges.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            badges.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            snippet.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            snippet.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            time.leadingAnchor.constraint(greaterThanOrEqualTo: snippet.trailingAnchor, constant: 8),
            time.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            time.firstBaselineAnchor.constraint(equalTo: snippet.firstBaselineAnchor),
        ])
        // The title and the badges share the first line; a long title gives way to the badges, never the other way round.
        let titleToBadges = title.trailingAnchor.constraint(lessThanOrEqualTo: badges.leadingAnchor, constant: -6)
        titleToBadges.priority = .defaultHigh
        titleToBadges.isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, snippet text: String, time when: String, pinned: Bool, reminder: Bool, trashed: Bool, indented: Bool = false) {
        titleLeading.constant = indented ? 26 : 12
        textField?.stringValue = title
        textField?.font = .systemFont(ofSize: 13, weight: pinned ? .semibold : .medium)
        snippet.stringValue = text
        time.stringValue = when
        pinBadge.isHidden = !pinned || trashed
        bellBadge.isHidden = !reminder || trashed
        toolTip = title
        var spoken = [title]
        if pinned { spoken.append("pinned") }
        if reminder { spoken.append("has a reminder") }
        if !text.isEmpty { spoken.append(text) }
        spoken.append(when)
        setAccessibilityLabel(spoken.joined(separator: ", "))
    }
}

func sym(_ name: String) -> NSImage { NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage() }
func appIcon(_ bundleID: String, fallback: String, size: CGFloat = 22) -> NSImage {
    if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        let i = NSWorkspace.shared.icon(forFile: u.path); i.size = NSSize(width: size, height: size); return i
    }
    let s = sym(fallback); s.size = NSSize(width: size, height: size); return s
}
func colorFromHex(_ hex: String) -> NSColor {
    var s = hex; if s.hasPrefix("#") { s.removeFirst() }
    var v: UInt64 = 0; Scanner(string: s).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v>>16)&0xff)/255, green: CGFloat((v>>8)&0xff)/255, blue: CGFloat(v&0xff)/255, alpha: 1)
}
func hexFromColor(_ c: NSColor) -> String {
    let s = c.usingColorSpace(.sRGB) ?? c
    return String(format: "%02X%02X%02X", Int(s.redComponent*255), Int(s.greenComponent*255), Int(s.blueComponent*255))
}
func isLightColor(_ c: NSColor) -> Bool {
    let s = c.usingColorSpace(.sRGB) ?? c
    return (0.299*s.redComponent + 0.587*s.greenComponent + 0.114*s.blueComponent) > 0.6
}
func editorFont() -> NSFont {
    let size = CGFloat(Prefs.fontSize)
    if Prefs.fontFamily.isEmpty { return NSFont.monospacedSystemFont(ofSize: size, weight: .regular) }
    return NSFont(name: Prefs.fontFamily, size: size) ?? NSFont.systemFont(ofSize: size)
}
func noteTitle(_ content: String) -> String { MarkdownPlain.title(content) }
func safeFilename(_ s: String) -> String {
    let t = noteTitle(s)
    return t.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: " ")
}

// ============================================================================
// MARK: - Markdown → rich text  (RTF / HTML export; Jot edits Markdown only — see LegacyRTF.swift)
// ============================================================================
// Convert markdown text → NSAttributedString with formatting (bold, italic, headings, code).
// Strips the markdown markers so the result is clean rich text. Kept characters are copied as attributed
// RUNS (never through String(unichar), which yields the character CODE: the old version exported "87101…").
func markdownToRichText(_ md: String, baseFont: NSFont, color: NSColor) -> NSAttributedString {
    let ts = NSTextStorage(string: md)
    let styler = MarkdownStyler()
    styler.baseFont = { baseFont }
    styler.textColor = { color }
    styler.resetReveal()   // reveal nothing: every marker is concealed
    styler.styleAll(ts)

    let result = NSMutableAttributedString()
    let ns = ts.string as NSString
    var keepStart = -1                       // start of the current run of kept characters
    func flush(_ end: Int) {
        if keepStart >= 0, end > keepStart { result.append(ts.attributedSubstring(from: NSRange(location: keepStart, length: end - keepStart))) }
        keepStart = -1
    }
    var i = 0
    while i < ns.length {
        // Concealed characters are the **/*/__/_ emphasis markers.
        if ts.attribute(.jotConceal, at: i, effectiveRange: nil) != nil { flush(i); i += 1; continue }
        // A heading's leading #s (and the space after them) at the start of a line.
        if ns.character(at: i) == 0x23, i == 0 || ns.character(at: i - 1) == 0x0A {
            var skip = 0
            while i + skip < ns.length, ns.character(at: i + skip) == 0x23 { skip += 1 }
            if i + skip < ns.length, ns.character(at: i + skip) == 0x20 {
                while i + skip < ns.length, ns.character(at: i + skip) == 0x20 { skip += 1 }
                flush(i); i += skip; continue
            }
        }
        // Inline-code backticks.
        if ns.character(at: i) == 0x60 { flush(i); i += 1; continue }
        if keepStart < 0 { keepStart = i }
        i += 1
    }
    flush(ns.length)
    return result
}

// ============================================================================
// MARK: - JotTextView  (flagship editing: indent, list-continuation, move/dup lines)
// ============================================================================
final class JotTextView: NSTextView {
    private let indentUnit = "  "   // two spaces — markdown-friendly nesting

    override func insertTab(_ sender: Any?) {
        if moveToNextCell() { return }
        indentLines(outdent: false)
    }
    override func insertBacktab(_ sender: Any?) {
        if moveToPrevCell() { return }
        indentLines(outdent: true)
    }

    // Right-click menu: the standard text menu plus Refresh (re-read this note and the notes list from disk).
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let refresh = NSMenuItem(title: "Refresh", action: #selector(AppDelegate.refreshActiveNote), keyEquivalent: "")
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        menu.addItem(refresh)   // nil target → the responder chain reaches AppDelegate
        return menu
    }

    // Click on a checkbox marker → toggle [ ] ↔ [x]; ⌘-click on a link opens it.
    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let idx = characterIndex(for: pt)
        if idx != NSNotFound, event.modifierFlags.contains(.command), openLink(at: idx) { return }
        if idx != NSNotFound, toggleCheckbox(at: idx) { return }
        super.mouseDown(with: event)
    }

    // The web or mail address of the Markdown link at a character, if any: `[text](https://…)` — over its text, or over the
    // address itself when markers are showing. Only http, https and mailto: a note must not be able to launch anything else.
    func linkURL(at index: Int) -> URL? {
        let ns = string as NSString
        guard index >= 0, index < ns.length else { return nil }
        let lines = ns.lineRange(for: NSRange(location: index, length: 0))
        if let kind = textStorage?.attribute(.jotKind, at: lines.location, effectiveRange: nil) as? Int, kind == 60 || kind == 61 || kind == 70 { return nil }   // fenced code
        let local = ns.substring(with: lines)
        guard let line = MarkdownScanner.blocks(local).first else { return nil }
        let localIndex = index - lines.location
        for span in MarkdownScanner.spans(local, line: line) where span.kind == .link {
            guard let urlRange = span.url, localIndex >= span.full.location, localIndex < NSMaxRange(span.full) else { continue }
            let text = (local as NSString).substring(with: urlRange).trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: text), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return url
        }
        return nil
    }
    @discardableResult
    func openLink(at index: Int) -> Bool {
        guard let url = linkURL(at: index) else { return false }
        if Runtime.isPreview { PreviewLog.record("open-url", url.absoluteString) } else { NSWorkspace.shared.open(url) }
        return true
    }

    // An empty note says what to do. (Drawn, never typed: it isn't in the text, so it can't be copied, saved or searched.)
    private var wasEmpty = true
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, isEditable, !hasMarkedText() else { return }
        let origin = textContainerOrigin
        let attributes: [NSAttributedString.Key: Any] = [.font: editorFont(), .foregroundColor: insertionPointColor.withAlphaComponent(0.3)]
        ("Start typing…" as NSString).draw(at: NSPoint(x: origin.x + (textContainer?.lineFragmentPadding ?? 5), y: origin.y), withAttributes: attributes)
    }
    override func didChangeText() {
        super.didChangeText()
        if string.isEmpty != wasEmpty { wasEmpty = string.isEmpty; needsDisplay = true }
    }
    override func setSelectedRange(_ charRange: NSRange) {
        super.setSelectedRange(charRange)
        if string.isEmpty != wasEmpty { wasEmpty = string.isEmpty; needsDisplay = true }
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌘⇧ + arrows are the native "select to line / document edge" and are left alone (they used to be
        // hijacked for sidebar navigation). Note navigation lives in the View menu: ⌥⌘↑ / ⌥⌘↓, ⌃⌘S.
        if mods == .option, event.keyCode == 126 { moveLines(up: true); return }    // ⌥↑ move line up
        if mods == .option, event.keyCode == 125 { moveLines(up: false); return }   // ⌥↓ move line down
        if mods == .command, event.charactersIgnoringModifiers == "d" { duplicateLines(); return }  // ⌘D
        super.keyDown(with: event)
    }

    // A text view keeps its own ⌘⌫ ("delete to line start"). Key equivalents are offered to the window's
    // views first and the main menu second, so without this the menu's "Delete Note" claimed ⌘⌫ and
    // trashed the whole note while you typed. The Delete key is keyCode 51; the character it sends is 0x7F
    // or 0x08 depending on who asks, so match the key, not the character. With the notes list focused the
    // menu still wins (and ⇧⌘⌫ deletes the note from anywhere).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, event.keyCode == 51, window?.firstResponder === self {
            deleteToBeginningOfLine(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // Esc: close the ⌘F find bar if it's open; otherwise hide the pad. (Undocked note windows ignore it,
    // like any other window.)
    override func cancelOperation(_ sender: Any?) {
        if let scroll = enclosingScrollView, scroll.isFindBarVisible {
            scroll.isFindBarVisible = false
            window?.makeFirstResponder(self)
            return
        }
        if let ad = NSApp.delegate as? AppDelegate, window === ad.dropdown { ad.escape(); return }
        super.cancelOperation(sender)
    }

    // MARK: Markdown editing behaviours (the rules live in MarkdownEdit; these are the key hooks) ---------------------------------
    // The engine works on the lines the selection touches, never the whole note, so Return, Backspace and Tab cost the same in a
    // 200 KB note as in a short one. Lines inside a fenced block are code (the styler stamps their kind), not Markdown.
    private func editOnTouchedLines(_ make: (String, NSRange) -> TextEdit?) -> TextEdit? {
        let ns = string as NSString
        let sel = selectedRange()
        let lines = ns.lineRange(for: sel)
        if ns.length > 0, let kind = textStorage?.attribute(.jotKind, at: min(lines.location, ns.length - 1), effectiveRange: nil) as? Int,
           kind == 60 || kind == 61 || kind == 70 { return nil }
        guard let local = make(ns.substring(with: lines), NSRange(location: sel.location - lines.location, length: sel.length)) else { return nil }
        return TextEdit(range: NSRange(location: local.range.location + lines.location, length: local.range.length), replacement: local.replacement,
                        selection: NSRange(location: local.selection.location + lines.location, length: local.selection.length))
    }

    // Return: continue a list item or quote (a new bullet, the next number, an unchecked task), split an item at the caret,
    // end the list on an empty item, or open an empty line above when the caret is left of the marker. Anything else: a newline.
    override func insertNewline(_ sender: Any?) {
        if !hasMarkedText(), selectedRange().length == 0,
           apply(editOnTouchedLines { MarkdownEdit.continueList(in: $0, caret: $1.location) }) { return }
        super.insertNewline(sender)
    }

    // Backspace right after a list/heading/quote marker removes the marker (the line becomes plain text) instead of one of its characters.
    override func deleteBackward(_ sender: Any?) {
        if !hasMarkedText(), selectedRange().length == 0,
           apply(editOnTouchedLines { MarkdownEdit.backspaceMarker(in: $0, caret: $1.location) }) { return }
        super.deleteBackward(sender)
    }

    // Tab / ⇧Tab indent or outdent the lines you're on by two spaces (a list item nests; an empty line just gets the spaces).
    private func indentLines(outdent: Bool) {
        if apply(editOnTouchedLines { MarkdownEdit.indent(outdent: outdent, in: $0, selection: $1) }) { return }
        if !outdent, selectedRange().length == 0 { insertText(indentUnit, replacementRange: selectedRange()) }
    }

    // A URL on the clipboard pasted over selected text makes a link of it — `[selected](url)` — instead of replacing it.
    static func clipboardURL() -> String? {
        guard let copied = Runtime.pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !copied.isEmpty, !copied.contains(where: \.isNewline), let url = URL(string: copied),
              ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return copied
    }
    override func paste(_ sender: Any?) {
        if !hasMarkedText(), selectedRange().length > 0, let url = JotTextView.clipboardURL(),
           apply(editOnTouchedLines { text, selection in MarkdownEdit.state(in: text, selection: selection).link ? nil : MarkdownEdit.toggleLink(in: text, selection: selection, url: url) }) { return }
        if Runtime.isPreview { _ = readSelection(from: Runtime.pasteboard); return }   // a preview never reads your real clipboard
        super.paste(sender)
    }

    private func duplicateLines() {
        let ns = string as NSString
        let lr = ns.lineRange(for: selectedRange())
        let block = ns.substring(with: lr)
        let at = NSMaxRange(lr)
        let toInsert = block.hasSuffix("\n") ? block : "\n" + block
        let r = NSRange(location: at, length: 0)
        if shouldChangeText(in: r, replacementString: toInsert) { replaceCharacters(in: r, with: toInsert); didChangeText() }
    }

    private func moveLines(up: Bool) {
        let ns = string as NSString
        let lr = ns.lineRange(for: selectedRange())
        if up {
            if lr.location == 0 { return }
            let prev = ns.lineRange(for: NSRange(location: lr.location - 1, length: 0))
            var block = ns.substring(with: lr); var prevText = ns.substring(with: prev)
            if !block.hasSuffix("\n") { block += "\n"; if prevText.hasSuffix("\n") { prevText.removeLast() } }
            let region = NSRange(location: prev.location, length: prev.length + lr.length)
            let swapped = block + prevText
            if shouldChangeText(in: region, replacementString: swapped) {
                replaceCharacters(in: region, with: swapped); didChangeText()
                setSelectedRange(NSRange(location: prev.location, length: (block as NSString).length))
            }
        } else {
            let end = NSMaxRange(lr)
            if end >= ns.length { return }
            let next = ns.lineRange(for: NSRange(location: end, length: 0))
            var block = ns.substring(with: lr); var nextText = ns.substring(with: next)
            if !nextText.hasSuffix("\n") { nextText += "\n"; if block.hasSuffix("\n") { block.removeLast() } }
            let region = NSRange(location: lr.location, length: lr.length + next.length)
            let swapped = nextText + block
            if shouldChangeText(in: region, replacementString: swapped) {
                replaceCharacters(in: region, with: swapped); didChangeText()
                setSelectedRange(NSRange(location: lr.location + (nextText as NSString).length, length: (block as NSString).length))
            }
        }
    }

    // MARK: Checkbox toggle (click [ ]/[x] to toggle)
    private func toggleCheckbox(at idx: Int) -> Bool {
        let ns = string as NSString
        let lr = ns.lineRange(for: NSRange(location: idx, length: 0))
        let line = ns.substring(with: lr)
        let ws = String(line.prefix { $0 == " " || $0 == "\t" })
        let rest = line.dropFirst(ws.count)
        for cb in ["- [ ] ", "- [x] ", "- [X] "] where rest.hasPrefix(cb) {
            let bracketStart = lr.location + ws.count + 2   // position of '['
            if idx >= bracketStart && idx <= bracketStart + 2 {
                let innerIdx = bracketStart + 1              // char between brackets
                let ch = ns.character(at: innerIdx)
                let newChar = (ch == 0x20) ? "x" : " "       // space→x, x/X→space
                let r = NSRange(location: innerIdx, length: 1)
                if shouldChangeText(in: r, replacementString: newChar) {
                    replaceCharacters(in: r, with: newChar); didChangeText()
                }
                return true
            }
            break
        }
        return false
    }

    // MARK: Table cell navigation (Tab / Shift-Tab within |...| rows)
    private func isTableDataRow(_ idx: Int) -> (NSString, NSRange)? {
        let ns = string as NSString
        let lr = ns.lineRange(for: NSRange(location: idx, length: 0))
        let line = ns.substring(with: lr)
        guard line.hasPrefix("|"), line.contains("|") else { return nil }
        // Skip separator lines (|---|---|)
        if line.range(of: "^\\|[-: |]+\\|\\s*$", options: .regularExpression) != nil { return nil }
        return (ns, lr)
    }
    private func moveToNextCell() -> Bool {
        let sel = selectedRange()
        guard let (ns, lr) = isTableDataRow(sel.location) else { return false }
        for i in (sel.location + 1)..<NSMaxRange(lr) {
            let ch = ns.character(at: i)
            if ch == 0x7C { setSelectedRange(NSRange(location: i + 1, length: 0)); return true }
            if ch == 0x0A { break }
        }
        // Wrap to first cell of next row
        if NSMaxRange(lr) < ns.length {
            let nextLR = ns.lineRange(for: NSRange(location: NSMaxRange(lr), length: 0))
            let nextLine = ns.substring(with: nextLR)
            if nextLine.hasPrefix("|"), nextLine.range(of: "^\\|[-: |]+\\|\\s*$", options: .regularExpression) == nil {
                if let pipe = (nextLR.location + 1..<NSMaxRange(nextLR)).first(where: { ns.character(at: $0) == 0x7C }) {
                    setSelectedRange(NSRange(location: pipe + 1, length: 0)); return true
                }
            }
        }
        return false
    }
    private func moveToPrevCell() -> Bool {
        let sel = selectedRange()
        guard let (ns, lr) = isTableDataRow(sel.location) else { return false }
        for i in stride(from: sel.location - 1, through: lr.location + 1, by: -1) {
            if ns.character(at: i) == 0x7C { setSelectedRange(NSRange(location: i + 1, length: 0)); return true }
        }
        // Wrap to last cell of previous row
        if lr.location > 0 {
            let prevLR = ns.lineRange(for: NSRange(location: lr.location - 1, length: 0))
            let prevLine = ns.substring(with: prevLR)
            if prevLine.hasPrefix("|"), prevLine.range(of: "^\\|[-: |]+\\|\\s*$", options: .regularExpression) == nil {
                for i in stride(from: NSMaxRange(prevLR) - 1, through: prevLR.location, by: -1) {
                    let ch = ns.character(at: i)
                    if ch == 0x7C { setSelectedRange(NSRange(location: i + 1, length: 0)); return true }
                    if ch == 0x0A { continue }
                }
            }
        }
        return false
    }
}

// ============================================================================
// MARK: - NoteWindowController (undocked, editor-only secondary window — A6/A7)
// ============================================================================
// Opened by double-clicking a note in the sidebar. Hosts the same editor stack as the docked
// window (JotTextView + MarkdownStyler + the writing-tools bar) but no notes list, and a close
// (✕) button instead of the tray-minimize arrow — it's a normal, independent NSWindow.
final class NoteWindowController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    let window: NSWindow
    let textView: JotTextView
    let mdStyler = MarkdownStyler()
    let store: NotesStore
    let url: URL
    weak var appDelegate: AppDelegate?
    var noteMeta = NoteMeta()
    var toolsBar: NSView!
    var toolsToggle: NSButton!
    var shareButton: NSButton!
    var pinButton: NSButton!
    var editorScroll: NSScrollView!
    var toolsShown = Prefs.toolsShown
    var isPinned = false
    let undoMgr = UndoManager()
    var saveWork: DispatchWorkItem?
    let toolsH = JotUI.toolsHeight

    init(url: URL, store: NotesStore, appDelegate: AppDelegate) {
        self.url = url
        self.store = store
        self.appDelegate = appDelegate
        let size = NSSize(width: 440, height: 440)
        window = JotWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        textView = EditorKit.makeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        super.init()
        setupWindow(size: size)
    }

    private func setupWindow(size: NSSize) {
        window.title = appDelegate?.titleForNote(url) ?? "Note"
        window.titleVisibility = .visible                 // a real title bar: traffic lights and the note's title
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 360, height: 240)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = makeGlassContentView()
        let content = window.contentView!

        // Aa · Share · Pin sit in the title bar, to the right of the title.
        toolsToggle = JotUI.button("textformat", label: "Show or hide formatting (⌥⌘T)", target: self, action: #selector(toggleTools))
        shareButton = JotUI.button("square.and.arrow.up", label: "Share or send this note", target: self, action: #selector(showShareMenu(_:)))
        pinButton = JotUI.button("pin", label: "Keep this window on top", target: self, action: #selector(togglePin))
        let accessoryStack = NSStackView(views: [toolsToggle, shareButton, pinButton])
        accessoryStack.orientation = .horizontal; accessoryStack.spacing = 2
        accessoryStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 10)
        accessoryStack.setFrameSize(NSSize(width: 3 * 28 + 2 * 2 + 10, height: 28))      // a title-bar accessory is sized by its frame
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .trailing
        accessory.view = accessoryStack
        window.addTitlebarAccessoryViewController(accessory)

        guard let ad = appDelegate else { return }
        toolsBar = ad.buildToolsBar(width: size.width)

        editorScroll = NSScrollView()
        editorScroll.autoresizingMask = [.width, .height]
        editorScroll.hasVerticalScroller = true
        editorScroll.borderType = .noBorder
        editorScroll.scrollerStyle = .overlay
        editorScroll.autohidesScrollers = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.isRichText = false
        textView.isContinuousSpellCheckingEnabled = Prefs.spellcheck
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false   // no predictive suggestions in a notepad
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = JotUI.editorInset
        textView.font = editorFont()
        textView.delegate = self
        editorScroll.documentView = textView
        mdStyler.baseFont = { editorFont() }
        mdStyler.mode = Prefs.rawMode ? .raw : .formatted
        mdStyler.textColor = { [weak self] in
            guard let self = self else { return .white }
            if !self.noteMeta.textColor.isEmpty { return colorFromHex(self.noteMeta.textColor) }
            return self.appDelegate?.defaultEditorTextColor() ?? .white
        }
        textView.textStorage?.delegate = mdStyler
        textView.layoutManager?.delegate = concealLayoutDelegate

        content.addSubview(editorScroll)
        content.addSubview(toolsBar)

        applyToolsVisibility()
        applyEditorBG()
        noteMeta = store.readMeta(url)
        let body = store.read(url)
        textView.adaptLayout(toTextLength: body.utf16.count)
        mdStyler.isSuspended = true          // style once below, not line by line as the text lands
        textView.string = body
        mdStyler.isSuspended = false
        if let ts = textView.textStorage { mdStyler.styleAll(ts) }
        window.title = appDelegate?.titleForNote(url) ?? "Note"
        window.makeFirstResponder(textView)
        revealActiveParagraph(textView, mdStyler)
        ad.refreshFormattingBar(for: textView)
    }

    func applyToolsVisibility() {
        toolsBar?.isHidden = !toolsShown
        toolsToggle?.contentTintColor = toolsShown ? .controlAccentColor : .secondaryLabelColor
        guard let cv = window.contentView else { return }
        let W = cv.bounds.width, H = cv.bounds.height
        let bottom: CGFloat = toolsShown ? toolsH : 0
        let titleBar = max(0, H - window.contentLayoutRect.height)           // the native title bar sits over the top of the content
        toolsBar?.frame = NSRect(x: 0, y: 0, width: W, height: toolsH)
        editorScroll.frame = NSRect(x: 0, y: bottom, width: W, height: max(0, (H - titleBar) - bottom))
    }
    @objc func toggleTools() { toolsShown.toggle(); Prefs.toolsShown = toolsShown; applyToolsVisibility() }

    // Share / send menu — the same menu as the pad's. The export actions live on AppDelegate and operate on `activeEditor`
    // (the key window's text view), so this window is made key with its editor focused first; then every item acts on THIS note.
    @objc func showShareMenu(_ sender: NSButton) {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        guard let ad = appDelegate else { return }
        let menu = ad.shareMenu(anchor: sender)
        if menu.items.isEmpty { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
    }

    // Pin = keep this note window above other windows (its own floating level).
    @objc func togglePin() {
        isPinned.toggle()
        window.level = isPinned ? .floating : .normal
        pinButton.image = sym(isPinned ? "pin.fill" : "pin")
        pinButton.contentTintColor = isPinned ? .controlAccentColor : .secondaryLabelColor
        pinButton.toolTip = isPinned ? "Keep this window on top — on" : "Keep this window on top"
    }

    func applyEditorBG() {
        guard let ad = appDelegate else { return }
        let c = colorFromHex(Prefs.editorBGHex)
        textView.drawsBackground = true; textView.backgroundColor = c
        editorScroll.drawsBackground = true; editorScroll.backgroundColor = c
        let txt: NSColor
        if !noteMeta.textColor.isEmpty { txt = colorFromHex(noteMeta.textColor) }
        else { txt = ad.defaultEditorTextColor() }
        textView.insertionPointColor = txt
        textView.typingAttributes = [.font: editorFont(), .foregroundColor: txt]
        if let ts = textView.textStorage { mdStyler.styleAll(ts) }
    }

    // Pull the latest file content in when the main window (or another editor) changed this note,
    // unless this window is the one being typed in.
    func reloadFromDisk(force: Bool = false) {
        guard force || !window.isKeyWindow else { return }
        noteMeta = store.readMeta(url)
        let disk = store.read(url)
        guard textView.string != disk else { return }
        let sel = textView.selectedRange()
        undoMgr.disableUndoRegistration()
        textView.adaptLayout(toTextLength: disk.utf16.count)
        mdStyler.isSuspended = true
        textView.string = disk
        mdStyler.isSuspended = false
        undoMgr.enableUndoRegistration()
        textView.setSelectedRange(NSRange(location: min(sel.location, (disk as NSString).length), length: 0))
        if let ts = textView.textStorage { mdStyler.styleAll(ts) }
        window.title = noteTitle(disk)
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undoMgr }
    func windowShouldClose(_ sender: NSWindow) -> Bool { saveCurrent() }
    func windowWillClose(_ notification: Notification) {
        saveWork?.cancel()
        saveCurrent()
        appDelegate?.noteWindows.removeAll { $0 === self }
    }
    func closeAfterDeletion() {
        saveWork?.cancel()
        window.close()   // saveCurrent cannot recreate the removed file.
    }
    @objc func closeWindow() { window.performClose(nil) }

    func textDidChange(_ notification: Notification) {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveCurrent() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView, tv === textView else { return }
        revealActiveParagraph(tv, mdStyler)
        appDelegate?.refreshFormattingBar(for: textView)
    }
    @discardableResult
    func saveCurrent() -> Bool {
        saveWork?.cancel()
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        let body = textView.string
        do {
            try store.saveExisting(body, to: url)
        } catch {
            appDelegate?.showStorageError("The note could not be saved", error: error)
            return false
        }
        window.title = appDelegate?.titleForNote(url) ?? "Note"
        appDelegate?.refreshRowIfVisible(for: url)
        return true
    }
}

// ============================================================================
// MARK: - HotkeyRecorderView
// ============================================================================
final class HotkeyRecorderView: NSButton {
    var onCapture: ((_ keyCode: UInt32, _ carbon: UInt32, _ display: String) -> Void)?
    private var recording = false
    override init(frame: NSRect) { super.init(frame: frame); commonInit() }
    required init?(coder: NSCoder) { fatalError("not used") }
    private func commonInit() { bezelStyle = .rounded; setButtonType(.momentaryPushIn); target = self; action = #selector(begin); title = Prefs.hotkeyDisplay }
    @objc func begin() { recording = true; title = "Press shortcut…"; window?.makeFirstResponder(self) }
    override var acceptsFirstResponder: Bool { true }
    override func resignFirstResponder() -> Bool { if recording { recording = false; title = Prefs.hotkeyDisplay }; return true }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; title = Prefs.hotkeyDisplay; window?.makeFirstResponder(nil); return }
        let f = event.modifierFlags
        guard f.contains(.command) || f.contains(.option) || f.contains(.control) else { NSSound.beep(); return }
        let display = shortcutDisplay(f, event.keyCode, event.charactersIgnoringModifiers)
        recording = false; title = display; window?.makeFirstResponder(nil)
        onCapture?(UInt32(event.keyCode), carbonModifiers(from: f), display)
    }
}

// ============================================================================
// MARK: - SidebarDivider  (drag to resize the sidebar)
// ============================================================================
final class SidebarDivider: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var currentWidth: () -> CGFloat = { 210 }
    var isDraggable = true { didSet { window?.invalidateCursorRects(for: self) } }
    private var dragStartX: CGFloat = 0
    private var dragStartWidth: CGFloat = 0

    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { if isDraggable { addCursorRect(bounds, cursor: .resizeLeftRight) } }
    override func mouseDown(with event: NSEvent) {
        dragStartX = NSEvent.mouseLocation.x
        dragStartWidth = currentWidth()
    }
    override func mouseDragged(with event: NSEvent) {
        guard isDraggable else { return }
        let dx = NSEvent.mouseLocation.x - dragStartX
        onDrag?(dragStartWidth + dx)          // raw: the owner decides what is too narrow (dragging past the left edge closes the sidebar)
    }
}

// ============================================================================
// MARK: - App Delegate
// ============================================================================
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, UNUserNotificationCenterDelegate, NSMenuDelegate {

    var statusItem: NSStatusItem!
    var dropdown: NSWindow!
    let store = NotesStore(dir: Runtime.notesDirectory, trashDir: Runtime.trashDirectory)
    var notes: [URL] = []           // the notes that have a row in the list (filter applied, collapsed folders left out), in row order
    var sidebarItems: [SidebarItem] = []   // the table's rows: folder headers and notes. `notes` is this without the headers (Folders.swift)
    var layout = NoteLibrary.Layout()      // the whole library laid out into folders, before any filter
    var current: URL?
    var currentMeta = NoteMeta()
    var saveWork: DispatchWorkItem?

    var tableView: NSTableView!
    var textView: JotTextView!
    var shareButton: NSButton!
    var moreButton: NSButton!
    var newButton: NSButton!
    weak var shareAnchor: NSButton?
    var padGeneration = 0        // bumped by every show/hide request so a stale fade never orders out a pad that was shown again (PadWindow.swift)
    var padHiding = false
    var sidebarWasDocked = true
    let drawerBackdrop = DrawerBackdrop(frame: .zero)
    let drawerScrim = DrawerScrim(frame: .zero)
    var statusLabel: NSTextField!
    var pinButton: NSButton?
    var isPinned = false
    var suppressMoveSave = false
    var hotKeyRef: EventHotKeyRef?
    var registeredHotkey: (keyCode: UInt32, modifiers: UInt32)?
    var settingsController: SettingsController?

    let headerH = JotUI.headerHeight
    let toolsH = JotUI.toolsHeight
    var sidebarWidth: CGFloat = Prefs.sidebarWidth
    var listScroll: NSScrollView!
    let searchField = NSSearchField()
    let filterEmptyLabel = NSTextField(labelWithString: "No matching notes")
    var allNotes: [URL] = []                // every note in display order, folded-shut folders included; `notes` is what has a row (NoteFilter.swift)
    var filterText = ""
    var foldedCache: [URL: (date: Date, size: Int, text: String)] = [:]
    var sep: SidebarDivider!
    var editorScroll: NSScrollView!
    var sidebarToggle: NSButton!
    var sidebarShown = Prefs.sidebarShown
    var mdStyler: MarkdownStyler!
    var toolsBar: NSView!
    var toolsToggle: NSButton!
    var toolsShown = Prefs.toolsShown
    let undoMgr = UndoManager()   // fallback manager (used before any note is selected)
    var noteWindows: [NoteWindowController] = []   // undocked secondary editor windows (A6/A7)
    // Per-note undo: each note keeps its OWN undo stack so ⌘Z survives switching between notes.
    var undoManagers: [URL: UndoManager] = [:]
    var viewStates: [URL: (selection: NSRange, scrollY: CGFloat)] = [:]   // where you were in each note this session (caret and scroll)
    var pendingPick: DispatchWorkItem?                                    // a list selection made by a held arrow key, loaded once you stop
    var currentUndoManager: UndoManager?
    // Recently Deleted view (sidebar toggles between live notes and the 30-day trash).
    var viewingTrash = false
    var noteBeforeTrash: URL?
    var trashed: [URL] = []
    var trashToggle: NSButton!
    // In-memory only (never persisted): nil until the first open of this launch, then bumped on every
    // open/close. Drives "fresh note on launch" and "fresh note after 30 min idle with all notes closed".
    var lastActivity: Date? = nil
    var askedAXThisLaunch = false   // show the Accessibility prompt at most once per launch, never on every send
    var reminderButton: NSButton?
    // Cache behind noteInfo(_:) — invalidated by the file's modification date, so any write (here or
    // from an undocked window) refreshes it on the next read.
    var infoCache: [URL: (date: Date, size: Int, meta: NoteMeta, title: String, snippet: String)] = [:]
    var reminderPicker: NSDatePicker?
    var reminderPopover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // A preview must never be able to reach the real notes, however the store was built.
        precondition(!Runtime.isPreview || store.dir.path.hasPrefix(Runtime.previewRoot.path), "preview must not touch real notes")
        store.onWriteError = { [weak self] error in self?.showStorageError("The note could not be saved", error: error) }
        store.purgeTrash(olderThanDays: 30)   // clear Recently Deleted older than 30 days
        let legacyRTFReport = LegacyRTF.migrate(store)   // before any editor loads; backs up byte-for-byte first
        resolveHotkeyDefaults()                         // decided once, written down: new installs ⌥⌘J, existing ones keep ⌃J
        let welcomeNote = seedWelcomeNoteIfNeeded()     // a new install opens on a real "Welcome to Jot" note
        if !Runtime.isPreview { setupStatusItem() }   // a preview has no menu-bar icon and no hotkey
        setupDropdown()
        setupMainMenu()
        if !Runtime.isPreview {
            installHotkeyHandler()
            if !applyHotkey(keyCode: Prefs.hotkeyKeyCode, carbonModifiers: Prefs.hotkeyCarbon) {
                DispatchQueue.main.async { self.hotkeyUnavailable(Prefs.hotkeyDisplay) }
            }
        }
        notificationCenter()?.delegate = self
        reconcileReminders()
        NotificationCenter.default.addObserver(self, selector: #selector(appResignedActive),
                                               name: NSApplication.didResignActiveNotification, object: nil)
        announceLegacyRTF(legacyRTFReport)
        if let welcome = welcomeNote, !Runtime.isPreview {              // first run: open the pad on the welcome note
            lastActivity = Date()
            select(welcome)
            DispatchQueue.main.async { self.presentDropdown() }
        }
        if Runtime.isPreview { startPreview() }
    }
    // One plain notice, only when something happened. (Part 4.2's toast replaces the alert.)
    func announceLegacyRTF(_ report: LegacyRTF.Report) {
        guard !report.isEmpty else { return }
        if Runtime.isPreview { PreviewLog.record("rtf-migration", "\(report.converted.count) converted, \(report.failed.count) failed"); return }
        let alert = NSAlert()
        var lines: [String] = []
        if !report.converted.isEmpty {
            alert.messageText = report.converted.count == 1 ? "A Rich Text note was converted to Markdown" : "\(report.converted.count) Rich Text notes were converted to Markdown"
            lines.append("Jot now keeps notes as Markdown only (Rich Text is still available as an export format). The originals are kept in \(report.backupDirectory?.path ?? "Jot's Backups folder").")
        } else {
            alert.messageText = "A Rich Text note could not be converted"
        }
        if !report.failed.isEmpty {
            lines.append("\(report.failed.count) note\(report.failed.count == 1 ? " was" : "s were") left exactly as they were: " + report.failed.map { "\($0.url.lastPathComponent) (\($0.reason))" }.joined(separator: "; ") + ".")
        }
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.addButton(withTitle: "OK")
        if let folder = report.backupDirectory { alert.addButton(withTitle: "Show Backups"); if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([folder]) } }
        else { alert.runModal() }
    }
    func applicationWillTerminate(_ notification: Notification) {
        Runtime.resetPreviewState()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quitting does not guarantee a resign-active or window-close callback. Flush all pending
        // editor buffers while the run loop and UI are still available, and keep Jot open on failure.
        saveWork?.cancel()
        var saved = saveCurrent()
        for editor in noteWindows { if !editor.saveCurrent() { saved = false } }
        return saved ? .terminateNow : .terminateCancel
    }
    func showStorageError(_ message: String, error: Error) {
        flash(message)
        if Runtime.isPreview { PreviewLog.record("storage-error", "\(message): \(error.localizedDescription)"); return }   // never block a walkthrough on a modal
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription + "\nThe note has been kept."
        alert.alertStyle = .warning
        alert.runModal()
    }
    @objc func appResignedActive() {
        guard saveCurrent() else { return }
        // Tray mode hides on click-away; a pinned or detached window stays put.
        if dropdown.isVisible && !isPinned && !Prefs.detached { hidePad() }
    }

    // MARK: status item
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Jot")
            b.action = #selector(statusClicked); b.target = self
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }
    @objc func statusClicked() {
        if let e = NSApp.currentEvent, e.type == .rightMouseUp { showMenu() } else { toggleDropdown() }
    }

    // MARK: dropdown window
    func setupDropdown() {
        let size = NSSize(width: 440, height: 440)   // small square window
        dropdown = JotWindow(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        dropdown.titleVisibility = .hidden
        dropdown.titlebarAppearsTransparent = true
        dropdown.standardWindowButton(.closeButton)?.isHidden = true
        dropdown.standardWindowButton(.miniaturizeButton)?.isHidden = true
        dropdown.standardWindowButton(.zoomButton)?.isHidden = true
        dropdown.isMovableByWindowBackground = true
        dropdown.animationBehavior = .none       // the pad animates itself (PadWindow.swift)
        dropdown.level = .floating           // NOT .popUpMenu — that sat on top of Spotlight even when unpinned
        dropdown.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]   // open on the current Space — including over a full-screen app
        dropdown.minSize = NSSize(width: 360, height: 240)   // keep controls distinct and the editor usable
        dropdown.hidesOnDeactivate = false   // we hide on app-resign (first-click fix)
        dropdown.isReleasedWhenClosed = false
        dropdown.delegate = self
        dropdown.contentView = makeGlassContentView()
        let content = dropdown.contentView!

        // Header: sidebar · the note's title (with pin / reminder badges) · Aa · Share · New · ⋯. Everything occasional — pin,
        // reminder, new window, delete, Settings — lives in ⋯; everything that sends the note somewhere lives in Share.
        let header = NSView(frame: NSRect(x: 0, y: size.height - headerH, width: size.width, height: headerH))
        header.autoresizingMask = [.width, .minYMargin]
        let headerStack = NSStackView()
        headerStack.orientation = .horizontal; headerStack.spacing = 4
        headerStack.distribution = .fill           // the title takes the slack, so the actions sit against the right edge
        headerStack.alignment = .centerY; headerStack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerStack)
        NSLayoutConstraint.activate([
            headerStack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            headerStack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            headerStack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        sidebarToggle = JotUI.button("sidebar.left", label: "Show or hide notes", target: self, action: #selector(toggleSidebar))
        statusLabel = NSTextField(labelWithString: "")          // the open note's title; messages are toasts (ToastCenter)
        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)          // the title takes all the slack…
        statusLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)   // …and is what gives way first
        reminderButton = JotUI.badge("bell.fill", label: "Reminder set — click to change", tint: .systemOrange, target: self, action: #selector(showReminderPopover(_:)))
        pinButton = JotUI.badge("pin.fill", label: "Always on top — click to turn off", tint: .controlAccentColor, target: self, action: #selector(togglePin(_:)))
        reminderButton?.isHidden = true; pinButton?.isHidden = true
        toolsToggle = JotUI.button("textformat", label: "Show or hide formatting (⌥⌘T)", target: self, action: #selector(toggleTools))
        shareButton = JotUI.button("square.and.arrow.up", label: "Share or send this note", target: self, action: #selector(showPadShareMenu(_:)))
        moreButton = JotUI.button("ellipsis", label: "More note actions", target: self, action: #selector(showNoteActions(_:)))
        let newBtn = NSButton(title: "New", image: sym("square.and.pencil"), target: self, action: #selector(newNote))
        newButton = newBtn
        newBtn.bezelStyle = .rounded; newBtn.controlSize = .regular
        newBtn.font = .systemFont(ofSize: 12, weight: .medium)
        newBtn.imagePosition = .imageLeading
        newBtn.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        newBtn.toolTip = "New note (⌘N)"; newBtn.setAccessibilityLabel("New note")
        for v in [sidebarToggle!, statusLabel!, reminderButton!, pinButton!, toolsToggle!, shareButton!, newBtn, moreButton!] {
            headerStack.addArrangedSubview(v)
        }
        // Kept for the existing Recently Deleted state handling.
        trashToggle = NSButton(title: "", image: sym("trash.circle"), target: self, action: #selector(toggleTrashView))
        trashToggle.isBordered = false; trashToggle.contentTintColor = .secondaryLabelColor

        // Formatting bar (along the bottom)
        let tools = buildToolsBar(width: size.width)
        toolsBar = tools

        // Notes list (left) — flat table view; HIDDEN by default.
        listScroll = NSScrollView()
        listScroll.autoresizingMask = [.height, .maxXMargin]
        listScroll.hasVerticalScroller = true; listScroll.drawsBackground = false
        listScroll.scrollerStyle = .overlay; listScroll.autohidesScrollers = true
        searchField.placeholderString = "Search notes"
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 12)
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.target = self; searchField.action = #selector(filterChanged(_:))
        searchField.setAccessibilityLabel("Search notes")
        filterEmptyLabel.font = .systemFont(ofSize: 12); filterEmptyLabel.textColor = .tertiaryLabelColor
        filterEmptyLabel.alignment = .center; filterEmptyLabel.isHidden = true
        let notesTable = NoteTableView()
        tableView = notesTable
        notesTable.onUserPick = { [weak self] row in self?.sidebarRowPicked(row) }
        notesTable.setAccessibilityLabel("Notes")
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note")); col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil; tableView.backgroundColor = .clear; tableView.rowHeight = 52
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.gridStyleMask = []
        tableView.style = .sourceList
        tableView.dataSource = self; tableView.delegate = self
        tableView.menu = listContextMenu()
        tableView.menu?.delegate = self
        tableView.allowsMultipleSelection = true
        tableView.target = self; tableView.doubleAction = #selector(openNoteWindow)
        tableView.registerForDraggedTypes([NSPasteboard.PasteboardType("public.file-url")])
        listScroll.documentView = tableView

        sep = SidebarDivider()
        sep.wantsLayer = true; sep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        sep.autoresizingMask = [.height, .maxXMargin]
        sep.currentWidth = { [weak self] in self?.listScroll.frame.width ?? 210 }
        sep.onDrag = { [weak self] w in
            guard let self = self, self.sidebarDocks, self.sidebarShown else { return }
            if w < SidebarGeometry.closeDragThreshold { self.hideSidebar(); return }       // dragged all the way to the left: closed (the saved width is untouched)
            self.sidebarWidth = max(120, w)
            Prefs.sidebarWidth = self.sidebarWidth
            self.applySidebarVisibility()
        }
        drawerScrim.onClick = { [weak self] in self?.hideSidebar() }
        drawerScrim.isHidden = true; drawerBackdrop.isHidden = true

        // Editor — bordered, opaque, editable background colour
        editorScroll = NSScrollView()
        editorScroll.autoresizingMask = [.width, .height]
        editorScroll.hasVerticalScroller = true
        editorScroll.borderType = .noBorder
        editorScroll.scrollerStyle = .overlay
        editorScroll.autohidesScrollers = true
        textView = EditorKit.makeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        // Tuned for very large text:
        textView.isRichText = false
        textView.isContinuousSpellCheckingEnabled = Prefs.spellcheck
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false   // no predictive suggestions in a notepad
        textView.allowsUndo = true
        textView.usesFindBar = true                 // ⌘F find/replace bar
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = JotUI.editorInset
        textView.font = editorFont()
        textView.delegate = self
        editorScroll.documentView = textView
        // Live markdown styling (render **bold**/*italic*/# heading/`code` while editing).
        mdStyler = MarkdownStyler()
        mdStyler.baseFont = { editorFont() }
        mdStyler.textColor = { [weak self] in self?.editorTextColor() ?? .white }
        mdStyler.mode = Prefs.rawMode ? .raw : .formatted
        textView.textStorage?.delegate = mdStyler
        textView.layoutManager?.delegate = concealLayoutDelegate   // hides the **/* markers (renders real bold/italic)
        applyEditorBG()

        content.addSubview(editorScroll)
        content.addSubview(tools)
        content.addSubview(drawerScrim)          // the drawer's pieces sit above the text…
        content.addSubview(drawerBackdrop)
        content.addSubview(listScroll)
        content.addSubview(searchField)
        content.addSubview(filterEmptyLabel)
        content.addSubview(sep)
        content.addSubview(header)               // …and under the header

        applySidebarVisibility()
        applyToolsVisibility()
        pruneBlankNotes(keeping: nil)   // sweep "New Note" ghosts left by earlier sessions
        reloadNotes(selectFirst: true)
    }

    // MARK: layout helpers (sidebar hidden by default)
    // View ▸ Show Markdown Syntax: raw Markdown with every marker visible, or the formatted live preview.
    @objc func toggleDisplayMode() { setDisplayMode(raw: !Prefs.rawMode) }
    func setDisplayMode(raw: Bool) {
        guard raw != Prefs.rawMode else { return }
        Prefs.rawMode = raw
        let mode: MarkdownStyler.Mode = Prefs.rawMode ? .raw : .formatted
        if let ts = textView.textStorage { mdStyler.setMode(mode, in: ts) }
        for nc in noteWindows { if let ts = nc.textView.textStorage { nc.mdStyler.setMode(mode, in: ts) } }
        revealActiveParagraph(textView, mdStyler)
        refreshAllFormattingBars()
        flash(Prefs.rawMode ? "Markdown syntax shown" : "Formatted view")
    }
    func selectPrevNote() {
        guard !viewingTrash, !notes.isEmpty else { return }
        let at = noteURL(atRow: tableView.selectedRow).flatMap { notes.firstIndex(of: $0) } ?? -1     // folder headers have no place in the walk
        let prev = at > 0 ? at - 1 : notes.count - 1
        openOrSelect(notes[prev])
    }
    func selectNextNote() {
        guard !viewingTrash, !notes.isEmpty else { return }
        let at = noteURL(atRow: tableView.selectedRow).flatMap { notes.firstIndex(of: $0) } ?? -1
        let next = at < notes.count - 1 ? at + 1 : 0
        openOrSelect(notes[next])
    }
    func applyToolsVisibility() {
        toolsBar?.isHidden = !toolsShown
        toolsToggle?.contentTintColor = toolsShown ? .controlAccentColor : .secondaryLabelColor
        applySidebarVisibility()   // recompute editor/list frames with/without the tools-bar height
    }
    @objc func toggleTools() {
        if let key = NSApp.keyWindow, let nc = noteWindows.first(where: { $0.window === key }) { nc.toggleTools(); return }
        toolsShown.toggle(); Prefs.toolsShown = toolsShown; applyToolsVisibility()
    }

    func editorTextColor() -> NSColor {
        if !currentMeta.textColor.isEmpty { return colorFromHex(currentMeta.textColor) }
        return defaultEditorTextColor()
    }
    func defaultEditorTextColor() -> NSColor {
        let c = colorFromHex(Prefs.editorBGHex)
        return isLightColor(c) ? NSColor.black.withAlphaComponent(0.85) : NSColor.white.withAlphaComponent(0.92)
    }
    // `restyle: false` when the text was just styled with these colours anyway (loading a note), so a 200 KB note isn't styled twice.
    // A background change from Settings reaches the pad and every open note window.
    func applyEditorBGEverywhere() { applyEditorBG(); for nc in noteWindows { nc.applyEditorBG() } }
    // Spell checking is the person's choice (off by default); it applies to every editor at once.
    func applySpellcheck() {
        if Runtime.isPreview { PreviewLog.record("spellcheck", Prefs.spellcheck ? "on" : "off") }
        textView.isContinuousSpellCheckingEnabled = Prefs.spellcheck
        for nc in noteWindows { nc.textView.isContinuousSpellCheckingEnabled = Prefs.spellcheck }
    }
    func applyEditorBG(restyle: Bool = true) {
        guard textView != nil else { return }
        let c = colorFromHex(Prefs.editorBGHex)
        textView.drawsBackground = true; textView.backgroundColor = c
        editorScroll.drawsBackground = true; editorScroll.backgroundColor = c
        let txt = editorTextColor()
        textView.insertionPointColor = txt
        textView.typingAttributes = [.font: editorFont(), .foregroundColor: txt]
        if restyle, let ts = textView.textStorage { mdStyler?.styleAll(ts) }   // re-render markdown with new colours
    }

    // MARK: formatting bar (the bar, its menus and the actions live in FormattingBar.swift)
    func buildToolsBar(width: CGFloat) -> NSView {
        let bar = FormattingBar(target: self, width: width)
        bar.frame = NSRect(x: 0, y: 0, width: width, height: toolsH)
        return bar
    }
    // Font family and size live in Settings (and View ▸ Bigger / Smaller / Actual Size), not on the bar.
    func setFontFamily(_ family: String) { Prefs.fontFamily = family; applyFontSize() }
    func setFontSize(_ size: Int) { Prefs.fontSize = Double(size); applyFontSize() }
    @objc func fontSmaller() { stepSize(-1) }
    @objc func fontBigger() { stepSize(1) }
    @objc func fontActualSize() { setFontSize(FontChoices.defaultSize) }
    private func stepSize(_ dir: Int) {
        let cur = Int(Prefs.fontSize)
        let idx = FontChoices.sizes.firstIndex(where: { $0 >= cur }) ?? 0
        let ni = max(0, min(FontChoices.sizes.count - 1, idx + dir))
        setFontSize(FontChoices.sizes[ni])
    }

    // Right-click ▸ Refresh: flush this editor's pending (unsaved) edit, then re-read the note (and, for the docked
    // pad, the notes list) from disk so changes made elsewhere — Obsidian, a sync client — show up.
    @objc func refreshActiveNote() {
        if let key = NSApp.keyWindow, let nc = noteWindows.first(where: { $0.window === key }) {
            if nc.saveWork.map({ !$0.isCancelled }) == true { guard nc.saveCurrent() else { return } }
            nc.reloadFromDisk(force: true)
            return
        }
        guard !viewingTrash else { return }
        if saveWork.map({ !$0.isCancelled }) == true { guard saveCurrent() else { return } }   // only a still-pending edit; a blind save would overwrite the outside change
        let stillThere = current.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        reloadNotes(selectFirst: !stillThere)
        if stillThere, let u = current {
            let sel = textView.selectedRange()
            currentMeta = store.readMeta(u)
            loadNoteIntoEditor(u)
            textView.setSelectedRange(NSRange(location: min(sel.location, (textView.string as NSString).length), length: 0))
        }
        flash("Refreshed ✓")
    }
    func loadNoteIntoEditor(_ url: URL) {
        currentUndoManager?.disableUndoRegistration()
        mdStyler?.isSuspended = true          // the text arrives in one go: style it once below, not line by line as it lands
        let body = store.read(url)
        textView.adaptLayout(toTextLength: body.utf16.count)
        textView.string = body
        mdStyler?.isSuspended = false
        currentUndoManager?.enableUndoRegistration()
        if let ts = textView.textStorage { mdStyler?.styleAll(ts) }
        refreshFormattingBar(for: textView)
    }
    // Sidebar row data (title + metadata + mod date), read off disk once per note and cached until
    // the file changes. Sorting and drawing the list used to re-read every note several times over.
    func noteInfo(_ url: URL) -> (meta: NoteMeta, title: String, snippet: String, modified: Date) {
        let mod = store.modificationDate(url) ?? .distantPast      // asked of the file system each time: a URL caches its resource values
        let size = store.fileSize(url) ?? -1
        if let hit = infoCache[url], hit.date == mod, hit.size == size { return (hit.meta, hit.title, hit.snippet, mod) }
        let (meta, body) = parseFrontmatter(store.readRaw(url))
        let title = noteTitle(body), snippet = MarkdownPlain.snippet(body)
        infoCache[url] = (mod, size, meta, title, snippet)
        return (meta, title, snippet, mod)
    }
    func titleForNote(_ url: URL) -> String { noteInfo(url).title }
    // Formatting acts on whichever editor is focused — the docked one or an undocked note window.
    var activeEditor: JotTextView {
        if let key = NSApp.keyWindow, let tv = key.firstResponder as? JotTextView { return tv }
        return textView
    }
    var activeStyler: MarkdownStyler { (activeEditor.textStorage?.delegate as? MarkdownStyler) ?? mdStyler }
    // MARK: notes list (sidebar — flat, sorted by pin → manual order → newest first)
    func reloadNotes(selectFirst: Bool) {
        rebuildNotes()
        if allNotes.isEmpty {
            do { current = try store.create(); rebuildNotes() }
            catch { showStorageError("A new note could not be created", error: error); return }
        }
        if selectFirst, let first = notes.first { select(first) }
        else if let c = current, let row = rowIndex(of: c) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
    }
    // The list's order — pins, then dragged positions, then newest first, within the unfiled notes and within each folder — is
    // NoteLibrary.layout (see Folders.swift); `noteEntry` is what it reads from a note.
    func noteEntry(_ u: URL) -> NoteLibrary.Entry {
        let info = noteInfo(u)
        return NoteLibrary.Entry(url: u, pin: info.meta.pin, order: info.meta.order, modified: info.modified, folder: info.meta.folder)
    }
    func select(_ url: URL) {
        pendingPick?.cancel()
        saveWork?.cancel()
        guard saveCurrent() else { return }
        rememberViewState()                       // the note you're leaving keeps your place
        current = url
        currentMeta = store.readMeta(url)
        currentUndoManager = perNoteUndoManager(url)
        mdStyler?.resetReveal()
        loadNoteIntoEditor(url)
        restoreViewState(for: url)
        fadeEditorIn()
        if let row = rowIndex(of: url) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
        applyEditorBG(restyle: false)
        updateHeaderBadges()
        refreshHeaderTitle()
        dropdown.makeFirstResponder(textView)
        revealActiveParagraph(textView, mdStyler)
    }
    // Caret and scroll position per note, for the session: come back to a long note and you're where you left it.
    func rememberViewState() {
        guard let c = current, !viewingTrash else { return }
        viewStates[c] = (textView.selectedRange(), editorScroll.contentView.bounds.origin.y)
    }
    func restoreViewState(for url: URL) {
        let length = (textView.string as NSString).length
        guard let saved = viewStates[url] else {                    // a note you haven't been in this session opens at the top
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollToBeginningOfDocument(nil)
            return
        }
        let location = min(saved.selection.location, length)
        textView.setSelectedRange(NSRange(location: location, length: min(saved.selection.length, length - location)))
        let maxY = max(0, (editorScroll.documentView?.frame.height ?? 0) - editorScroll.contentView.bounds.height)
        editorScroll.contentView.scroll(to: NSPoint(x: 0, y: min(saved.scrollY, maxY)))
        editorScroll.reflectScrolledClipView(editorScroll.contentView)
    }
    // Switching notes: a quick fade instead of a hard flash of different text (nothing under Reduce Motion).
    func fadeEditorIn() {
        guard animatesPad, dropdown.isVisible else { editorScroll.alphaValue = 1; return }
        editorScroll.alphaValue = 0.4
        animateWithFallback(duration: 0.12, { self.editorScroll.animator().alphaValue = 1 }, done: { self.editorScroll.alphaValue = 1 })
    }
    // A note lives in exactly one editor. Picking a note that has its own window brings that window forward instead of loading it into
    // the pad as well (which is what used to need the two-way sync code); the list's highlight goes back to the note the pad shows.
    func openOrSelect(_ url: URL) {
        guard let nc = noteWindows.first(where: { $0.url == url }) else { select(url); return }
        nc.window.makeKeyAndOrderFront(nil); jotActivate()
        hideTrayUnlessPinned()
        if let c = current, let row = rowIndex(of: c) { tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else { tableView.deselectAll(nil) }
    }
    func perNoteUndoManager(_ url: URL) -> UndoManager {
        if let m = undoManagers[url] { return m }
        let m = UndoManager(); m.levelsOfUndo = 0; undoManagers[url] = m; return m
    }

    // MARK: blank-note housekeeping
    // Jot wants exactly ONE empty scratch note lying around — the one you land on after a delete, or
    // when the dropdown opens fresh. Each of those moments used to mint a brand-new file, so the
    // sidebar slowly filled with untouched "New Note" rows. Now we reuse the blank note that already
    // exists and sweep up the strays.
    //
    // Blank = no body text and nothing the user set on it (a manual sort position doesn't count).
    func isBlankNote(_ u: URL) -> Bool {
        return store.isUndecoratedBlank(u)
    }
    // The blank note worth reusing: most recently touched one that isn't already open in its own window.
    private func reusableBlankNote() -> URL? {
        NoteLibrary.reusableBlank(in: store.all(), inWindows: Set(noteWindows.map { $0.url }), isBlank: isBlankNote)
    }
    // Discard every blank note except `keep` and the ones open in undocked windows. These files hold
    // no body and no metadata, so there is nothing to recover and nothing to send to Recently Deleted.
    // Callers must saveCurrent() first — an unsaved editor makes a note look blank on disk.
    @discardableResult
    func pruneBlankNotes(keeping keep: URL?) -> Int {
        let spared = Set(noteWindows.map { $0.url }).union([keep].compactMap { $0 })
        var removed = 0
        for u in NoteLibrary.strays(in: store.all(), spared: spared, isBlank: isBlankNote) {
            try? FileManager.default.removeItem(at: u)
            undoManagers[u] = nil
            infoCache[u] = nil
            if current == u { current = nil }
            removed += 1
        }
        return removed
    }

    @objc func newNote() {
        if viewingTrash { toggleTrashView() }
        let fromSecondary = noteWindows.contains { $0.window.isKeyWindow }
        openBlankNote()                     // reuses the empty note already sitting there, if any
        if fromSecondary, let u = current { openWindow(for: u) }
    }
    // Top-bar "Open in New Window": pop the current note into its own undocked window, then leave the
    // docked dropdown on a fresh blank note (so the moved note isn't shown in two places at once).
    @objc func openCurrentInNewWindow() {
        guard let u = current else { return }
        guard saveCurrent() else { return }
        openWindow(for: u)                       // (the pad moves on to a blank note by itself)
        jotActivate()
    }
    @objc func captureClipboard() {
        if viewingTrash { toggleTrashView() }
        let s = Runtime.pasteboard.string(forType: .string) ?? ""
        guard saveCurrent() else { return }
        let u: URL
        do { u = try store.create(); try store.saveExisting(s, to: u) }
        catch { showStorageError("The clipboard note could not be saved", error: error); return }
        pruneBlankNotes(keeping: u)
        rebuildNotes(); select(u)
        flash(s.isEmpty ? "Clipboard was empty" : "Captured clipboard ✓")
    }
    // Delete the OPEN note (or the full multi-selection). ⌘⌫ (list focus), ⇧⌘⌫ and the ⋯ menu act on the note you're looking at:
    // a key undocked window means THAT note.
    @objc func deleteCurrentNote() { deleteNote(inWindow: NSApp.keyWindow) }
    func deleteNote(inWindow key: NSWindow?) {
        guard !viewingTrash else { return }
        if let key = key, let editor = noteWindows.first(where: { $0.window === key }) {
            guard editor.saveCurrent() else { return }
            if moveNoteToRecentlyDeleted(editor.url) != nil { refreshSidebarKeepingSelection() }   // closes that window; the pad is untouched
            return
        }
        saveWork?.cancel()   // cancel pending autosave so it doesn't fire after current is nil
        guard saveCurrent() else { return }
        let selected = tableView.selectedRowIndexes
        if selected.count > 1 { deleteNotes(noteURLs(atRows: Array(selected))); return }
        // Prefer current; fall back to the selected row.
        var u: URL? = current
        if u == nil { u = noteURL(atRow: tableView.selectedRow) }
        guard let target = u else { return }
        deleteNotes([target])
    }

    // What an Undo needs to put a note back exactly: where it was, where it went, when it was last touched, its reminder.
    struct DeletedNote { let original: URL; let trash: URL; let modified: Date; let reminder: Date? }

    // The one way notes leave the list: into Recently Deleted (never the system Trash), the editor staying where it is unless its
    // own note went (then a fresh blank note), and a toast whose Undo restores them — name, content, place in the list, reminder.
    func deleteNotes(_ urls: [URL]) {
        guard !viewingTrash, !urls.isEmpty else { return }
        saveWork?.cancel()
        guard saveCurrent() else { return }
        let openWasDeleted = current.map { urls.contains($0) } ?? false
        var batch: [DeletedNote] = []
        for u in urls {
            guard let record = moveNoteToRecentlyDeleted(u) else { break }          // a failed move (already reported) stops here: nothing after it is touched
            batch.append(record)
        }
        guard !batch.isEmpty else { reloadNotes(selectFirst: current == nil); return }
        if openWasDeleted || current == nil { openBlankNote() } else { refreshSidebarKeepingSelection() }
        flash(batch.count == 1 ? "Moved to Recently Deleted" : "\(batch.count) notes moved to Recently Deleted", actionTitle: "Undo", duration: 6) { [weak self] in
            self?.undoDeletion(batch, reselect: openWasDeleted)
        }
    }
    func undoDeletion(_ batch: [DeletedNote], reselect: Bool) {
        var restored: [URL] = []
        for record in batch {
            do {
                let url = try store.restore(record.trash, as: record.original, modified: record.modified)
                restored.append(url)
                if let when = record.reminder, when > Date() { scheduleReminder(for: url, on: when) }      // deleting cancelled it
            } catch { showStorageError("The note could not be restored", error: error) }
        }
        guard !restored.isEmpty else { return }
        for u in restored { infoCache[u] = nil }
        if viewingTrash { trashed = store.trashedAll(); tableView.reloadData() }
        else if reselect, let first = restored.first {
            rebuildNotes()
            select(first)                         // the blank note opened after the delete stays (Jot keeps one scratch note); this is the one you want back
        } else { refreshSidebarKeepingSelection() }
        flash(restored.count == 1 ? "Restored" : "\(restored.count) notes restored")
    }
    func listContextMenu() -> NSMenu {
        if viewingTrash {
            let m = NSMenu()
            let r = NSMenuItem(title: "Restore", action: #selector(restoreClickedNote), keyEquivalent: ""); r.target = self; m.addItem(r)
            let d = NSMenuItem(title: "Delete Permanently", action: #selector(deletePermanentlyClickedNote), keyEquivalent: ""); d.target = self; m.addItem(d)
            return m
        }
        let m = NSMenu()
        m.delegate = self                      // filled in menuNeedsUpdate, when the right-click is known
        return m
    }
    // The notes list's right-click menu is built when it opens: the titles follow the clicked note(s) — Pin / Unpin, Set / Change
    // Reminder, "Delete 3 Notes" — and anything that doesn't apply is left out. A click inside a multi-selection acts on all of it.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === tableView.menu, !viewingTrash else { return }
        menu.removeAllItems()
        let row = tableView.clickedRow, selected = tableView.selectedRowIndexes
        if let folder = folderName(atRow: row) { populateFolderMenu(menu, folder: folder); return }
        let rows = row >= 0 ? (selected.contains(row) && selected.count > 1 ? Array(selected).sorted() : [row]) : []
        populateListMenu(menu, rows: rows)
    }
    func populateListMenu(_ menu: NSMenu, rows: [Int]) {
        let urls = noteURLs(atRows: rows)
        guard !urls.isEmpty else {                                     // empty space below the rows
            if !viewingTrash && !isFiltering { addNewFolderItem(to: menu) }
            return
        }
        let many = urls.count > 1
        let metas = urls.map { noteInfo($0).meta }
        let allPinned = metas.allSatisfy { $0.pin }
        @discardableResult func add(_ title: String, _ symbol: String, _ action: Selector, enabled: Bool = true) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: ""); i.target = self; i.image = sym(symbol); i.isEnabled = enabled
            menu.addItem(i); return i
        }
        add(many ? "Open \(urls.count) in New Windows" : "Open in New Window", "macwindow", #selector(openNoteWindow))
        add(allPinned ? (many ? "Unpin Notes" : "Unpin") : (many ? "Pin Notes" : "Pin"), allPinned ? "pin.slash" : "pin", #selector(toggleClickedNotePin))
        if !many {
            let has = metas[0].reminder != nil
            add(has ? "Change Reminder…" : "Remind Me…", has ? "bell.fill" : "bell", #selector(setReminderForClickedNote))
            if has { add("Clear Reminder", "bell.slash", #selector(clearReminderForClickedNote)) }
        }
        addFolderItem(to: menu, urls: urls)
        menu.addItem(.separator())
        add(many ? "Delete \(urls.count) Notes" : "Delete Note", "trash", #selector(deleteClickedNote))
        menu.addItem(.separator())
        add("Reset Manual Order", "arrow.up.arrow.down", #selector(resetManualOrder), enabled: notes.contains { noteInfo($0).meta.order != 0 })
    }
    @objc func deleteClickedNote() {
        let row = tableView.clickedRow
        let selected = tableView.selectedRowIndexes
        if selected.contains(row) && selected.count > 1 { deleteNotes(noteURLs(atRows: Array(selected))); return }
        guard let url = noteURL(atRow: row) else { return }
        deleteNotes([url])
    }
    // Save any detached editor before moving its file. Update UI and close editors only after the
    // recoverable move succeeds; a failed move keeps both the original and its editing session.
    @discardableResult
    private func moveNoteToRecentlyDeleted(_ url: URL) -> DeletedNote? {
        let editor = noteWindows.first { $0.url == url }
        if let editor = editor, !editor.saveCurrent() { return nil }
        let modified = store.modificationDate(url) ?? Date()
        let reminder = store.readMeta(url).reminder
        let trash: URL
        do { trash = try store.delete(url) }
        catch { showStorageError("The note could not be moved to Recently Deleted", error: error); return nil }
        cancelReminder(for: url)
        undoManagers[url] = nil; infoCache[url] = nil; viewStates[url] = nil
        if current == url { current = nil }                         // (the list drops the row when the caller rebuilds it, so it can slide out)
        editor?.closeAfterDeletion()
        return DeletedNote(original: url, trash: trash, modified: modified, reminder: reminder)
    }
    @objc func openNoteWindow() {
        guard !viewingTrash else { return }
        let clicked = tableView.clickedRow
        guard noteURL(atRow: clicked) != nil else { return }
        let sel = tableView.selectedRowIndexes
        let rows = (sel.contains(clicked) && sel.count > 1) ? Array(sel) : [clicked]
        for url in noteURLs(atRows: rows) { openWindow(for: url) }
        jotActivate()
    }
    // Opens (or re-focuses) an undocked window for a note. Returns the controller.
    @discardableResult
    func openWindow(for url: URL) -> NoteWindowController {
        if let existing = noteWindows.first(where: { $0.url == url }) {
            existing.window.makeKeyAndOrderFront(nil); hideTrayUnlessPinned(); return existing
        }
        // The new window reads the note from disk, so the pad's own unsaved edits to it go first (once the
        // window is open, the pad no longer saves that note — the window is authoritative).
        if url == current { saveWork?.cancel(); _ = saveCurrent() }
        let nc = NoteWindowController(url: url, store: store, appDelegate: self)
        let padWasShowingIt = url == current
        // Position near the current key window (or the dropdown), not bottom-left.
        let base: NSWindow = NSApp.keyWindow ?? dropdown
        let bf = base.frame
        let vis = (base.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var origin = NSPoint(x: bf.origin.x + 22, y: bf.origin.y - 22)
        origin.x = min(max(origin.x, vis.minX), vis.maxX - nc.window.frame.width)
        origin.y = max(origin.y, vis.minY)
        nc.window.setFrameOrigin(origin)
        noteWindows.append(nc)
        if padWasShowingIt { current = nil; openBlankNote() }     // one editor per note: the pad moves on to a blank note
        nc.window.makeKeyAndOrderFront(nil)
        hideTrayUnlessPinned()     // the floating pad would otherwise sit on top of the window you just opened
        return nc
    }
    // Lets an undocked note window keep the sidebar row title in sync after an edit.
    // A note window changed its note: its row (title, snippet, time) follows. The pad never shows a note that has a window of its own
    // (one editor per note), so there is nothing to mirror.
    func refreshRowIfVisible(for url: URL) {
        infoCache[url] = nil
        let row = rowIndex(of: url) ?? -1
        if row >= 0 { tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0)) }
    }

    // MARK: Recently Deleted — the sidebar list toggles between live notes and the 30-day trash.
    @objc func showRecentlyDeleted() {
        if !dropdown.isVisible { presentDropdown() }
        toggleTrashView()
    }
    @objc func toggleTrashView() {
        if !viewingTrash, !saveCurrent() { return }
        viewingTrash.toggle()
        if viewingTrash {
            noteBeforeTrash = current
            current = nil   // trash preview does not own or mutate a live note
            if !sidebarShown { sidebarShown = true; Prefs.sidebarShown = true; applySidebarVisibility() }
            trashed = store.trashedAll()
            tableView.menu = listContextMenu()
            tableView.reloadData()
            textView.string = ""
            textView.isEditable = false
            updateHeaderBadges()
            refreshHeaderTitle()
        } else {
            textView.isEditable = true
            tableView.menu = listContextMenu()
            // The text view contains a trash preview, not the live current note. Clear ownership
            // before select() can autosave, then reload the live note from disk.
            let previous = noteBeforeTrash
            noteBeforeTrash = nil
            current = nil
            reloadNotes(selectFirst: false)
            if let previous = previous, notes.contains(previous) { select(previous) }
            else if let first = notes.first { current = nil; select(first) }
        }
        trashToggle.contentTintColor = viewingTrash ? .controlAccentColor : .secondaryLabelColor
        updateTrashChrome()
    }
    @objc func restoreClickedNote() { restoreTrashed(at: tableView.clickedRow) }
    @objc func restoreSelectedTrashed() { restoreTrashed(at: tableView.selectedRow) }
    // Restore from Recently Deleted: the note returns to the top of the list (modified now) and its reminder is scheduled again.
    private func restoreTrashed(at row: Int) {
        guard viewingTrash, row >= 0, row < trashed.count else { return }
        let url: URL
        do { url = try store.restore(trashed[row]) }
        catch { showStorageError("The note could not be restored", error: error); return }
        if let when = store.readMeta(url).reminder, when > Date() { scheduleReminder(for: url, on: when) }
        trashed.remove(at: row); tableView.reloadData()
        if !trashed.isEmpty { tableView.selectRowIndexes(IndexSet(integer: min(row, trashed.count - 1)), byExtendingSelection: false) }
        else { textView.string = "" }
        updateTrashChrome()
        flash("Restored ✓")
    }
    // In Recently Deleted the header's New button becomes Restore (for the selected note); elsewhere it is New.
    func updateTrashChrome() {
        guard let b = newButton else { return }
        if viewingTrash {
            b.title = "Restore"; b.image = sym("arrow.uturn.backward"); b.action = #selector(restoreSelectedTrashed)
            b.isEnabled = tableView.selectedRow >= 0 && tableView.selectedRowIndexes.count == 1
            b.toolTip = "Restore the selected note"; b.setAccessibilityLabel("Restore note")
        } else {
            b.title = "New"; b.image = sym("square.and.pencil"); b.action = #selector(newNote); b.isEnabled = true
            b.toolTip = "New note (⌘N)"; b.setAccessibilityLabel("New note")
        }
    }
    @objc func deletePermanentlyClickedNote() {
        let row = tableView.clickedRow
        guard viewingTrash, row >= 0, row < trashed.count else { return }
        store.deletePermanently(trashed[row]); trashed.remove(at: row); tableView.reloadData()
    }

    func refreshSidebarKeepingSelection() {
        guard !viewingTrash else { return }
        let keep = current
        rebuildNotes()
        if let c = keep, let row = rowIndex(of: c) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    // MARK: NSTableView data source + delegate
    func numberOfRows(in tableView: NSTableView) -> Int { viewingTrash ? trashed.count : sidebarItems.count }
    func tableView(_ t: NSTableView, heightOfRow row: Int) -> CGFloat { folderName(atRow: row) == nil ? t.rowHeight : JotUI.folderRowHeight }
    // Folder headers fold and unfold on a click (NoteTableView); they are never "the open note".
    func tableView(_ t: NSTableView, shouldSelectRow row: Int) -> Bool { folderName(atRow: row) == nil }
    func tableView(_ t: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if let name = folderName(atRow: row) { return folderHeaderCell(t, name: name) }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = t.makeView(withIdentifier: id, owner: self) as? NoteListCell ?? {
            let c = NoteListCell(frame: .zero); c.identifier = id
            return c
        }()
        let url: URL
        if viewingTrash { guard row >= 0, row < trashed.count else { return cell }; url = trashed[row] }
        else { guard let u = noteURL(atRow: row) else { return cell }; url = u }
        let info = noteInfo(url)
        cell.configure(title: info.title, snippet: info.snippet, time: RelativeTime.short(info.modified),
                       pinned: !viewingTrash && info.meta.pin, reminder: !viewingTrash && info.meta.reminder != nil, trashed: viewingTrash,
                       indented: !viewingTrash && !NoteLibrary.folder(atRow: row, in: sidebarItems).isEmpty)
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        let sel = tableView.selectedRowIndexes
        if sel.count > 1 { return }   // multi-select: preserve selection, don't change editor
        let row = tableView.selectedRow
        if viewingTrash {
            updateTrashChrome()
            guard row >= 0, row < trashed.count else { return }
            textView.string = store.read(trashed[row])
            if let ts = textView.textStorage { mdStyler?.styleAll(ts) }
            return
        }
        guard let url = noteURL(atRow: row), url != current else { return }
        if let e = NSApp.currentEvent, e.type == .keyDown, e.isARepeat {            // holding ↑/↓: load the note you stop on, not every one you pass
            pendingPick?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.openOrSelect(url) }
            pendingPick = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
            return
        }
        openOrSelect(url)
    }

    // Context menu actions (operate on the right-clicked row via tableView.clickedRow)
    @objc func toggleClickedNotePin() {
        let row = tableView.clickedRow; guard noteURL(atRow: row) != nil else { return }
        let selected = tableView.selectedRowIndexes
        let rows = selected.contains(row) && selected.count > 1 ? Array(selected) : [row]
        let urls = noteURLs(atRows: rows)
        let makePinned = !urls.allSatisfy { noteInfo($0).meta.pin }       // all pinned → unpin them; otherwise pin them all
        for url in urls {
            var meta = store.readMeta(url); meta.pin = makePinned; store.writeMeta(meta, to: url)
            infoCache[url] = nil
            if url == current { currentMeta = meta }
        }
        refreshSidebarKeepingSelection()
    }
    @objc func setReminderForClickedNote() {
        guard let url = noteURL(atRow: tableView.clickedRow) else { return }
        select(url)
        if let anchor = moreButton { showReminderPopover(anchor) }
    }
    @objc func clearReminderForClickedNote() {
        guard let url = noteURL(atRow: tableView.clickedRow) else { return }
        var meta = store.readMeta(url); meta.reminder = nil; store.writeMeta(meta, to: url)
        cancelReminder(for: url)
        if url == current { currentMeta = meta; updateHeaderBadges() }
        flash("Reminder cleared")
    }
    // MARK: Drag-and-drop reorder (NSTableView)
    func tableView(_ t: NSTableView, writeRowsWith rowIndexes: IndexSet, to pboard: NSPasteboard) -> Bool {
        guard !isFiltering else { return false }          // a position in a partial list means nothing
        guard !viewingTrash, let first = rowIndexes.first, let dragged = noteURL(atRow: first) else { return false }
        pboard.setString(dragged.path, forType: .fileURL)
        pboard.setString(String(first), forType: .string)
        return true
    }
    // A drop is a move: onto a folder's header it files the note there; between rows it puts the note in that gap's group (Folders.swift).
    func tableView(_ t: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard !viewingTrash, let target = NoteLibrary.dropTarget(row: row, onRow: op == .on, items: sidebarItems, collapsed: collapsedFolderSet) else { return [] }
        if op == .on, case .group = target { t.setDropRow(row, dropOperation: .above) }         // a note row is never dropped ON, only between
        return .move
    }
    func tableView(_ t: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        guard !viewingTrash, let pbItem = info.draggingPasteboard.pasteboardItems?.first,
              let path = pbItem.string(forType: .fileURL) else { return false }
        // The pasteboard carries a plain POSIX path — URL(string:) returns nil on the space in
        // "Application Support", which used to make every drop silently fail.
        let src = URL(fileURLWithPath: path)
        guard notes.contains(src),
              let target = NoteLibrary.dropTarget(row: row, onRow: op == .on, items: sidebarItems, collapsed: collapsedFolderSet) else { return false }
        dropNote(src, onto: target)
        return true
    }
    // Frontmatter-only edits shouldn't make a note look freshly modified — that would reshuffle the
    // date-sorted part of the list every time you drag a row or clear the manual order.
    func writeMetaPreservingDate(_ meta: NoteMeta, to u: URL) {
        let mod = store.modificationDate(u)
        store.writeMeta(meta, to: u)
        if let mod { try? FileManager.default.setAttributes([.modificationDate: mod], ofItemAtPath: u.path) }
        infoCache[u] = nil
    }
    // Clears every dragged position, returning the sidebar to plain newest-first (pins still lead).
    @objc func resetManualOrder() {
        for u in store.all() {
            var meta = store.readMeta(u)
            guard meta.order != 0 else { continue }
            meta.order = 0
            writeMetaPreservingDate(meta, to: u)
        }
        refreshSidebarKeepingSelection()
        flash("Manual order cleared")
    }

    // MARK: Reminders (UserNotifications — schedule/cancel based on frontmatter)
    func reconcileReminders() {
        guard let center = notificationCenter() else { return }
        center.getPendingNotificationRequests { [weak self] requests in
            guard let self = self else { return }
            let scheduledIDs = Set(requests.map { $0.identifier })
            let allNotes = self.store.all()
            let noteIDs = Set(allNotes.map { $0.deletingPathExtension().lastPathComponent })
            // Cancel notifications for deleted notes
            let stale = scheduledIDs.subtracting(noteIDs)
            if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: Array(stale)) }
            // Schedule notifications for notes with future reminders that aren't scheduled
            for url in allNotes {
                let meta = self.store.readMeta(url)
                let id = url.deletingPathExtension().lastPathComponent
                if let r = meta.reminder, r > Date() {
                    if !scheduledIDs.contains(id) { self.scheduleReminder(for: url, on: r) }
                } else if scheduledIDs.contains(id) {
                    center.removePendingNotificationRequests(withIdentifiers: [id])
                }
            }
        }
    }
    func scheduleReminder(for url: URL, on date: Date) {
        guard let center = notificationCenter() else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { DispatchQueue.main.async { self.reminderNotAuthorized() }; return }       // never leave a bell that can't ring
            let content = UNMutableNotificationContent()
            content.title = noteTitle(self.store.read(url))
            content.body = "Reminder for your Jot note"
            content.sound = .default
            content.userInfo = ["path": url.path]
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let id = url.deletingPathExtension().lastPathComponent
            let req = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            center.removePendingNotificationRequests(withIdentifiers: [id])   // replace if exists
            center.add(req) { _ in }
        }
    }
    // Notifications are off for Jot: say so at the moment it matters, with a way to fix it.
    func reminderNotAuthorized() {
        flash("Notifications are off for Jot, so this reminder won't alert you", actionTitle: "Open Settings…", duration: 8) { AppDelegate.openNotificationSettings() }
    }
    static func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        if Runtime.isPreview { PreviewLog.record("open-settings", url.absoluteString) } else { NSWorkspace.shared.open(url) }
    }
    func cancelReminder(for url: URL) {
        let id = url.deletingPathExtension().lastPathComponent
        notificationCenter()?.removePendingNotificationRequests(withIdentifiers: [id])
    }

    @objc func showReminderPopover(_ sender: NSButton) {
        guard let u = current else { return }
        let popover = NSPopover()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 100))
        let picker = NSDatePicker(frame: NSRect(x: 12, y: 48, width: 216, height: 28))
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinute]
        picker.minDate = Date()
        if let r = store.readMeta(u).reminder { picker.dateValue = r }
        else { picker.dateValue = Date().addingTimeInterval(3600) }   // default: 1 hour from now
        content.addSubview(picker)
        let setBtn = NSButton(title: "Set", target: self, action: #selector(setReminderFromPopover))
        setBtn.frame = NSRect(x: 12, y: 10, width: 60, height: 24); setBtn.bezelStyle = .rounded
        content.addSubview(setBtn)
        let clearBtn = NSButton(title: "Clear", target: self, action: #selector(clearReminder))
        clearBtn.frame = NSRect(x: 80, y: 10, width: 60, height: 24); clearBtn.bezelStyle = .rounded
        clearBtn.isEnabled = store.readMeta(u).reminder != nil
        content.addSubview(clearBtn)
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = content
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        reminderPicker = picker
        reminderPopover = popover
    }
    @objc func setReminderFromPopover() {
        guard let u = current, let picker = reminderPicker else { return }
        let date = picker.dateValue
        var meta = store.readMeta(u)
        meta.reminder = date
        store.writeMeta(meta, to: u)
        currentMeta = meta
        scheduleReminder(for: u, on: date)
        updateHeaderBadges()
        reminderPopover?.close()
        let fmt = DateFormatter(); fmt.dateStyle = .medium; fmt.timeStyle = .short
        flash("Reminder set for \(fmt.string(from: date))")
    }
    @objc func clearReminder() {
        guard let u = current else { return }
        var meta = store.readMeta(u)
        meta.reminder = nil
        store.writeMeta(meta, to: u)
        currentMeta = meta
        cancelReminder(for: u)
        updateHeaderBadges()
        reminderPopover?.close()
        flash("Reminder cleared")
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["path"] as? String {
            let url = URL(fileURLWithPath: path)
            DispatchQueue.main.async {
                if !self.dropdown.isVisible { self.toggleDropdown() }
                if self.notes.contains(url) { self.select(url) }
            }
        }
        completionHandler()
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])   // show even if Jot is frontmost
    }

    // MARK: editor autosave (debounced — handles huge text gracefully)
    func textDidChange(_ notification: Notification) {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveCurrent(reloadRow: true) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView, tv === textView else { return }
        revealActiveParagraph(tv, mdStyler)
        refreshFormattingBar(for: textView)
    }
    @discardableResult
    func saveCurrent(reloadRow: Bool = false) -> Bool {
        saveWork?.cancel()
        guard !viewingTrash, let u = current, FileManager.default.fileExists(atPath: u.path) else { return true }
        let body = textView.string
        do {
            try store.saveExisting(body, to: u)
        } catch {
            showStorageError("The note could not be saved", error: error)
            return false
        }
        infoCache[u] = nil                         // we just wrote it: whatever was cached for its row and title is stale
        if reloadRow { let r = rowIndex(of: u) ?? -1; if r >= 0 { tableView.reloadData(forRowIndexes: IndexSet(integer: r), columnIndexes: IndexSet(integer: 0)) }; refreshHeaderTitle() }
        return true
    }
    func applyFontSize() {
        settingsController?.refreshEditorControls()
        let tv = activeEditor
        tv.font = editorFont()
        tv.typingAttributes = [.font: editorFont(), .foregroundColor: editorTextColor()]
        if let ts = tv.textStorage { (tv.textStorage?.delegate as? MarkdownStyler ?? mdStyler)?.styleAll(ts) }
    }

    // MARK: action bar
    // ⋯ — everything occasional: pin, reminder, new window, delete, Recently Deleted, Settings, About, Quit.
    @objc func showNoteActions(_ sender: NSButton) {
        noteActionsMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
    }
    func noteActionsMenu() -> NSMenu {
        let menu = NSMenu()
        @discardableResult func item(_ title: String, _ symbol: String?, _ action: Selector, key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
            i.target = self; if let symbol = symbol { i.image = sym(symbol) }; menu.addItem(i); return i
        }
        let pin = item(isPinned ? "Stop Keeping on Top" : "Keep on Top", isPinned ? "pin.slash" : "pin", #selector(togglePin(_:)))
        pin.state = isPinned ? .on : .off
        item(currentMeta.reminder == nil ? "Remind Me…" : "Change Reminder…", currentMeta.reminder == nil ? "bell" : "bell.fill", #selector(remindFromMenu))
        menu.addItem(.separator())
        item("New Note from Clipboard", "doc.on.clipboard", #selector(captureClipboard))
        item("Open in New Window", "macwindow", #selector(openCurrentInNewWindow))
        if !viewingTrash, let shown = current { addFolderItem(to: menu, urls: [shown]) }
        menu.addItem(.separator())
        item("Delete Note", "trash", #selector(deleteCurrentNote))
        item(viewingTrash ? "Back to Notes" : "Recently Deleted", "trash.circle", #selector(showRecentlyDeleted))
        menu.addItem(.separator())
        item("Show Notes in Finder", "folder", #selector(showNotesInFinder))
        item("Settings…", "gearshape", #selector(openSettings), key: ",")
        item("About Jot", "info.circle", #selector(showAbout))
        item("Quit Jot", nil, #selector(NSApplication.terminate(_:)), key: "q")
        return menu
    }
    @objc func remindFromMenu() { if let anchor = moreButton { showReminderPopover(anchor) } }
    @objc func showNotesInFinder() { NSWorkspace.shared.open(store.dir) }

    // Share — one menu for everything that sends the note somewhere (each entry can be hidden in Settings).
    @objc func showPadShareMenu(_ sender: NSButton) {
        shareMenu(anchor: sender).popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
    }
    func shareMenu(anchor: NSButton) -> NSMenu {
        let menu = NSMenu()
        shareAnchor = anchor
        func item(_ id: String, _ title: String, _ symbol: String, _ action: Selector) {
            guard Prefs.show(id) else { return }
            let i = NSMenuItem(title: title, action: action, keyEquivalent: ""); i.target = self; i.image = sym(symbol); menu.addItem(i)
        }
        item("notes", "Apple Notes", "note.text", #selector(toNotes))
        item("stickies", "Stickies", "note", #selector(toStickies))
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        if Prefs.show("save") {
            let save = NSMenuItem(title: "Save As", action: nil, keyEquivalent: ""); save.image = sym("square.and.arrow.down")
            let sub = NSMenu()
            for (t, ext) in [("Plain Text", "txt"), ("Markdown", "md"), ("Rich Text", "rtf"), ("HTML", "html"), ("PDF", "pdf")] {
                let it = NSMenuItem(title: t, action: #selector(saveAs(_:)), keyEquivalent: ""); it.target = self; it.representedObject = ext; sub.addItem(it)
            }
            save.submenu = sub; menu.addItem(save)
        }
        item("share", "Share…", "square.and.arrow.up", #selector(shareFromMenu))
        item("copy", "Copy as Text", "doc.on.doc", #selector(toCopy))
        return menu
    }
    @objc func shareFromMenu() { if let anchor = shareAnchor { toShare(anchor) } }

    private var text: String { activeEditor.string }
    // A message for the window you're looking at (the pad, or a note window), as a toast — never over the note's title.
    func flash(_ msg: String, actionTitle: String? = nil, duration: TimeInterval? = nil, action: (() -> Void)? = nil) {
        var window: NSWindow = dropdown
        var inset: CGFloat = toolsBar?.isHidden == false ? toolsH : 0
        if let key = NSApp.keyWindow, let nc = noteWindows.first(where: { $0.window === key }) { window = key; inset = nc.toolsBar?.isHidden == false ? nc.toolsH : 0 }
        ToastCenter.shared.show(msg, in: window, bottomInset: inset, actionTitle: actionTitle, duration: duration, action: action)
    }
    // The header shows the open note's plain title (a message never replaces it).
    func refreshHeaderTitle() {
        statusLabel?.stringValue = viewingTrash ? "Recently Deleted · clears after 30 days" : (current.map { titleForNote($0) } ?? "")
    }
    func updateHeaderBadges() {
        reminderButton?.isHidden = currentMeta.reminder == nil || viewingTrash
        pinButton?.isHidden = !isPinned
    }

    // MARK: export / send
    @objc func toCopy() { Runtime.pasteboard.clearContents(); Runtime.pasteboard.setString(text, forType: .string); flash("Copied ✓") }

    @objc func toStickies() {
        if Runtime.isPreview { PreviewLog.record("stickies"); flash("Preview: not sent"); return }
        let s = text
        guard !s.isEmpty else { flash("Nothing to send"); return }
        // Preferred path: the macOS "Make New Sticky Note" Service (NSMessage makeStickyFromTextService —
        // confirmed registered via `pbs`). It builds a sticky straight from a pasteboard: no Accessibility,
        // no keystrokes, no focus/timing games. (The keystroke route was sending ⌘N/⌘V while Jot still had
        // key focus, so it pasted back into Jot, not Stickies — which is why the note never appeared.)
        // The Service's NSSendTypes are public.plain-text / public.rtf / flat-rtfd — NOT .string
        // (public.utf8-plain-text), so we must declare public.plain-text or it rejects us. (On current
        // macOS this Service is a no-op and returns false anyway — kept in case Apple revives it, since
        // it's the only path that needs no Accessibility.)
        let pt = NSPasteboard.PasteboardType("public.plain-text")
        let pb = NSPasteboard(name: NSPasteboard.Name("JotStickiesService"))
        pb.declareTypes([pt], owner: nil)
        pb.setString(s, forType: pt)
        if NSPerformService("Make New Sticky Note", pb) { flash("Sent to Stickies ✓"); return }
        stickiesViaKeystrokes(s)   // the real path on current macOS — needs Accessibility for Jot
    }
    // Fallback: drive Stickies from the keyboard (needs Accessibility for Jot). Waits until Stickies is
    // genuinely frontmost before typing so the keystrokes land in the new sticky, not back in Jot.
    private func stickiesViaKeystrokes(_ s: String) {
        // The keystroke route pastes from the clipboard, so the note goes there for a moment — and your own clipboard comes back afterwards.
        let saved = AppDelegate.snapshotPasteboard(Runtime.pasteboard)
        Runtime.pasteboard.clearContents()
        Runtime.pasteboard.declareTypes([.string], owner: nil)
        Runtime.pasteboard.setString(s, forType: .string)
        let src = """
        tell application "Stickies" to activate
        tell application "System Events"
            repeat 30 times
                if exists (process "Stickies") then
                    if frontmost of process "Stickies" then exit repeat
                end if
                delay 0.1
            end repeat
            delay 0.3
            tell process "Stickies"
                keystroke "n" using {command down}
                delay 0.5
                keystroke "v" using {command down}
            end tell
        end tell
        """
        DispatchQueue.global().async {
            var err: NSDictionary?
            NSAppleScript(source: src)?.executeAndReturnError(&err)
            DispatchQueue.main.async { self.finishStickies(err, savedClipboard: saved, note: s) }
        }
    }
    private func finishStickies(_ err: NSDictionary?, savedClipboard: [[NSPasteboard.PasteboardType: Data]], note: String) {
        func restoreClipboard() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { AppDelegate.restorePasteboard(Runtime.pasteboard, savedClipboard) } }
        guard let err = err else { restoreClipboard(); flash("Sent to Stickies ✓"); return }
        let message = SendErrors.stickies(code: (err["NSAppleScriptErrorNumber"] as? Int) ?? 0, message: (err["NSAppleScriptErrorMessage"] as? String) ?? "")
        if message.opensAccessibilitySettings {
            // No Accessibility grant: don't just fail. The note stays on the clipboard, Stickies opens, and the toast says what to press.
            if let stickies = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Stickies") { NSWorkspace.shared.openApplication(at: stickies, configuration: NSWorkspace.OpenConfiguration()) }
            flash("Copied — in Stickies press ⌘N, then ⌘V", actionTitle: "Allow Accessibility…", duration: 8) {
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
            return
        }
        restoreClipboard()
        flash(message.text, actionTitle: message.opensAutomationSettings ? "Open Settings…" : nil, duration: 8) { AppDelegate.openAutomationSettings() }
    }
    static func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        if Runtime.isPreview { PreviewLog.record("open-settings", url.absoluteString) } else { NSWorkspace.shared.open(url) }
    }
    // A copy of everything on a pasteboard, and the way back — so borrowing the clipboard never costs anyone what they had on it.
    static func snapshotPasteboard(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { copy[type] = data } }
            return copy
        }
    }
    static func restorePasteboard(_ pb: NSPasteboard, _ items: [[NSPasteboard.PasteboardType: Data]]) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        pb.writeObjects(items.map { copy -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in copy { item.setData(data, forType: type) }
            return item
        })
    }
    @objc func toNotes() {
        if Runtime.isPreview { PreviewLog.record("notes"); flash("Preview: not sent"); return }
        let body = text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
        let escaped = body.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let src = "tell application \"Notes\" to make new note with properties {body:\"\(escaped)\"}"
        DispatchQueue.global().async {
            var err: NSDictionary?
            NSAppleScript(source: src)?.executeAndReturnError(&err)
            DispatchQueue.main.async {
                guard let err = err else { self.flash("Saved to Apple Notes ✓"); return }
                let message = SendErrors.appleNotes(code: (err["NSAppleScriptErrorNumber"] as? Int) ?? 0)
                self.flash(message.text, actionTitle: message.opensAutomationSettings ? "Open Settings…" : nil, duration: 8) { AppDelegate.openAutomationSettings() }
            }
        }
    }
    @objc func toShare(_ sender: NSButton) {
        if Runtime.isPreview { PreviewLog.record("share"); return }
        NSSharingServicePicker(items: [text]).show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }
    @objc func toSave(_ sender: NSButton) {
        let menu = NSMenu()
        for (t, ext) in [("Plain Text", "txt"), ("Markdown", "md"), ("Rich Text", "rtf"), ("HTML", "html"), ("PDF", "pdf")] {
            let it = NSMenuItem(title: t, action: #selector(saveAs(_:)), keyEquivalent: ""); it.target = self; it.representedObject = ext; menu.addItem(it)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }
    @objc func saveAs(_ sender: NSMenuItem) {
        guard let ext = sender.representedObject as? String else { return }
        if Runtime.isPreview { PreviewLog.record("save", ext); return }
        let body = text
        let panel = NSSavePanel(); panel.nameFieldStringValue = safeFilename(body) + "." + ext
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            do { try self.writeNote(body, to: url, ext: ext); self.flash("Saved \(url.lastPathComponent) ✓") }
            catch { self.flash("Couldn't save \(url.lastPathComponent): \(error.localizedDescription)") }      // never claim a save that didn't happen
        }
    }
    // Formatted (bold, italic, headings) rich text for the RTF export. The note stays Markdown.
    func exportAttributed(_ markdown: String) -> NSAttributedString {
        markdownToRichText(markdown, baseFont: .systemFont(ofSize: 13), color: .black)
    }
    enum ExportError: LocalizedError {
        case couldNotRender(String)
        var errorDescription: String? { if case .couldNotRender(let what) = self { return "the \(what) could not be produced" }; return nil }
    }
    // Writes a note in one of the Save As formats; throws instead of failing quietly.
    func writeNote(_ body: String, to url: URL, ext: String) throws {
        switch ext {
        case "rtf":
            let a = exportAttributed(body)
            guard let d = a.rtf(from: NSRange(location: 0, length: a.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else { throw ExportError.couldNotRender("Rich Text") }
            try d.write(to: url, options: .atomic)
        case "html":
            try MarkdownHTML.document(body, title: noteTitle(body)).write(to: url, atomically: true, encoding: .utf8)
        case "pdf":
            guard let d = pdfData(from: body) else { throw ExportError.couldNotRender("PDF") }
            try d.write(to: url, options: .atomic)
        default:
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
    }
    // A real multi-page PDF: US Letter, 0.75" margins, the formatted note flowing from page to page (it used to be one very tall page).
    func pdfData(from body: String) -> Data? {
        let page = CGSize(width: 612, height: 792), margin: CGFloat = 54
        let storage = NSTextStorage(attributedString: exportAttributed(body.isEmpty ? " " : body))
        let layout = NSLayoutManager(); storage.addLayoutManager(layout)
        let area = CGSize(width: page.width - 2 * margin, height: page.height - 2 * margin)
        var containers: [NSTextContainer] = []
        repeat {
            let container = NSTextContainer(size: area); container.lineFragmentPadding = 0
            layout.addTextContainer(container); containers.append(container)
            layout.ensureLayout(for: container)
        } while NSMaxRange(layout.glyphRange(for: containers.last!)) < layout.numberOfGlyphs && containers.count < 2_000
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var box = CGRect(origin: .zero, size: page)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        for container in containers {
            context.beginPDFPage(nil)
            context.translateBy(x: 0, y: page.height); context.scaleBy(x: 1, y: -1)             // top-left origin, like a text view
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let glyphs = layout.glyphRange(for: container)
            layout.drawBackground(forGlyphRange: glyphs, at: CGPoint(x: margin, y: margin))
            layout.drawGlyphs(forGlyphRange: glyphs, at: CGPoint(x: margin, y: margin))
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    // MARK: open/close + chrome (reused from the suite)
    // Tray = .floating (above the active app, below Spotlight); detached = .normal (regular window);
    // pinned = above other apps.
    func applyDropdownLevel() {
        if isPinned {
            dropdown.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        } else if Prefs.detached {
            dropdown.level = .normal
        } else {
            dropdown.level = .floating
        }
    }
    @objc func toggleDropdown() { toggleTray(fromHotkey: false) }   // menu-bar icon: a plain toggle
    // The global shortcut brings a visible-but-unfocused pad (pinned, dragged away, behind another window)
    // forward instead of hiding it; only a pad you're already in is hidden by it.
    func toggleTray(fromHotkey: Bool) {
        if isPadShowing && dropdown.isOnActiveSpace {
            if fromHotkey && (!dropdown.isKeyWindow || !NSApp.isActive) {
                dropdown.makeKeyAndOrderFront(nil); jotActivate(); dropdown.makeFirstResponder(textView); return
            }
            guard saveCurrent() else { return }
            lastActivity = Date()
            resetToTrayAnchor()                 // any close → next open re-anchors under the menu-bar icon
            hidePad(); return
        }
        if viewingTrash {
            lastActivity = Date()
            presentDropdown()
            sidebarShown = true; applySidebarVisibility()
            return
        }
        let fresh = shouldOpenFresh()           // launch, or 30-min idle with all notes closed
        reloadNotes(selectFirst: !fresh && current == nil)
        if fresh { openBlankNote() }
        lastActivity = Date()
        presentDropdown()
    }
    // Open onto a brand-new blank note when: (a) this is the first open since launch (lastActivity == nil),
    // or (b) it's been >30 min since the last activity AND no note windows are open (everything was closed).
    func shouldOpenFresh() -> Bool {
        guard Prefs.startOnNewNote else { return false }            // Settings ▸ "Start each session on a new note" is off
        guard let last = lastActivity else { return true }          // first open of this launch
        return noteWindows.isEmpty && Date().timeIntervalSince(last) > 1800
    }
    // Put the docked dropdown on an empty note and select it (no secondary window). Reuses the blank
    // note that's already there rather than minting another, and sweeps up any other strays.
    private func openBlankNote() {
        saveWork?.cancel()
        guard saveCurrent() else { return }
        var u = reusableBlankNote()
        if u == nil {
            let fresh: URL
            do { fresh = try store.create() }
            catch { showStorageError("A new note could not be created", error: error); return }
            u = fresh
        }
        guard let target = u else { return }
        pruneBlankNotes(keeping: target)
        rebuildNotes(); select(target)
    }
    // Reset to tray state so the next open anchors under the menu-bar icon (forgets any dragged-off frame).
    private func resetToTrayAnchor() {
        Prefs.detached = false
        Prefs.d.removeObject(forKey: "jotFrame")
    }
    func presentDropdown() {
        if sidebarShown { sidebarShown = false; Prefs.sidebarShown = false; applySidebarVisibility() }  // always open with the notes list hidden
        clearFilter()
        suppressMoveSave = true
        if !Runtime.isPreview { restorePadSize() }      // the size you left it at, wherever it opens
        if Runtime.isPreview {
            positionForPreview()                        // no status item in a preview
        } else if Prefs.detached, let saved = savedFrame() {   // moved/pinned before → reopen there
            dropdown.setFrame(fitted(saved), display: false)
        } else {
            positionUnderStatusItem()                   // tray mode → re-anchor under the icon
        }
        suppressMoveSave = false
        applyDropdownLevel()
        showPad()
        dropdown.makeFirstResponder(textView)
    }
    func windowDidMove(_ n: Notification) {
        guard let w = n.object as? NSWindow, w === dropdown, !suppressMoveSave else { return }
        // Only a person dragging (left button down) detaches the tray; AppKit, Spaces and display changes move windows too.
        guard leftMouseIsDown else { return }
        Prefs.detached = true                 // user dragged it off the anchor → becomes a normal window
        applyDropdownLevel()
        Prefs.d.set(NSStringFromRect(w.frame), forKey: "jotFrame")
    }
    func windowDidResize(_ n: Notification) {
        guard let w = n.object as? NSWindow, w === dropdown else { return }
        applySidebarVisibility()
        guard !suppressMoveSave else { return }
        if !Runtime.isPreview { rememberPadSize() }                 // size is remembered always…
        guard Prefs.detached else { return }
        Prefs.d.set(NSStringFromRect(w.frame), forKey: "jotFrame")  // …position only once you've dragged the pad away
    }
    // Vend a single undo manager for the dropdown so the text view registers undos there
    // and the Edit-menu ⌘Z/⌘⇧Z route to the same manager.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { currentUndoManager ?? undoMgr }
    // Canonical per-text-view hook: the docked editor asks here for its undo manager, so ⌘Z acts on
    // the current note's own stack the moment we switch notes (no window-cache staleness).
    func undoManager(for view: NSTextView) -> UndoManager? { currentUndoManager ?? undoMgr }
    private func savedFrame() -> NSRect? {
        guard let s = Prefs.d.string(forKey: "jotFrame") else { return nil }
        let r = NSRectFromString(s); return (r.width >= 150 && r.height >= 120) ? r : nil
    }
    // Every way of closing the pad funnels here (Esc, ⌘W, the hotkey, click-away use the same housekeeping).
    func hideTray() { minimizeToMenuBar() }
    // Esc, in order: the find bar (the editor deals with that) → an open sidebar drawer → the pad itself.
    func escape() { if sidebarShown && !sidebarDocks { hideSidebar() } else { hideTray() } }
    @objc func cancelOperation(_ sender: Any?) { escape() }      // Esc from the notes list: the window's delegate is on the responder chain
    // Opening another Jot window (a note, Settings) puts the pad away — unless you pinned it on top.
    func hideTrayUnlessPinned() { if dropdown.isVisible && !isPinned { minimizeToMenuBar() } }
    @objc func closeFocusedWindow() {           // ⌘W: close the key window, or put the pad away
        if let key = NSApp.keyWindow, key !== dropdown { key.performClose(nil) } else { hideTray() }
    }
    @objc func previousNote() { selectPrevNote() }
    @objc func nextNote() { selectNextNote() }
    // The main-menu ⌘⌫ "Delete Note" is for the notes list; it must never fire while a text field (the find
    // bar's, a Settings field) has focus. ⇧⌘⌫ and the ⋯ menu's Delete always work.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(deleteCurrentNote), item.keyEquivalent == "\u{8}", item.keyEquivalentModifierMask == [.command] {
            return !(NSApp.keyWindow?.firstResponder is NSText)
        }
        if let handled = validateFormatItem(item) { return handled }
        return true
    }
    @objc func minimizeToMenuBar() {            // "close to tray" — reset to the menu-bar anchor on next open
        guard saveCurrent() else { return }
        lastActivity = Date()
        resetToTrayAnchor()
        hidePad()
    }
    @objc func togglePin(_ sender: Any?) {
        isPinned.toggle()
        applyDropdownLevel()
        updateHeaderBadges()
    }

    // MARK: settings / menu / hotkey / login
    @objc func openSettings() { hideTrayUnlessPinned(); if settingsController == nil { settingsController = SettingsController(app: self) }; settingsController?.show() }
    @objc func changeHotkey() { openSettings(); settingsController?.recorder.begin() }

    func showMenu() {
        let menu = NSMenu()
        let deleted = NSMenuItem(title: viewingTrash ? "Back to Notes" : "Recently Deleted…", action: #selector(showRecentlyDeleted), keyEquivalent: "")
        deleted.target = self; menu.addItem(deleted)
        menu.addItem(.separator())
        let s = NSMenuItem(title: "Preferences…", action: #selector(openSettings), keyEquivalent: ","); s.target = self; menu.addItem(s)
        let hk = NSMenuItem(title: "Change Hotkey…  (\(Prefs.hotkeyDisplay))", action: #selector(changeHotkey), keyEquivalent: ""); hk.target = self; menu.addItem(hk)
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: ""); login.target = self
        login.state = loginItemEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Jot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
    }
    func setupMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        let newItem = NSMenuItem(title: "New Note", action: #selector(newNote), keyEquivalent: "n"); newItem.target = self
        let capItem = NSMenuItem(title: "Paste Clipboard", action: #selector(captureClipboard), keyEquivalent: "v")
        capItem.keyEquivalentModifierMask = [.command, .shift]; capItem.target = self
        let delItem = NSMenuItem(title: "Delete Note", action: #selector(deleteCurrentNote), keyEquivalent: "\u{8}"); delItem.target = self
        let delAnywhere = NSMenuItem(title: "Delete Note", action: #selector(deleteCurrentNote), keyEquivalent: "\u{8}")
        delAnywhere.keyEquivalentModifierMask = [.command, .shift]; delAnywhere.target = self   // ⇧⌘⌫: works while typing
        let closeItem = NSMenuItem(title: "Close", action: #selector(closeFocusedWindow), keyEquivalent: "w"); closeItem.target = self
        appMenu.addItem(newItem); appMenu.addItem(capItem); appMenu.addItem(delItem); appMenu.addItem(delAnywhere)
        appMenu.addItem(closeItem)
        appMenu.addItem(.separator())
        let s = NSMenuItem(title: "Preferences…", action: #selector(openSettings), keyEquivalent: ","); s.target = self
        appMenu.addItem(s); appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Jot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        // Edit menu so ⌘C/⌘V/⌘X/⌘Z/⌘A + Find work in the editor.
        let editItem = NSMenuItem(); mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(.separator())
        let find = NSMenuItem(title: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = 1   // NSFindPanelAction.showFindPanel → shows the find bar (usesFindBar = true)
        editMenu.addItem(find)
        editItem.submenu = editMenu
        // Format menu — the same items the formatting bar uses (FormattingBar.swift ▸ FormatMenu); this menu is never
        // shown (Jot has no Dock icon) but it is what routes ⌘B, ⇧⌘T … to the focused editor.
        let fmtItem = NSMenuItem(); mainMenu.addItem(fmtItem)
        fmtItem.submenu = FormatMenu.mainMenu(target: self)
        // View menu — ⌘+ / ⌘= / ⌘- change the overall text size.
        let viewItem = NSMenuItem(); mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let bigger = NSMenuItem(title: "Bigger Text", action: #selector(fontBigger), keyEquivalent: "+"); bigger.target = self
        let bigger2 = NSMenuItem(title: "Bigger Text", action: #selector(fontBigger), keyEquivalent: "="); bigger2.target = self; bigger2.isAlternate = false
        let smaller = NSMenuItem(title: "Smaller Text", action: #selector(fontSmaller), keyEquivalent: "-"); smaller.target = self
        let actual = NSMenuItem(title: "Actual Size", action: #selector(fontActualSize), keyEquivalent: "0"); actual.target = self
        viewMenu.addItem(bigger); viewMenu.addItem(bigger2); viewMenu.addItem(smaller); viewMenu.addItem(actual)
        viewMenu.addItem(.separator())
        let sidebarItem = NSMenuItem(title: "Show/Hide Sidebar", action: #selector(toggleSidebar), keyEquivalent: "s")
        sidebarItem.keyEquivalentModifierMask = [.control, .command]; sidebarItem.target = self
        let prevItem = NSMenuItem(title: "Previous Note", action: #selector(previousNote), keyEquivalent: String(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!))
        prevItem.keyEquivalentModifierMask = [.option, .command]; prevItem.target = self
        let nextItem = NSMenuItem(title: "Next Note", action: #selector(nextNote), keyEquivalent: String(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!))
        nextItem.keyEquivalentModifierMask = [.option, .command]; nextItem.target = self
        let rawItem = NSMenuItem(title: "Show Markdown Syntax", action: #selector(toggleDisplayMode), keyEquivalent: "/"); rawItem.target = self
        let barItem = NSMenuItem(title: "Show/Hide Formatting Bar", action: #selector(toggleTools), keyEquivalent: "t")
        barItem.keyEquivalentModifierMask = [.option, .command]; barItem.target = self
        let searchItem = NSMenuItem(title: "Search Notes", action: #selector(focusSearch), keyEquivalent: "f")
        searchItem.keyEquivalentModifierMask = [.option, .command]; searchItem.target = self
        viewMenu.addItem(sidebarItem); viewMenu.addItem(searchItem); viewMenu.addItem(barItem); viewMenu.addItem(prevItem); viewMenu.addItem(nextItem); viewMenu.addItem(rawItem)
        viewItem.submenu = viewMenu
        NSApp.mainMenu = mainMenu
    }
    func installHotkeyHandler() {
        var et = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, _, _) -> OSStatus in
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.toggleTray(fromHotkey: true) }
            return noErr
        }, 1, &et, nil, nil)
    }
    // Registers the new shortcut BEFORE releasing the old one, so a refused key can't leave you with no
    // shortcut at all. Carbon reports a conflict only with this process or an exclusive holder — a
    // system shortcut or another app's non-exclusive hotkey can't be detected.
    @discardableResult
    func applyHotkey(keyCode: UInt32, carbonModifiers: UInt32) -> Bool {
        if let current = registeredHotkey, current.keyCode == keyCode, current.modifiers == carbonModifiers { return true }
        var newRef: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4A4F5421) /* 'JOT!' */, id: 1)
        let status = RegisterEventHotKey(keyCode, carbonModifiers, id, GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr, let ref = newRef else { return false }
        if let old = hotKeyRef { UnregisterEventHotKey(old) }
        hotKeyRef = ref
        registeredHotkey = (keyCode, carbonModifiers)
        return true
    }
    func hotkeyUnavailable(_ display: String) {
        let alert = NSAlert()
        alert.messageText = "Jot couldn't use \(display)"
        alert.informativeText = "Another app or macOS is using that shortcut. Choose a different one in Settings."
        alert.runModal()
    }
}

// MARK: - Entry point
let app = NSApplication.shared
Runtime.prepareIfPreview()   // before AppDelegate() so the store/defaults it builds are the preview's
let delegate = AppDelegate()
app.delegate = delegate
app.run()
