import Cocoa

// ============================================================================
// FormattingBar — the row of formatting buttons under (or over) the text. Every button TOGGLES (a second
// press undoes the first), lights up while the caret is inside that formatting, and the whole bar fits the
// smallest pad (360 pt) without scrolling:
//
//   [Style ▾]  B  I  •  ☑  1.  🔗  ⋯                                   </>
//
// Style = Title / Heading / Subheading / Body; ⋯ = strikethrough, code, quote, code block, divider, table, indent.
// The buttons only send actions; AppDelegate applies them to whichever editor is focused through MarkdownEdit.
// The same menu items back the main menu's Format menu, so labels and shortcuts are defined once (FormatMenu).
// ============================================================================

// A quiet icon (or text) button with hover, pressed and "on" feedback.
class FormatButton: NSButton {
    var isActive = false { didSet { if isActive != oldValue { updateLook() } } }
    private var isHovering = false { didSet { if isHovering != oldValue { updateLook() } } }
    private var tracking: NSTrackingArea?

    init(symbol: String?, title: String = "", label: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target; self.action = action
        self.title = title
        if let symbol = symbol { image = sym(symbol); imagePosition = title.isEmpty ? .imageOnly : .imageLeading }
        isBordered = false
        bezelStyle = .regularSquare
        imageScaling = .scaleProportionallyDown
        focusRingType = .none
        refusesFirstResponder = true           // clicking a format button must not take the caret away from the text
        toolTip = label
        setAccessibilityLabel(label)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        updateLook()
    }
    required init?(coder: NSCoder) { fatalError() }

    // A button that is just text (the Style button) sets its own width.
    func setFixedWidth(_ width: CGFloat) {
        for c in constraints where c.firstAttribute == .width { c.isActive = false }
        widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { isHovering = true }
    func setHoverForPreview(_ on: Bool) { isHovering = on }   // the walkthrough draws a button hovered
    override func mouseExited(with event: NSEvent) { isHovering = false }

    private func updateLook() {
        contentTintColor = isActive ? .controlAccentColor : (isHovering ? .labelColor : .secondaryLabelColor)
        needsDisplay = true
    }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        var fill: NSColor?
        if isHighlighted { fill = NSColor.labelColor.withAlphaComponent(0.16) }
        else if isActive { fill = NSColor.controlAccentColor.withAlphaComponent(0.20) }
        else if isHovering { fill = NSColor.labelColor.withAlphaComponent(0.08) }
        if let fill = fill {
            fill.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}

// A button that opens a menu instead of acting (Style, ⋯).
final class FormatMenuButton: FormatButton {
    var menuBuilder: (() -> NSMenu)?
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let menu = menuBuilder?() else { return }
        isHighlighted = true
        // Above the button when it sits in the lower half of its window (the bar is at the bottom), below otherwise.
        let inLowerHalf = (window.map { convert(bounds, to: nil).midY < $0.frame.height / 2 }) ?? false
        let at = NSPoint(x: 0, y: inLowerHalf ? bounds.maxY + menu.size.height + 2 : -2)
        menu.popUp(positioning: nil, at: at, in: self)
        isHighlighted = false
    }
    override func accessibilityPerformPress() -> Bool { mouseDown(with: NSEvent()); return true }
}

// ----------------------------------------------------------------------------------------------------------------
// The menu items, defined once: the main menu's Format menu and the bar's pop-ups both come from here.
// ----------------------------------------------------------------------------------------------------------------
enum FormatMenu {
    static let styleTitles = ["Title", "Heading", "Subheading", "Body"]

    private static func item(_ title: String, _ action: Selector, key: String = "", _ mods: NSEvent.ModifierFlags = [.command], target: AnyObject?) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        i.target = target
        return i
    }

    static func styleItems(target: AnyObject?) -> [NSMenuItem] {
        [item("Title", #selector(AppDelegate.tTitle), key: "t", [.command, .shift], target: target),
         item("Heading", #selector(AppDelegate.tHeading), key: "h", [.command, .shift], target: target),
         item("Subheading", #selector(AppDelegate.tSubheading), key: "j", [.command, .shift], target: target),
         item("Body", #selector(AppDelegate.tBody), key: "b", [.command, .shift], target: target)]
    }
    static func inlineItems(target: AnyObject?) -> [NSMenuItem] {
        [item("Bold", #selector(AppDelegate.tBold), key: "b", target: target),
         item("Italic", #selector(AppDelegate.tItalic), key: "i", target: target),
         item("Strikethrough", #selector(AppDelegate.tStrike), key: "x", [.command, .shift], target: target),
         item("Code", #selector(AppDelegate.tCode), key: "m", [.command, .shift], target: target)]
    }
    static func blockItems(target: AnyObject?) -> [NSMenuItem] {
        [item("Bulleted List", #selector(AppDelegate.tBullet), key: "7", [.command, .shift], target: target),
         item("Numbered List", #selector(AppDelegate.tNumbered), key: "9", [.command, .shift], target: target),
         item("Checklist", #selector(AppDelegate.tCheckbox), key: "l", [.command, .shift], target: target),
         item("Block Quote", #selector(AppDelegate.tQuote), key: "'", target: target)]
    }
    static func insertItems(target: AnyObject?) -> [NSMenuItem] {
        [item("Link", #selector(AppDelegate.tLink), key: "k", target: target),
         item("Code Block", #selector(AppDelegate.tCodeBlock), target: target),
         item("Divider", #selector(AppDelegate.tDivider), target: target),
         item("Table", #selector(AppDelegate.tTable), target: target)]
    }
    static func indentItems(target: AnyObject?) -> [NSMenuItem] {
        [item("Increase Indent", #selector(AppDelegate.tIndent), key: "]", target: target),
         item("Decrease Indent", #selector(AppDelegate.tOutdent), key: "[", target: target)]
    }

    // The main menu's Format menu: everything.
    static func mainMenu(target: AnyObject?) -> NSMenu {
        let menu = NSMenu(title: "Format")
        let groups = [styleItems(target: target), inlineItems(target: target), blockItems(target: target), insertItems(target: target), indentItems(target: target)]
        for (n, group) in groups.enumerated() {
            if n > 0 { menu.addItem(.separator()) }
            group.forEach(menu.addItem)
        }
        return menu
    }

    // The Style pop-up: just the four styles, the current one ticked.
    static func stylePopup(target: AnyObject?, current: String) -> NSMenu {
        let menu = NSMenu(title: "Style")
        for i in styleItems(target: target) { i.state = i.title == current ? .on : .off; menu.addItem(i) }
        return menu
    }

    // The ⋯ pop-up: what doesn't fit on the bar, with its state ticked.
    static func morePopup(target: AnyObject?, state: FormatState) -> NSMenu {
        let menu = NSMenu(title: "More")
        func tick(_ i: NSMenuItem, _ on: Bool) -> NSMenuItem { i.state = on ? .on : .off; return i }
        let inline = inlineItems(target: target)
        menu.addItem(tick(inline[2], state.strike))
        menu.addItem(tick(inline[3], state.code))
        menu.addItem(.separator())
        let block = blockItems(target: target)
        menu.addItem(tick(block[3], state.quote))
        let insert = insertItems(target: target)
        menu.addItem(tick(insert[1], state.codeBlock))
        menu.addItem(insert[2]); menu.addItem(insert[3])
        menu.addItem(.separator())
        indentItems(target: target).forEach(menu.addItem)
        return menu
    }

    // The Style button's label for a line.
    static func styleName(_ block: BlockStyle?) -> String {
        if case .heading(let level)? = block {
            switch level { case 1: return "Title"; case 2: return "Heading"; case 3: return "Subheading"; default: return "Heading \(level)" }
        }
        return "Body"
    }
}

// ----------------------------------------------------------------------------------------------------------------
final class FormattingBar: NSView {
    private(set) var state = FormatState()
    private let style: FormatMenuButton
    private let bold, italic, bullet, task, numbered, link: FormatButton
    private let more: FormatMenuButton
    private let raw: FormatButton
    private weak var actionTarget: AnyObject?

    init(target: AnyObject, width: CGFloat) {
        actionTarget = target
        style = FormatMenuButton(symbol: nil, title: "Body ▾", label: "Text style", target: nil, action: nil)
        style.font = .systemFont(ofSize: 12, weight: .medium)
        style.alignment = .left
        style.setFixedWidth(88)
        bold = FormatButton(symbol: "bold", label: "Bold", target: target, action: #selector(AppDelegate.tBold))
        italic = FormatButton(symbol: "italic", label: "Italic", target: target, action: #selector(AppDelegate.tItalic))
        bullet = FormatButton(symbol: "list.bullet", label: "Bulleted list", target: target, action: #selector(AppDelegate.tBullet))
        task = FormatButton(symbol: "checkmark.square", label: "Checklist", target: target, action: #selector(AppDelegate.tCheckbox))
        numbered = FormatButton(symbol: "list.number", label: "Numbered list", target: target, action: #selector(AppDelegate.tNumbered))
        link = FormatButton(symbol: "link", label: "Link", target: target, action: #selector(AppDelegate.tLink))
        more = FormatMenuButton(symbol: "ellipsis", label: "More formatting", target: nil, action: nil)
        raw = FormatButton(symbol: "doc.plaintext", label: "Show Markdown syntax", target: target, action: #selector(AppDelegate.toggleDisplayMode))
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: JotUI.toolsHeight))
        autoresizingMask = [.width, .maxYMargin]

        style.menuBuilder = { [weak self] in
            FormatMenu.stylePopup(target: self?.actionTarget, current: FormatMenu.styleName(self?.state.block))
        }
        more.menuBuilder = { [weak self] in FormatMenu.morePopup(target: self?.actionTarget, state: self?.state ?? FormatState()) }
        style.setAccessibilityRole(.popUpButton)
        more.setAccessibilityRole(.popUpButton)
        for b in [bold, italic, bullet, task, numbered] { b.setButtonType(.pushOnPushOff) }
        raw.setButtonType(.pushOnPushOff)

        let divider = NSBox(frame: NSRect(x: 0, y: JotUI.toolsHeight - 1, width: width, height: 1))
        divider.boxType = .separator; divider.autoresizingMask = [.width, .minYMargin]
        addSubview(divider)

        let spacer = NSView(); spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [style, bold, italic, bullet, task, numbered, link, more, spacer, raw])
        stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 1, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityLabel("Formatting")
        setAccessibilityRole(.toolbar)
        update(FormatState(), raw: Prefs.rawMode)
    }
    required init?(coder: NSCoder) { fatalError() }

    // The width the controls need (the lint in the walkthrough compares it with the smallest pad).
    var requiredWidth: CGFloat { subviews.compactMap { $0 as? NSStackView }.first?.fittingSize.width ?? 0 }
    // For the walkthrough: which buttons are lit, what the Style button says, and whether any control spills out of the bar.
    private var controls: [FormatButton] { [style, bold, italic, bullet, task, numbered, link, more, raw] }
    var activeLabels: [String] { controls.filter { $0.isActive }.map { $0.accessibilityLabel() ?? "" } }
    var styleLabel: String { style.title }
    func previewHover(_ label: String?) { for b in controls { b.setHoverForPreview(b.accessibilityLabel() == label) } }
    // The widest Style title (with its arrow) against the room the button gives it.
    var widestStyleTitle: CGFloat { (FormatMenu.styleTitles + ["Heading 4"]).map { ($0 + " ▾" as NSString).size(withAttributes: [.font: style.font ?? .systemFont(ofSize: 12)]).width }.max() ?? 0 }
    var styleButtonWidth: CGFloat { style.constraints.first { $0.firstAttribute == .width }?.constant ?? 0 }
    var spillsOut: Bool {
        layoutSubtreeIfNeeded()
        return controls.contains { b in b.superview.map { convert(b.frame, from: $0).maxX > bounds.width + 0.5 || convert(b.frame, from: $0).minX < -0.5 } ?? false }
    }

    func update(_ new: FormatState, raw isRaw: Bool) {
        state = new
        let name = FormatMenu.styleName(new.block)
        style.title = name + " ▾"
        style.setAccessibilityValue(name)
        func set(_ b: FormatButton, _ on: Bool) { b.isActive = on; b.state = on ? .on : .off }
        set(bold, new.strong); set(italic, new.emphasis)
        set(bullet, new.block == .bullet); set(task, new.block == .task); set(numbered, new.block == .ordered)
        set(link, new.link)
        more.isActive = new.strike || new.code || new.quote || new.codeBlock
        set(raw, isRaw)
    }
}

// ----------------------------------------------------------------------------------------------------------------
// Font choices (Settings and View ▸ Bigger / Smaller / Actual Size; the bar no longer carries them).
// ----------------------------------------------------------------------------------------------------------------
enum FontChoices {
    static let families: [(title: String, value: String)] = [
        ("System Mono", ""), ("System", "System"), ("Helvetica Neue", "Helvetica Neue"), ("Georgia", "Georgia"),
        ("Menlo", "Menlo"), ("Courier New", "Courier New"), ("Times New Roman", "Times New Roman"),
    ]
    static let sizes = [10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 32, 36, 48]
    static let defaultSize = 13
}

// ----------------------------------------------------------------------------------------------------------------
// Applying a MarkdownEdit: one replace (so ⌘Z undoes the whole formatting step), then the selection the edit asks for.
// ----------------------------------------------------------------------------------------------------------------
extension JotTextView {
    @discardableResult
    func apply(_ edit: TextEdit?) -> Bool {
        guard let edit = edit, isEditable, shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return false }
        replaceCharacters(in: edit.range, with: edit.replacement)
        setSelectedRange(edit.selection)
        didChangeText()
        scrollRangeToVisible(edit.selection)
        return true
    }
}

// ----------------------------------------------------------------------------------------------------------------
// The actions: the bar's buttons, the Format menu and every shortcut all land here and act on the focused editor.
// ----------------------------------------------------------------------------------------------------------------
extension AppDelegate {
    private static let formatActions: [Selector] = [
        #selector(AppDelegate.tTitle), #selector(AppDelegate.tHeading), #selector(AppDelegate.tSubheading), #selector(AppDelegate.tBody),
        #selector(AppDelegate.tBold), #selector(AppDelegate.tItalic), #selector(AppDelegate.tStrike), #selector(AppDelegate.tCode),
        #selector(AppDelegate.tBullet), #selector(AppDelegate.tNumbered), #selector(AppDelegate.tCheckbox), #selector(AppDelegate.tQuote),
        #selector(AppDelegate.tLink), #selector(AppDelegate.tCodeBlock), #selector(AppDelegate.tDivider), #selector(AppDelegate.tTable),
        #selector(AppDelegate.tIndent), #selector(AppDelegate.tOutdent),
    ]

    // The editor a format command acts on: the focused one (pad or note window), else the docked pad — if it can be edited.
    var formatTarget: JotTextView? {
        let tv = activeEditor
        return tv.isEditable ? tv : nil
    }
    // Format menu items work only while an editable editor is the target (they're never shown, but they route shortcuts).
    func validateFormatItem(_ item: NSMenuItem) -> Bool? {
        guard let action = item.action, AppDelegate.formatActions.contains(action) else { return nil }
        guard let tv = formatTarget else { return false }
        return NSApp.keyWindow == nil || NSApp.keyWindow === tv.window
    }

    private func format(_ make: (String, NSRange) -> TextEdit?) {
        guard let tv = formatTarget else { return }
        tv.apply(make(tv.string, tv.selectedRange()))
        refreshFormattingBar(for: tv)
    }
    // The line a block insertion (divider, table) goes below: the last line of the selection.
    private func insertionCaret(_ r: NSRange) -> Int { r.length > 0 ? NSMaxRange(r) - 1 : r.location }

    @objc func tBold() { format { MarkdownEdit.toggleInline(.strong, in: $0, selection: $1) } }
    @objc func tItalic() { format { MarkdownEdit.toggleInline(.emphasis, in: $0, selection: $1) } }
    @objc func tStrike() { format { MarkdownEdit.toggleInline(.strike, in: $0, selection: $1) } }
    @objc func tCode() { format { MarkdownEdit.toggleInline(.code, in: $0, selection: $1) } }
    @objc func tTitle() { format { MarkdownEdit.setBlock(.heading(1), in: $0, selection: $1) } }
    @objc func tHeading() { format { MarkdownEdit.setBlock(.heading(2), in: $0, selection: $1) } }
    @objc func tSubheading() { format { MarkdownEdit.setBlock(.heading(3), in: $0, selection: $1) } }
    @objc func tBody() { format { MarkdownEdit.setBlock(.body, in: $0, selection: $1) } }
    @objc func tBullet() { format { MarkdownEdit.setBlock(.bullet, in: $0, selection: $1) } }
    @objc func tNumbered() { format { MarkdownEdit.setBlock(.ordered, in: $0, selection: $1) } }
    @objc func tCheckbox() { format { MarkdownEdit.setBlock(.task, in: $0, selection: $1) } }
    @objc func tQuote() { format { MarkdownEdit.setBlock(.quote, in: $0, selection: $1) } }
    @objc func tIndent() { format { MarkdownEdit.indent(outdent: false, in: $0, selection: $1) } }
    @objc func tOutdent() { format { MarkdownEdit.indent(outdent: true, in: $0, selection: $1) } }
    @objc func tCodeBlock() { format { MarkdownEdit.toggleCodeBlock(in: $0, selection: $1) } }
    @objc func tDivider() { format { MarkdownEdit.insertDivider(in: $0, caret: self.insertionCaret($1)) } }
    @objc func tTable() { format { MarkdownEdit.insertTable(in: $0, caret: self.insertionCaret($1)) } }
    // Link: a URL on the clipboard becomes the destination of the selected text.
    @objc func tLink() {
        let destination = (formatTarget?.selectedRange().length ?? 0) > 0 ? JotTextView.clipboardURL() : nil
        format { MarkdownEdit.toggleLink(in: $0, selection: $1, url: destination) }
    }

    // MARK: keeping the bar in step with the caret
    func formattingBar(for tv: JotTextView) -> FormattingBar? {
        if tv === textView { return toolsBar as? FormattingBar }
        return noteWindows.first { $0.textView === tv }?.toolsBar as? FormattingBar
    }
    func refreshFormattingBar(for tv: JotTextView) {
        guard let bar = formattingBar(for: tv), !bar.isHidden else { return }
        bar.update(MarkdownEdit.state(in: tv.string, selection: tv.selectedRange()), raw: Prefs.rawMode)
    }
    func refreshAllFormattingBars() {
        refreshFormattingBar(for: textView)
        for nc in noteWindows { refreshFormattingBar(for: nc.textView) }
    }
}
