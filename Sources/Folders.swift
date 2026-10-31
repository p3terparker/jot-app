import Cocoa

// ============================================================================
// Folders — group notes in the sidebar.
//
// A folder is a name in a note's frontmatter (`folder: "Work"`); the files stay flat in one directory, so Obsidian-style tools,
// Finder and sync see exactly what they saw before, and a note can't be lost by deleting a folder. The pure rules (layout, drop
// targets, names) are in NoteLibrary.swift and tested by test.sh; this file is the AppKit side:
//
//   • rows        `sidebarItems` is what the table shows — a header per folder, then its notes. `notes` is those rows without the
//                 headers, so keyboard navigation, delete, filtering and the editor all still talk about notes.
//   • make / file ⋯ ▸ Move to Folder, right-click ▸ Move to Folder (or New Folder…), or drag a note onto a folder's header.
//                 Dragging between rows reorders inside that group and files the note there.
//   • fold        click a header; the choice is remembered (Prefs.collapsedFolders).
//   • rename / remove  right-click a header. Removing a folder only unfiles its notes (Undo puts them back).
//   • empty folders live in Prefs.folderOrder (creation order); a folder only a note names shows up too, after them.
// ============================================================================

final class FolderMove {
    let urls: [URL]
    let folder: String          // "" = take them out of any folder
    init(urls: [URL], folder: String) { self.urls = urls; self.folder = folder }
}

// A folder's header row: chevron, folder glyph, name, and how many notes it holds. Fold state is spoken as well as shown.
final class FolderHeaderCell: NSTableCellView {
    private let chevron = NSImageView()
    private let glyph = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let countField = NSTextField(labelWithString: "")
    var onToggle: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        chevron.contentTintColor = .tertiaryLabelColor
        glyph.image = sym("folder")
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        glyph.contentTintColor = .secondaryLabelColor
        nameField.font = .systemFont(ofSize: 12.5, weight: .semibold)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.maximumNumberOfLines = 1
        nameField.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        countField.font = .systemFont(ofSize: 11)
        countField.textColor = .tertiaryLabelColor
        countField.alignment = .right
        countField.setContentHuggingPriority(.required, for: .horizontal)
        countField.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [chevron, glyph, nameField, countField] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textField = nameField
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            chevron.widthAnchor.constraint(equalToConstant: 10),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 5),
            glyph.widthAnchor.constraint(equalToConstant: 16),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameField.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 6),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            countField.leadingAnchor.constraint(greaterThanOrEqualTo: nameField.trailingAnchor, constant: 8),
            countField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            countField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, count: Int, collapsed: Bool) {
        nameField.stringValue = name
        countField.stringValue = count == 0 ? "" : "\(count)"
        chevron.image = sym(collapsed ? "chevron.right" : "chevron.down")
        toolTip = name
        setAccessibilityLabel("\(name) folder, \(count == 1 ? "1 note" : "\(count) notes"), \(collapsed ? "collapsed" : "expanded")")
    }
    override func accessibilityPerformPress() -> Bool { onToggle?(); return true }
}

extension AppDelegate {
    // MARK: rows
    var collapsedFolderSet: Set<String> { Set(Prefs.collapsedFolders) }

    func noteURL(atRow row: Int) -> URL? {
        guard !viewingTrash, row >= 0, row < sidebarItems.count, case .note(let url) = sidebarItems[row] else { return nil }
        return url
    }
    func noteURLs(atRows rows: [Int]) -> [URL] { rows.compactMap { noteURL(atRow: $0) } }
    func folderName(atRow row: Int) -> String? {
        guard !viewingTrash, row >= 0, row < sidebarItems.count, case .folder(let name) = sidebarItems[row] else { return nil }
        return name
    }
    func rowIndex(of url: URL) -> Int? { sidebarItems.firstIndex(of: .note(url)) }

    func folderHeaderCell(_ t: NSTableView, name: String) -> NSView {
        let id = NSUserInterfaceItemIdentifier("folderCell")
        let cell = t.makeView(withIdentifier: id, owner: self) as? FolderHeaderCell ?? {
            let c = FolderHeaderCell(frame: .zero); c.identifier = id
            return c
        }()
        let collapsed = collapsedFolderSet.contains(name)
        cell.configure(name: name, count: layout.counts[name] ?? 0, collapsed: collapsed)
        cell.onToggle = { [weak self] in self?.setFolder(name, collapsed: !collapsed) }
        return cell
    }

    // MARK: fold
    func toggleFolder(atRow row: Int) {
        guard let name = folderName(atRow: row) else { return }
        setFolder(name, collapsed: !collapsedFolderSet.contains(name))
    }
    func setFolder(_ name: String, collapsed: Bool) {
        var shut = Prefs.collapsedFolders.filter { $0 != name }
        if collapsed { shut.append(name) }
        Prefs.collapsedFolders = shut
        refreshSidebarKeepingSelection()
    }
    @objc func toggleFolderFromMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        setFolder(name, collapsed: !collapsedFolderSet.contains(name))
    }

    // MARK: make, file, rename, remove
    private func declareFolder(_ name: String) {
        if !Prefs.folderOrder.contains(name) { Prefs.folderOrder = Prefs.folderOrder + [name] }
    }

    // A name from the user. Nothing is asked in a preview run (the walkthrough calls the functions below directly).
    func promptForFolderName(title: String, message: String, confirm: String, initial: String = "") -> String? {
        if Runtime.isPreview { PreviewLog.record("folder-prompt", title); return nil }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.placeholderString = "Folder name"
        field.setAccessibilityLabel("Folder name")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = FolderNames.clean(field.stringValue)
        return name.isEmpty ? nil : name
    }

    // Files notes into a folder ("" = takes them out of any). A new name makes the folder; a name that differs from an existing one
    // only by case or accents means that folder. The folder opens so you see them land, and the toast offers Undo.
    func moveNotes(_ urls: [URL], toFolder raw: String) {
        guard !viewingTrash, !urls.isEmpty else { return }
        var target = FolderNames.clean(raw)
        if !target.isEmpty {
            target = FolderNames.existing(target, in: layout.folders) ?? target
            declareFolder(target)
            Prefs.collapsedFolders = Prefs.collapsedFolders.filter { $0 != target }
        }
        var before: [(url: URL, folder: String, order: Int)] = []
        for url in urls {
            var meta = store.readMeta(url)
            guard meta.folder != target else { continue }
            before.append((url, meta.folder, meta.order))
            meta.folder = target
            meta.order = 0                                   // a position in the old group means nothing in the new one: it lands with the newest
            writeMetaPreservingDate(meta, to: url)
            if url == current { currentMeta = meta }
        }
        refreshSidebarKeepingSelection()
        guard !before.isEmpty else { return }
        let what = before.count == 1 ? "Note" : "\(before.count) notes"
        let message = target.isEmpty ? "\(what) moved out of its folder" : "\(what) moved to \(target)"
        flash(message, actionTitle: "Undo", duration: 6) { [weak self] in
            guard let self = self else { return }
            for old in before {
                var meta = self.store.readMeta(old.url)
                meta.folder = old.folder; meta.order = old.order
                self.writeMetaPreservingDate(meta, to: old.url)
                if old.url == self.current { self.currentMeta = meta }
            }
            self.refreshSidebarKeepingSelection()
        }
    }

    @objc func moveNotesFromMenu(_ sender: NSMenuItem) {
        guard let move = sender.representedObject as? FolderMove else { return }
        moveNotes(move.urls, toFolder: move.folder)
    }
    @objc func moveNotesToNewFolderFromMenu(_ sender: NSMenuItem) {
        guard let move = sender.representedObject as? FolderMove,
              let name = promptForFolderName(title: "New Folder", message: move.urls.count == 1 ? "The note moves into it." : "The \(move.urls.count) notes move into it.", confirm: "Create") else { return }
        moveNotes(move.urls, toFolder: name)
    }
    // A folder with nothing in it yet.
    @objc func newFolderFromMenu() {
        guard let name = promptForFolderName(title: "New Folder", message: "Drag notes onto it, or use Move to Folder.", confirm: "Create") else { return }
        createFolder(name)
    }
    func createFolder(_ raw: String) {
        let name = FolderNames.clean(raw)
        guard !name.isEmpty else { return }
        if let existing = FolderNames.existing(name, in: layout.folders) { flash("A folder named “\(existing)” already exists"); return }
        declareFolder(name)
        refreshSidebarKeepingSelection()
        flash("Folder “\(name)” created")
    }

    @objc func renameFolderFromMenu(_ sender: NSMenuItem) {
        guard let old = sender.representedObject as? String,
              let name = promptForFolderName(title: "Rename Folder", message: "", confirm: "Rename", initial: old) else { return }
        renameFolder(old, to: name)
    }
    func renameFolder(_ old: String, to raw: String) {
        let name = FolderNames.clean(raw)
        guard !name.isEmpty, name != old else { return }
        if let clash = FolderNames.existing(name, in: layout.folders), clash != old { flash("A folder named “\(clash)” already exists"); return }
        for url in layout.all where noteInfo(url).meta.folder == old {
            var meta = store.readMeta(url)
            meta.folder = name
            writeMetaPreservingDate(meta, to: url)
            if url == current { currentMeta = meta }
        }
        var order = Prefs.folderOrder
        if let at = order.firstIndex(of: old) { order[at] = name } else { order.append(name) }
        Prefs.folderOrder = order
        Prefs.collapsedFolders = Prefs.collapsedFolders.map { $0 == old ? name : $0 }
        refreshSidebarKeepingSelection()
    }

    @objc func deleteFolderFromMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        removeFolder(name)
    }
    // Removing a folder never deletes a note: they go back to the top of the list, and Undo files them again.
    func removeFolder(_ name: String) {
        let members = layout.all.filter { noteInfo($0).meta.folder == name }
        let before = members.map { (url: $0, order: noteInfo($0).meta.order) }
        let position = Prefs.folderOrder.firstIndex(of: name)
        let wasCollapsed = collapsedFolderSet.contains(name)
        for url in members {
            var meta = store.readMeta(url)
            meta.folder = ""; meta.order = 0
            writeMetaPreservingDate(meta, to: url)
            if url == current { currentMeta = meta }
        }
        Prefs.folderOrder = Prefs.folderOrder.filter { $0 != name }
        Prefs.collapsedFolders = Prefs.collapsedFolders.filter { $0 != name }
        refreshSidebarKeepingSelection()
        let kept = before.isEmpty ? "" : (before.count == 1 ? " — its note is kept" : " — its \(before.count) notes are kept")
        flash("Folder “\(name)” removed\(kept)", actionTitle: "Undo", duration: 6) { [weak self] in
            guard let self = self else { return }
            var order = Prefs.folderOrder.filter { $0 != name }
            order.insert(name, at: min(position ?? order.count, order.count))
            Prefs.folderOrder = order
            if wasCollapsed { Prefs.collapsedFolders = Prefs.collapsedFolders + [name] }
            for old in before {
                var meta = self.store.readMeta(old.url)
                meta.folder = name; meta.order = old.order
                self.writeMetaPreservingDate(meta, to: old.url)
                if old.url == self.current { self.currentMeta = meta }
            }
            self.refreshSidebarKeepingSelection()
        }
    }

    // MARK: drag and drop (the table's data-source methods call this)
    func dropNote(_ src: URL, onto target: NoteLibrary.DropTarget) {
        switch target {
        case .into(let name):
            moveNotes([src], toFolder: name)
        case .group(let folder, let before):
            let list = NoteLibrary.reordered(NoteLibrary.notes(inFolder: folder, items: sidebarItems), moving: src, before: before)
            for (i, url) in list.enumerated() {
                var meta = store.readMeta(url)
                guard meta.order != i + 1 || meta.folder != folder else { continue }       // only rewrite what actually moved
                meta.order = i + 1
                meta.folder = folder
                writeMetaPreservingDate(meta, to: url)
                if url == current { currentMeta = meta }
            }
            refreshSidebarKeepingSelection()
        }
    }

    // MARK: menus
    // "Move to Folder ▸" for these notes: every folder (ticked when they are all in it), New Folder…, and Remove from Folder when any is filed.
    func folderSubmenu(for urls: [URL]) -> NSMenu {
        let sub = NSMenu()
        let filedIn = urls.map { noteInfo($0).meta.folder }
        for name in layout.folders {
            let item = NSMenuItem(title: name, action: #selector(moveNotesFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = FolderMove(urls: urls, folder: name)
            item.image = sym("folder")
            item.state = filedIn.allSatisfy { $0 == name } ? .on : .off
            sub.addItem(item)
        }
        if !layout.folders.isEmpty { sub.addItem(.separator()) }
        let new = NSMenuItem(title: "New Folder…", action: #selector(moveNotesToNewFolderFromMenu(_:)), keyEquivalent: "")
        new.target = self
        new.representedObject = FolderMove(urls: urls, folder: "")
        new.image = sym("folder.badge.plus")
        sub.addItem(new)
        if filedIn.contains(where: { !$0.isEmpty }) {
            let out = NSMenuItem(title: "Remove from Folder", action: #selector(moveNotesFromMenu(_:)), keyEquivalent: "")
            out.target = self
            out.representedObject = FolderMove(urls: urls, folder: "")
            out.image = sym("folder.badge.minus")
            sub.addItem(.separator())
            sub.addItem(out)
        }
        return sub
    }
    func addFolderItem(to menu: NSMenu, urls: [URL]) {
        let item = NSMenuItem(title: "Move to Folder", action: nil, keyEquivalent: "")
        item.image = sym("folder")
        item.submenu = folderSubmenu(for: urls)
        menu.addItem(item)
    }
    func addNewFolderItem(to menu: NSMenu) {
        let item = NSMenuItem(title: "New Folder…", action: #selector(newFolderFromMenu), keyEquivalent: "")
        item.target = self
        item.image = sym("folder.badge.plus")
        menu.addItem(item)
    }
    // Right-click on a folder's header.
    func populateFolderMenu(_ menu: NSMenu, folder: String) {
        func add(_ title: String, _ symbol: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.image = sym(symbol); item.representedObject = folder
            menu.addItem(item)
        }
        let collapsed = collapsedFolderSet.contains(folder)
        add(collapsed ? "Expand" : "Collapse", collapsed ? "chevron.down" : "chevron.right", #selector(toggleFolderFromMenu(_:)))
        add("Rename Folder…", "pencil", #selector(renameFolderFromMenu(_:)))
        menu.addItem(.separator())
        add("Remove Folder", "folder.badge.minus", #selector(deleteFolderFromMenu(_:)))
        menu.addItem(.separator())
        addNewFolderItem(to: menu)
    }
}
