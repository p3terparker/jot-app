import Cocoa

// ============================================================================
// NoteFilter — the search field above the notes list (⌥⌘F). It filters the list by title AND body, ignoring case and accents
// ("resume" finds "Résumé"), as you type. `allNotes` is the whole library in display order; `notes` is what has a row. While a
// filter is active the list is FLAT — matches only, no folder headers, folded-shut folders searched too — and reordering is off
// (a position in a partial list means nothing). Without a filter the rows are the folders' layout (Folders.swift).
//   Esc clears the field (a second Esc closes the drawer / pad) · Return opens the first match · ↓ moves into the list.
// ============================================================================
extension AppDelegate {
    var isFiltering: Bool { !filterText.trimmingCharacters(in: .whitespaces).isEmpty }

    // Re-list the notes from disk, lay them out into folders, then apply the filter.
    func rebuildNotes() {
        layout = NoteLibrary.layout(store.all().map { noteEntry($0) }, folderOrder: Prefs.folderOrder, collapsed: collapsedFolderSet)
        allNotes = layout.all
        applyFilter()
        updateFilterEmptyState()
    }
    // The rows for the current filter: the folder layout, or — while searching — the flat list of matches.
    func applyFilter() {
        if isFiltering {
            let hits = filteredNotes(allNotes)
            setSidebar(items: hits.map { SidebarItem.note($0) }, notes: hits)
        } else {
            setSidebar(items: layout.items, notes: layout.notes)
        }
    }
    // Swaps in new rows and brings the table up to date: rows slide in and out when the sidebar is on screen (so the
    // list keeps its scroll position and selection), a plain reload otherwise.
    func setSidebar(items new: [SidebarItem], notes newNotes: [URL]) {
        let old = sidebarItems
        sidebarItems = new
        notes = newNotes
        guard !viewingTrash, sidebarShown, dropdown?.isVisible == true, animatesSidebar, tableView.numberOfRows == old.count,
              let diff = ListDiff.compute(old: old, new: new) else {
            tableView.reloadData(); return
        }
        if !diff.removed.isEmpty || !diff.inserted.isEmpty {
            tableView.beginUpdates()
            if !diff.removed.isEmpty { tableView.removeRows(at: IndexSet(diff.removed), withAnimation: [.effectFade, .slideUp]) }
            if !diff.inserted.isEmpty { tableView.insertRows(at: IndexSet(diff.inserted), withAnimation: [.effectFade, .slideDown]) }
            tableView.endUpdates()
        }
        let kept = IndexSet(new.indices).subtracting(IndexSet(diff.inserted))             // rows that stayed may show a new title, time or folder count
        if !kept.isEmpty { tableView.reloadData(forRowIndexes: kept, columnIndexes: IndexSet(integer: 0)) }
    }
    func filteredNotes(_ all: [URL]) -> [URL] {
        guard isFiltering else { return all }
        return all.filter { NoteLibrary.matches(folded: foldedText(of: $0), query: filterText) }
    }
    // The note's whole text, folded once and cached until the file changes.
    private func foldedText(of url: URL) -> String {
        let mod = store.modificationDate(url) ?? .distantPast, size = store.fileSize(url) ?? -1
        if let hit = foldedCache[url], hit.date == mod, hit.size == size { return hit.text }
        let text = NoteLibrary.fold(store.read(url))
        foldedCache[url] = (mod, size, text)
        return text
    }

    @objc func filterChanged(_ sender: NSSearchField) {
        filterText = sender.stringValue
        let keep = current
        applyFilter()
        if let c = keep, let row = rowIndex(of: c) { tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        updateFilterEmptyState()
    }
    func clearFilter() {
        guard !searchField.stringValue.isEmpty || !filterText.isEmpty else { return }
        searchField.stringValue = ""
        filterChanged(searchField)
    }
    func updateFilterEmptyState() {
        filterEmptyLabel.isHidden = !(isFiltering && notes.isEmpty) || viewingTrash
    }

    // View ▸ Search Notes (⌥⌘F): open the sidebar if it is closed and put the caret in the field.
    @objc func focusSearch() {
        guard !viewingTrash else { return }
        if !dropdown.isVisible { presentDropdown() }
        showSidebar()
        dropdown.makeFirstResponder(searchField)
    }
}

extension AppDelegate: NSSearchFieldDelegate {
    func control(_ control: NSControl, textView fieldEditor: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === searchField else { return false }
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            if !searchField.stringValue.isEmpty { clearFilter() }
            else { escape() }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if let first = notes.first { openOrSelect(first); sidebarRowPicked(0); if sidebarDocks, noteWindows.allSatisfy({ $0.url != first }) { dropdown.makeFirstResponder(textView) } }
            return true
        case #selector(NSResponder.moveDown(_:)):
            if tableView.selectedRow < 0, !notes.isEmpty { tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            dropdown.makeFirstResponder(tableView)
            return true
        default:
            return false
        }
    }
}
