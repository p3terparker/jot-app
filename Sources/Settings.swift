import Cocoa
import Carbon
import ServiceManagement

// ============================================================================
// Settings — one compact window, in the order people look for things:
//   Shortcut · Startup · Editor · Share menu · Notes folder · About.
// Every control reflects the real state (the login item from the system, the shortcut from what actually registered) and
// applies at once; there is no OK button to forget.
// ============================================================================

// A round colour swatch for the background presets.
final class ColorSwatch: NSButton {
    var color: NSColor = .black { didSet { needsDisplay = true } }
    var isChosen = false { didSet { needsDisplay = true } }
    init(name: String, hex: String, target: AnyObject, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        self.target = target; self.action = action
        isBordered = false; title = ""
        color = colorFromHex(hex)
        identifier = NSUserInterfaceItemIdentifier(hex)
        toolTip = name; setAccessibilityLabel("\(name) background")
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 4, dy: 4)
        color.setFill(); NSBezierPath(ovalIn: r).fill()
        NSColor.labelColor.withAlphaComponent(0.25).setStroke()
        let edge = NSBezierPath(ovalIn: r); edge.lineWidth = 1; edge.stroke()
        if isChosen {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5)); ring.lineWidth = 2; ring.stroke()
        }
    }
}

final class SettingsController {
    let window: NSWindow
    weak var app: AppDelegate?
    var recorder: HotkeyRecorderView!
    private var shortcutCaption: NSTextField!
    private var loginCheck: NSButton!
    private var loginCaption: NSTextField!
    private var loginSettingsButton: NSButton!
    private var familyPopup: NSPopUpButton!
    private var sizePopup: NSPopUpButton!
    private var modePopup: NSPopUpButton!
    private var spellCheck: NSButton!
    private var freshNote: NSButton!
    private var bgWell: NSColorWell!
    private var swatches: [ColorSwatch] = []
    private var toggleBoxes: [String: NSButton] = [:]

    static let backgroundPresets: [(name: String, hex: String)] = [("Dark", "1C1D20"), ("Black", "000000"), ("Slate", "2B2E36"), ("Paper", "F6F2E9")]
    private let shareToggles: [(id: String, title: String, bundle: String?)] = [
        ("notes", "Apple Notes", "com.apple.Notes"), ("stickies", "Stickies", "com.apple.Stickies"),
        ("save", "Save As…", nil), ("share", "Share…", nil), ("copy", "Copy as Text", nil),
    ]

    init(app: AppDelegate) {
        self.app = app
        window = JotWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Jot Settings"; window.isReleasedWhenClosed = false
        buildUI()
    }
    func show() {
        syncAll()
        if Runtime.snapshotDirectory != nil { window.setFrameOrigin(NSPoint(x: -4000, y: 100)); window.orderFrontRegardless(); return }
        window.center(); window.makeKeyAndOrderFront(nil); jotActivate()
    }

    // MARK: building
    private func caption(_ text: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: text)
        t.font = .systemFont(ofSize: 11); t.textColor = .secondaryLabelColor
        t.preferredMaxLayoutWidth = 290
        t.widthAnchor.constraint(lessThanOrEqualToConstant: 290).isActive = true
        t.setContentCompressionResistancePriority(.required, for: .vertical)
        return t
    }
    private func header(_ s: String) -> NSTextField { let t = NSTextField(labelWithString: s); t.font = .systemFont(ofSize: 13, weight: .semibold); return t }
    private func row(_ title: String, _ control: NSView) -> NSStackView {
        let l = NSTextField(labelWithString: title); l.alignment = .right
        l.widthAnchor.constraint(equalToConstant: 118).isActive = true
        let r = NSStackView(views: [l, control]); r.spacing = 10; r.alignment = .centerY; return r
    }
    private func indented(_ view: NSView) -> NSStackView { let s = NSStackView(views: [view]); s.edgeInsets = NSEdgeInsets(top: 0, left: 128, bottom: 0, right: 0); return s }
    private func rule() -> NSBox { let b = NSBox(); b.boxType = .separator; b.translatesAutoresizingMaskIntoConstraints = false; b.widthAnchor.constraint(equalToConstant: 420).isActive = true; return b }

    private func buildUI() {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
        ])

        // Shortcut
        stack.addArrangedSubview(header("Shortcut"))
        recorder = HotkeyRecorderView(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
        recorder.onCapture = { [weak self] kc, carbon, disp in
            guard let app = self?.app else { return }
            if app.applyHotkey(keyCode: kc, carbonModifiers: carbon) {
                Prefs.hotkeyKeyCode = kc; Prefs.hotkeyCarbon = carbon; Prefs.hotkeyDisplay = disp   // only a shortcut that registered is kept
            } else {
                NSSound.beep()
                self?.recorder.title = Prefs.hotkeyDisplay
                app.hotkeyUnavailable(disp)
            }
            self?.syncShortcutCaption()
        }
        stack.addArrangedSubview(row("Open or close:", recorder))
        shortcutCaption = caption("")
        stack.addArrangedSubview(indented(shortcutCaption))
        stack.addArrangedSubview(rule())

        // Startup
        stack.addArrangedSubview(header("Startup"))
        loginCheck = NSButton(checkboxWithTitle: "Open Jot at login", target: self, action: #selector(loginChanged))
        loginCheck.setAccessibilityLabel("Open Jot at login")
        stack.addArrangedSubview(indented(loginCheck))
        loginCaption = caption("")
        loginSettingsButton = NSButton(title: "Open Login Items…", target: self, action: #selector(openLoginItems))
        loginSettingsButton.bezelStyle = .rounded; loginSettingsButton.controlSize = .small
        let loginStack = NSStackView(views: [loginCaption, loginSettingsButton]); loginStack.orientation = .vertical; loginStack.alignment = .leading; loginStack.spacing = 4
        stack.addArrangedSubview(indented(loginStack))
        stack.addArrangedSubview(rule())

        // Editor
        stack.addArrangedSubview(header("Editor"))
        familyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        familyPopup.addItems(withTitles: FontChoices.families.map { $0.title })
        familyPopup.target = self; familyPopup.action = #selector(familyChanged); familyPopup.setAccessibilityLabel("Font")
        sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        sizePopup.addItems(withTitles: FontChoices.sizes.map { "\($0)" })
        sizePopup.target = self; sizePopup.action = #selector(sizeChanged); sizePopup.setAccessibilityLabel("Font size")
        let fontRow = NSStackView(views: [familyPopup, sizePopup]); fontRow.spacing = 8
        stack.addArrangedSubview(row("Font:", fontRow))
        let swatchRow = NSStackView(); swatchRow.spacing = 4; swatchRow.alignment = .centerY
        for preset in SettingsController.backgroundPresets {
            let s = ColorSwatch(name: preset.name, hex: preset.hex, target: self, action: #selector(swatchChosen(_:)))
            swatches.append(s); swatchRow.addArrangedSubview(s)
        }
        bgWell = NSColorWell(); bgWell.target = self; bgWell.action = #selector(bgChanged)
        bgWell.widthAnchor.constraint(equalToConstant: 40).isActive = true; bgWell.heightAnchor.constraint(equalToConstant: 22).isActive = true
        bgWell.setAccessibilityLabel("Custom background colour")
        swatchRow.addArrangedSubview(bgWell)
        stack.addArrangedSubview(row("Background:", swatchRow))
        modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        modePopup.addItems(withTitles: ["Formatted", "Markdown source"])
        modePopup.target = self; modePopup.action = #selector(modeChanged); modePopup.setAccessibilityLabel("Show notes as")
        stack.addArrangedSubview(row("Show notes as:", modePopup))
        spellCheck = NSButton(checkboxWithTitle: "Check spelling while typing", target: self, action: #selector(spellChanged))
        stack.addArrangedSubview(indented(spellCheck))
        freshNote = NSButton(checkboxWithTitle: "Start each session on a new note", target: self, action: #selector(freshChanged))
        freshNote.toolTip = "Jot opens on a blank note when it launches and after 30 idle minutes; your other notes are one click away."
        stack.addArrangedSubview(indented(freshNote))
        stack.addArrangedSubview(rule())

        // Share menu
        stack.addArrangedSubview(header("Share menu"))
        let left = NSStackView(), right = NSStackView()
        for column in [left, right] { column.orientation = .vertical; column.alignment = .leading; column.spacing = 4 }
        for (i, t) in shareToggles.enumerated() {
            var title = t.title
            if let bundle = t.bundle, NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) == nil { title += " (not installed)" }
            let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(toggleChanged(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(t.id); toggleBoxes[t.id] = b
            (i % 2 == 0 ? left : right).addArrangedSubview(b)
        }
        let grid = NSStackView(views: [left, right]); grid.spacing = 18; grid.alignment = .top
        stack.addArrangedSubview(row("Show:", grid))
        stack.addArrangedSubview(indented(caption("Apple Notes and Stickies ask macOS for permission the first time.")))
        stack.addArrangedSubview(rule())

        // Notes folder
        stack.addArrangedSubview(header("Notes"))
        let path = NSTextField(labelWithString: (app?.store.dir.path ?? "") .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        path.lineBreakMode = .byTruncatingMiddle; path.font = .systemFont(ofSize: 12); path.textColor = .secondaryLabelColor
        path.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        path.widthAnchor.constraint(lessThanOrEqualToConstant: 250).isActive = true
        let reveal = NSButton(title: "Show in Finder", target: self, action: #selector(showNotes)); reveal.bezelStyle = .rounded; reveal.controlSize = .small
        let folderRow = NSStackView(views: [path, reveal]); folderRow.spacing = 8; folderRow.alignment = .centerY
        stack.addArrangedSubview(row("Folder:", folderRow))
        stack.addArrangedSubview(rule())

        // About
        let info = Bundle.main.infoDictionary
        let version = "Jot \(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))"
        let versionLabel = NSTextField(labelWithString: version); versionLabel.font = .systemFont(ofSize: 12); versionLabel.textColor = .secondaryLabelColor
        let about = NSButton(title: "About Jot", target: self, action: #selector(showAboutPanel)); about.bezelStyle = .rounded; about.controlSize = .small
        let aboutRow = NSStackView(views: [versionLabel, about]); aboutRow.spacing = 10; aboutRow.alignment = .centerY
        stack.addArrangedSubview(aboutRow)

        syncAll()
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 460, height: stack.fittingSize.height + 36))
    }

    // MARK: state → controls
    func syncAll() {
        syncShortcutCaption(); syncLogin(); syncEditorControls()
        for (id, box) in toggleBoxes { box.state = Prefs.show(id) ? .on : .off }
    }
    func syncShortcutCaption() {
        let control = (Prefs.hotkeyCarbon & UInt32(controlKey)) != 0, others = (Prefs.hotkeyCarbon & UInt32(cmdKey | optionKey)) != 0
        shortcutCaption?.stringValue = control && !others
            ? "Control-letter shortcuts clash with Terminal and many text fields; ⌥⌘J is safer. If it doesn't respond, another app may be using it."
            : "If it doesn't respond, another app may be using it — choose a different one."
        recorder?.title = Prefs.hotkeyDisplay
    }
    func syncLogin() {
        loginCheck?.state = (app?.loginItemEnabled ?? false) ? .on : .off
        let needsApproval = app?.loginItemNeedsApproval ?? false
        loginCaption?.stringValue = "macOS is waiting for your approval: turn Jot on under System Settings ▸ General ▸ Login Items."
        loginCaption?.isHidden = !needsApproval
        loginSettingsButton?.isHidden = !needsApproval
    }
    // Font and size can also change from View ▸ Bigger / Smaller / Actual Size while this window is open.
    func refreshEditorControls() { syncEditorControls() }
    private func syncEditorControls() {
        familyPopup?.selectItem(at: FontChoices.families.firstIndex { $0.value == Prefs.fontFamily } ?? 0)
        sizePopup?.selectItem(withTitle: "\(Int(Prefs.fontSize))")
        modePopup?.selectItem(at: Prefs.rawMode ? 1 : 0)
        spellCheck?.state = Prefs.spellcheck ? .on : .off
        freshNote?.state = Prefs.startOnNewNote ? .on : .off
        let hex = Prefs.editorBGHex.uppercased()
        for s in swatches { s.isChosen = s.identifier?.rawValue.uppercased() == hex }
        bgWell?.color = colorFromHex(Prefs.editorBGHex)
    }

    // MARK: what the walkthrough drives and reads
    var chosenBackgroundName: String? { swatches.first { $0.isChosen }.flatMap { c in SettingsController.backgroundPresets.first { $0.hex.uppercased() == c.identifier?.rawValue.uppercased() }?.name } }
    func choose(background name: String) { if let p = SettingsController.backgroundPresets.first(where: { $0.name == name }) { chooseBackground(hex: p.hex) } }
    func set(rawMode: Bool) { modePopup.selectItem(at: rawMode ? 1 : 0); modeChanged() }
    func set(spellCheck on: Bool) { spellCheck.state = on ? .on : .off; spellChanged() }
    func set(loginItem on: Bool) { loginCheck.state = on ? .on : .off; loginChanged() }

    // MARK: actions
    @objc private func loginChanged() { app?.setLoginItem(loginCheck.state == .on); syncLogin() }
    @objc private func openLoginItems() { if #available(macOS 13.0, *), !Runtime.isPreview { SMAppService.openSystemSettingsLoginItems() } }
    @objc private func familyChanged() { app?.setFontFamily(FontChoices.families[max(0, familyPopup.indexOfSelectedItem)].value) }
    @objc private func sizeChanged() { app?.setFontSize(Int(sizePopup.titleOfSelectedItem ?? "") ?? FontChoices.defaultSize) }
    @objc private func swatchChosen(_ sender: ColorSwatch) { chooseBackground(hex: sender.identifier?.rawValue ?? "1C1D20") }
    @objc private func bgChanged() { chooseBackground(hex: hexFromColor(bgWell.color)) }
    func chooseBackground(hex: String) { Prefs.editorBGHex = hex; app?.applyEditorBGEverywhere(); syncEditorControls() }
    @objc private func modeChanged() { app?.setDisplayMode(raw: modePopup.indexOfSelectedItem == 1) }
    @objc private func freshChanged() { Prefs.startOnNewNote = freshNote.state == .on }
    func set(startOnNewNote on: Bool) { freshNote.state = on ? .on : .off; freshChanged() }
    @objc private func spellChanged() { Prefs.spellcheck = spellCheck.state == .on; app?.applySpellcheck() }
    @objc private func toggleChanged(_ sender: NSButton) { if let id = sender.identifier?.rawValue { Prefs.setShow(id, sender.state == .on) } }
    @objc private func showNotes() { app?.showNotesInFinder() }
    @objc private func showAboutPanel() { app?.showAbout() }
}
