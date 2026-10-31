import Foundation

// ============================================================================
// NoteLibrary — the rules about the note list, as pure Foundation functions.
// AppDelegate supplies data (it caches file reads); these decide order, filtering and housekeeping, so
// the intricate, GOTCHAS-documented behaviour can be tested without AppKit.
// ============================================================================
enum NoteLibrary {
    struct Entry {
        let url: URL
        let pin: Bool
        let order: Int          // manual position; 0 = never dragged
        let modified: Date
        var folder: String = ""   // "" = not in a folder
    }

    // Pinned notes lead; then notes with NO manual order, newest first; then the notes you dragged into
    // place, by ascending position. Unordered notes sort ABOVE ordered ones — otherwise, once a single drag
    // had numbered the whole list, every note created afterwards sank to the bottom (GOTCHAS 2026-09-03).
    // Equal keys fall back to the path so the list never shuffles between launches.
    static func sorted(_ entries: [Entry]) -> [URL] {
        entries.sorted { a, b in
            if a.pin != b.pin { return a.pin }
            if a.order != b.order {
                if a.order == 0 { return true }
                if b.order == 0 { return false }
                return a.order < b.order
            }
            if a.modified != b.modified { return a.modified > b.modified }
            return a.url.path < b.url.path
        }.map { $0.url }
    }

    // Every whitespace-separated term must appear (any order), ignoring case and diacritics.
    static func matches(_ text: String, query: String) -> Bool {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return terms.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    // Blank notes that are safe to sweep: not spared (the one in the editor, those open in windows).
    static func strays(in urls: [URL], spared: Set<URL>, isBlank: (URL) -> Bool) -> [URL] {
        urls.filter { !spared.contains($0) && isBlank($0) }
    }

    // The blank note worth reusing instead of creating another: the first (most recently touched) one
    // that isn't open in its own window.
    static func reusableBlank(in urls: [URL], inWindows: Set<URL>, isBlank: (URL) -> Bool) -> URL? {
        urls.first { !inWindows.contains($0) && isBlank($0) }
    }
}

// How a note row says when it was last touched, the way Apple Notes does: the time today, "Yesterday", the weekday this week,
// "Sep 27" this year, "9/27/25" before that. Pure: calendar, locale and `now` are parameters, so the tests pin them down.
enum RelativeTime {
    static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        func format(_ template: String) -> String {
            let f = DateFormatter()
            f.calendar = calendar; f.locale = locale; f.timeZone = calendar.timeZone
            f.setLocalizedDateFormatFromTemplate(template)
            return f.string(from: date)
        }
        if date > now { return format("jm") }                                             // a clock a little ahead of the file's: treat as just now
        if calendar.isDate(date, inSameDayAs: now) { return format("jm") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            // The locale's own word for it. A formatter's "relative" wording is relative to the REAL clock, so ask it about the real yesterday.
            let f = DateFormatter(); f.calendar = calendar; f.locale = locale; f.timeZone = calendar.timeZone
            f.dateStyle = .medium; f.timeStyle = .none; f.doesRelativeDateFormatting = true
            let word = calendar.date(byAdding: .day, value: -1, to: Date()).map { f.string(from: $0) } ?? "Yesterday"
            return word.contains(where: \.isNumber) ? "Yesterday" : word        // a locale without a relative word: say it in English
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 99
        if days < 7 { return format("EEE") }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return format("MMMd") }
        let f = DateFormatter(); f.calendar = calendar; f.locale = locale; f.timeZone = calendar.timeZone
        f.dateStyle = .short; f.timeStyle = .none
        return f.string(from: date)
    }
}

// Searching the notes list: case-, accent- and width-insensitive, every word of the query must appear somewhere in the note's
// title or body ("resume draft" finds "Résumé — first draft"). `fold` is applied once per note and cached by the caller.
extension NoteLibrary {
    static func fold(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil) }
    static func matches(folded text: String, query: String) -> Bool {
        let terms = fold(query).split(whereSeparator: { $0.isWhitespace })
        return terms.allSatisfy { text.contains($0) }
    }
}

// What changed between two versions of a list, as the fewest row removals and insertions: the rows that stay (the longest common
// subsequence) keep their place, so a table can slide just the others out and in instead of reloading everything — and keeps its
// scroll position and selection. `removed` counts OLD indices, `inserted` counts NEW ones (the order a table applies them in).
// nil when the lists are too large to diff cheaply: the caller reloads.
enum ListDiff {
    struct Change: Equatable { var removed: [Int]; var inserted: [Int] }

    static func compute<T: Equatable>(old: [T], new: [T], limit: Int = 1_000_000) -> Change? {
        if old == new { return Change(removed: [], inserted: []) }
        let n = old.count, m = new.count
        if n * m > limit { return nil }
        let width = m + 1
        var table = [Int32](repeating: 0, count: (n + 1) * width)
        if n > 0, m > 0 {
            for i in 1...n { for j in 1...m {
                table[i * width + j] = old[i - 1] == new[j - 1] ? table[(i - 1) * width + j - 1] + 1 : max(table[(i - 1) * width + j], table[i * width + j - 1])
            } }
        }
        var removed: [Int] = [], inserted: [Int] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, old[i - 1] == new[j - 1] { i -= 1; j -= 1 }
            else if j > 0, i == 0 || table[i * width + j - 1] >= table[(i - 1) * width + j] { inserted.append(j - 1); j -= 1 }
            else { removed.append(i - 1); i -= 1 }
        }
        return Change(removed: removed.reversed(), inserted: inserted.reversed())
    }
    // Applies a change the way a table does (remove by old index, then insert by new index) — what the tests check against `new`.
    static func apply<T>(_ change: Change, to old: [T], producing new: [T]) -> [T] {
        var result = old
        for i in change.removed.reversed() { result.remove(at: i) }
        for j in change.inserted { result.insert(new[j], at: j) }
        return result
    }
}

// ============================================================================
// Folders — notes are grouped in the sidebar by the `folder:` frontmatter key. The files stay flat in one directory (so Obsidian-style
// tools, search and sync keep working); a folder is just a name that notes share. Everything here is pure so test.sh can pin it down.
// ============================================================================

// A folder name as it is stored and shown: control characters and line breaks become spaces, `"` becomes `'` and `\` becomes `/`
// (the name is written as a double-quoted YAML scalar, and Jot's own reader does no unescaping), trimmed and capped at 60 characters.
enum FolderNames {
    static let maxLength = 60
    static func clean(_ raw: String) -> String {
        var out = ""
        for scalar in raw.unicodeScalars {
            if scalar == "\"" { out.append("'") }
            else if scalar == "\\" { out.append("/") }
            else if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) { out.append(" ") }
            else { out.unicodeScalars.append(scalar) }
        }
        out = out.trimmingCharacters(in: .whitespaces)
        if out.count > maxLength { out = String(out.prefix(maxLength)).trimmingCharacters(in: .whitespaces) }
        return out
    }
    // The existing folder a typed name refers to (case- and accent-insensitive), so "work" files into "Work" instead of making a twin.
    static func existing(_ name: String, in names: [String]) -> String? {
        names.first { $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }
}

// One row of the sidebar: a folder's header, or a note.
enum SidebarItem: Equatable {
    case folder(String)
    case note(URL)
}

extension NoteLibrary {
    struct Layout {
        var items: [SidebarItem] = []     // the table's rows, top to bottom
        var notes: [URL] = []             // the notes that have a row (a collapsed folder's notes don't), in row order
        var all: [URL] = []               // every note in display order, collapsed folders included
        var folders: [String] = []        // every folder, in display order
        var counts: [String: Int] = [:]   // notes per folder, collapsed or not
    }

    // Unfiled notes first (pinned → manual order → newest, as ever), then each folder: its header, then its notes in the same order.
    // `folderOrder` is the order folders were made in; a folder only some note names (edited outside Jot) follows them alphabetically.
    // A folder in `collapsed` keeps its header and its count but lists no notes. With no folders at all this is just `sorted`.
    static func layout(_ entries: [Entry], folderOrder: [String], collapsed: Set<String>) -> Layout {
        var unfiled: [Entry] = []
        var filed: [String: [Entry]] = [:]
        for e in entries {
            if e.folder.isEmpty { unfiled.append(e) } else { filed[e.folder, default: []].append(e) }
        }
        var names: [String] = []
        var seen = Set<String>()
        for n in folderOrder where !n.isEmpty && seen.insert(n).inserted { names.append(n) }
        names += filed.keys.filter { !seen.contains($0) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        var out = Layout()
        out.folders = names
        let top = sorted(unfiled)
        out.items += top.map { SidebarItem.note($0) }
        out.notes += top
        out.all += top
        for name in names {
            let group = sorted(filed[name] ?? [])
            out.counts[name] = group.count
            out.items.append(.folder(name))
            out.all += group
            if !collapsed.contains(name) {
                out.items += group.map { SidebarItem.note($0) }
                out.notes += group
            }
        }
        return out
    }

    // The folder a row belongs to: its own name for a header, otherwise the nearest header above it ("" above the first one).
    static func folder(atRow row: Int, in items: [SidebarItem]) -> String {
        var i = min(row, items.count - 1)
        while i >= 0 {
            if case .folder(let name) = items[i] { return name }
            i -= 1
        }
        return ""
    }
    // The notes listed under a folder ("" = the unfiled ones), top to bottom.
    static func notes(inFolder folder: String, items: [SidebarItem]) -> [URL] {
        var current = ""
        var out: [URL] = []
        for item in items {
            switch item {
            case .folder(let name): current = name
            case .note(let url): if current == folder { out.append(url) }
            }
        }
        return out
    }

    // Where a drag lands. Dropping ON a folder header files the note there; dropping between rows puts it in the group that gap is in,
    // before the note below it. The gap above a header belongs to the end of the group above it. A collapsed folder can't show a position, so
    // it simply takes the note.
    enum DropTarget: Equatable {
        case into(String)
        case group(String, before: URL?)
    }
    static func dropTarget(row: Int, onRow: Bool, items: [SidebarItem], collapsed: Set<String>) -> DropTarget? {
        if onRow {
            guard row >= 0, row < items.count else { return nil }
            if case .folder(let name) = items[row] { return .into(name) }
        }
        guard row >= 0 else { return nil }
        var group = ""
        var before: URL? = nil
        if row >= items.count {
            group = items.isEmpty ? "" : folder(atRow: items.count - 1, in: items)
        } else {
            switch items[row] {
            case .note(let url): group = folder(atRow: row, in: items); before = url
            case .folder: group = row == 0 ? "" : folder(atRow: row - 1, in: items)
            }
        }
        if !group.isEmpty, collapsed.contains(group) { return .into(group) }
        return .group(group, before: before)
    }
    // The group's notes with `moving` taken out and put back before `before` (at the end when nil). Dropping a note on its own gap changes nothing.
    static func reordered(_ group: [URL], moving: URL, before: URL?) -> [URL] {
        if before == moving { return group }
        var list = group.filter { $0 != moving }
        let at = before.flatMap { list.firstIndex(of: $0) } ?? list.count
        list.insert(moving, at: at)
        return list
    }
}
