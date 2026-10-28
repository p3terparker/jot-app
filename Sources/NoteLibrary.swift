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
