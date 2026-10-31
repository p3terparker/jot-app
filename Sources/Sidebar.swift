import Cocoa

// ============================================================================
// Sidebar — the notes list as a DRAWER over the text on a small pad, DOCKED beside it on a wide one.
//
//   • Below 560 pt wide the list slides over the text (≤ 280 pt, never wider than the pad minus 56 pt). The text does not
//     reflow — it used to be squeezed to ~14 characters a line — the rest of the text is dimmed, a click on it (or Esc, or
//     picking a note) closes the drawer.
//   • From 560 pt up the list docks beside the text with the draggable divider; the text keeps at least 300 pt.
//   • Opening and closing slide (0.2 s); Reduce Motion (and the preview harness) switch instantly.
// All the frames come from one pure function, `SidebarGeometry.compute`, which the walkthrough checks at several sizes.
// ============================================================================

// The dimmed text beside an open drawer: a click on it closes the drawer.
final class DrawerScrim: NSView {
    var onClick: (() -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
}

// What the drawer sits on, so the text behind it doesn't show through: the system sidebar material, or a plain dark
// panel in preview snapshots (a snapshot can't render vibrancy).
final class DrawerBackdrop: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        if Runtime.snapshotDirectory != nil {
            layer?.backgroundColor = NSColor(white: 0.17, alpha: 1).cgColor
        } else {
            let effect = NSVisualEffectView(frame: bounds)
            effect.material = .sidebar; effect.blendingMode = .withinWindow; effect.state = .active
            effect.autoresizingMask = [.width, .height]
            addSubview(effect)
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}      // a click on the drawer's own background does nothing (and must not drag the window)
}

// The notes list. (A click on a folder's header folds it.) A single plain click on a row reports itself, so a drawer can close after you pick a note — but not after
// a drag-reorder, a ⌘/⇧ multi-select or an arrow-key walk through the list.
final class NoteTableView: NSTableView {
    var onUserPick: ((Int) -> Void)?
    // Esc with the list focused: close the drawer (or hide the pad). The table view doesn't pass Esc up to the app by itself.
    override func cancelOperation(_ sender: Any?) { (NSApp.delegate as? AppDelegate)?.escape() }
    override func mouseDown(with event: NSEvent) {
        // A click on a folder's header folds or unfolds it (the header is not selectable, so the table itself would do nothing).
        // Control-click is the context menu, which the table handles.
        let hit = row(at: convert(event.locationInWindow, from: nil))
        if hit >= 0, !event.modifierFlags.contains(.control), let app = NSApp.delegate as? AppDelegate, app.folderName(atRow: hit) != nil {
            if event.clickCount == 1 { app.toggleFolder(atRow: hit) }
            return
        }
        let start = event.locationInWindow
        super.mouseDown(with: event)                               // tracks the click (or the drag) to its end
        guard event.clickCount == 1, event.modifierFlags.intersection([.command, .shift, .control]).isEmpty,
              selectedRowIndexes.count == 1, selectedRow >= 0 else { return }
        if let up = NSApp.currentEvent, up.type == .leftMouseUp, hypot(up.locationInWindow.x - start.x, up.locationInWindow.y - start.y) > 4 { return }
        onUserPick?(selectedRow)
    }
}

extension AppDelegate {
    var sidebarDocks: Bool { (dropdown.contentView?.bounds.width ?? 0) >= SidebarGeometry.dockThreshold }
    var animatesSidebar: Bool { animatesPad }

    func applySidebarVisibility(animated: Bool = false) {
        guard let cv = dropdown.contentView else { return }
        let W = cv.bounds.width, H = cv.bounds.height
        let bottom = toolsShown ? toolsH : 0                      // the text reclaims the formatting bar's space when it is hidden
        let bodyH = max(0, (H - headerH) - bottom)
        let g = SidebarGeometry.compute(width: W, bodyHeight: bodyH, bottom: bottom, shown: sidebarShown, savedWidth: sidebarWidth)
        let modeChanged = g.docked != sidebarWasDocked
        sidebarWasDocked = g.docked
        let animate = animated && !modeChanged && animatesSidebar && listScroll.window != nil

        let panel: [NSView] = [drawerBackdrop, listScroll, searchField, sep]
        if sidebarShown { panel.forEach { $0.isHidden = false } }
        drawerScrim.isHidden = g.docked ? true : (!sidebarShown && !animate)
        sep.isDraggable = g.docked
        sep.layer?.backgroundColor = NSColor.white.withAlphaComponent(g.docked ? 0.07 : 0.14).cgColor
        drawerBackdrop.isHidden = g.docked || (!sidebarShown && !animate)
        let scrimAlpha: CGFloat = (g.docked || !sidebarShown) ? 0 : 1
        sidebarToggle.contentTintColor = sidebarShown ? .controlAccentColor : .secondaryLabelColor
        sidebarToggle.setAccessibilityValue(sidebarShown ? "shown" : "hidden")

        func place() {
            let proxy: (NSView) -> NSView = { animate ? $0.animator() : $0 }
            proxy(listScroll).frame = g.list
            proxy(searchField).frame = g.filter
            filterEmptyLabel.frame = NSRect(x: g.list.minX, y: g.list.midY - 10, width: g.list.width, height: 20)
            proxy(sep).frame = g.divider
            proxy(drawerBackdrop).frame = g.backdrop
            if !g.docked { drawerScrim.frame = g.scrim; proxy(drawerScrim).alphaValue = scrimAlpha }
            proxy(editorScroll).frame = g.editor
        }
        func finish() {
            if !self.sidebarShown { panel.forEach { $0.isHidden = true }; self.drawerScrim.isHidden = true }
        }
        if animate {
            animateWithFallback(duration: 0.2, { place() }, done: { finish() })
        } else {
            drawerScrim.alphaValue = scrimAlpha
            place()
            finish()
        }
    }

    @objc func toggleSidebar() {
        sidebarShown.toggle(); Prefs.sidebarShown = sidebarShown
        applySidebarVisibility(animated: true)
        // A drawer is something you reach into: the list takes the keys while it is open, the text gets them back when it closes.
        if !sidebarDocks { dropdown.makeFirstResponder(sidebarShown ? tableView : textView) }
    }
    @objc func showSidebar() { if !sidebarShown { toggleSidebar() } }
    @objc func hideSidebar() { if sidebarShown { toggleSidebar() } }

    // A plain click on a note in an open drawer: you have chosen, so the drawer closes and the text has the caret.
    func sidebarRowPicked(_ row: Int) {
        guard !viewingTrash, !sidebarDocks, sidebarShown else { return }
        hideSidebar()
        dropdown.makeFirstResponder(textView)
    }
}
