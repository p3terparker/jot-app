import Foundation

let jotDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Jot/Notes")

// ============================================================================
// MARK: - NoteMeta + YAML frontmatter  (per-note metadata, stored at top of .md)
// ============================================================================
// Format:
//   ---
//   pin: true
//   order: 3
//   folder: "Work"
//   reminder: 2026-07-15T09:00:00Z
//   ---
// Notes without frontmatter use defaults. read() strips it; write() keeps it.
//
// Jot only owns the keys in `jotFrontmatterKeys`. Everything else in the block — Obsidian `tags:` and
// `aliases:`, YAML lists, comments, blank lines, nested maps — belongs to the author and is carried
// through every save untouched: writes PATCH the original lines (see `formatFrontmatter`) rather than
// regenerating the block from the known fields.
let jotFrontmatterKeys = ["pin", "priority", "order", "folder", "textColor", "reminder", "rtfMode"]

struct NoteMeta {
    var pin: Bool = false
    var priority: Int = 0       // 0=none, 1=high, 2=medium, 3=low (no longer shown in the UI; kept so nothing is lost)
    var order: Int = 0          // manual sort position (within the note's folder, or among the unfiled notes)
    var folder: String = ""     // sidebar folder the note is filed in; "" = not in a folder (always written quoted: see canonicalLine)
    var textColor: String = ""  // hex, "" = default (no longer shown in the UI; kept so nothing is lost)
    var reminder: Date? = nil
    var rtfMode: Bool = false   // legacy rich-text note: its body is base64 RTF until it is converted to Markdown

    // The frontmatter exactly as found: the lines between the fences (no line endings) and the file's
    // line ending ("\r\n" files stay CRLF).
    var rawLines: [String] = []
    var lineEnding: String = "\n"

    // Frontmatter the author wrote that Jot doesn't own (anything except blank lines and Jot's own keys).
    var hasForeignContent: Bool {
        rawLines.contains { line in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return false }
            guard let key = frontmatterKey(line) else { return true }     // comment, list item, nested line
            return !jotFrontmatterKeys.contains(key)
        }
    }

    // Anything the user deliberately set on this note. `order` is excluded on purpose: a manual
    // sort position doesn't make an otherwise-empty note worth keeping (see AppDelegate.isBlankNote).
    // Hand-written frontmatter counts: a note carrying it is never swept as an empty scratch note.
    var isDecorated: Bool {
        pin || priority > 0 || !folder.isEmpty || !textColor.isEmpty || reminder != nil || rtfMode || hasForeignContent
    }
    var hasContent: Bool { isDecorated || order > 0 }
}

let metaDateFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

// A line is a key line only when it starts at column 0 with `key:`; indented lines, `- ` list items and
// `#` comments belong to whatever block they sit in.
func frontmatterKey(_ line: String) -> String? {
    guard let first = line.first, first != " ", first != "\t", first != "#", first != "-",
          let colon = line.firstIndex(of: ":") else { return nil }
    let key = line[..<colon].trimmingCharacters(in: .whitespaces)
    return key.isEmpty ? nil : key
}

private func unquoted(_ raw: String) -> String {
    var value = raw.trimmingCharacters(in: .whitespaces)
    for quote in ["\"", "'"] where value.count >= 2 && value.hasPrefix(quote) && value.hasSuffix(quote) {
        value.removeFirst(); value.removeLast(); break
    }
    return value
}

private func apply(_ key: String, _ rawValue: String, to meta: inout NoteMeta) {
    let value = unquoted(rawValue)
    switch key {
    case "pin":       meta.pin = value.lowercased() == "true"
    case "priority":  meta.priority = Int(value) ?? 0
    case "order":     meta.order = Int(value) ?? 0
    case "folder":    meta.folder = FolderNames.clean(value)
    case "textColor": meta.textColor = value
    case "reminder":  meta.reminder = metaDateFormatter.date(from: value)
    case "rtfMode":   meta.rtfMode = value.lowercased() == "true"
    default: break
    }
}

// Jot's own spelling of a key's value, or nil when the field is at its default (and so absent).
private func canonicalLine(_ key: String, _ m: NoteMeta) -> String? {
    switch key {
    case "pin":       return m.pin ? "pin: true" : nil
    case "priority":  return m.priority > 0 ? "priority: \(m.priority)" : nil
    case "order":     return m.order > 0 ? "order: \(m.order)" : nil
    case "folder":    return m.folder.isEmpty ? nil : "folder: \"\(m.folder)\""
    case "textColor": return m.textColor.isEmpty ? nil : "textColor: \"\(m.textColor)\""
    case "reminder":  return m.reminder.map { "reminder: \(metaDateFormatter.string(from: $0))" }
    case "rtfMode":   return m.rtfMode ? "rtfMode: true" : nil
    default:          return nil
    }
}

func parseFrontmatter(_ raw: String) -> (meta: NoteMeta, body: String) {
    var meta = NoteMeta()
    let crlf = raw.hasPrefix("---\r\n")
    guard raw.hasPrefix("---\n") || crlf else { return (meta, raw) }
    let lines = raw.components(separatedBy: "\n")
    guard lines.count >= 2 else { return (meta, raw) }
    var endLine = -1
    for i in 1..<lines.count {
        // `\r` counts: in a CRLF file the closing fence is "---\r".
        if lines[i].trimmingCharacters(in: .whitespacesAndNewlines) == "---" { endLine = i; break }
    }
    guard endLine > 0 else { return (meta, raw) }   // no closing delimiter → not frontmatter
    meta.lineEnding = crlf ? "\r\n" : "\n"
    for i in 1..<endLine {
        var line = lines[i]
        if line.hasSuffix("\r") { line.removeLast() }
        meta.rawLines.append(line)
        guard let key = frontmatterKey(line), jotFrontmatterKeys.contains(key),
              let colon = line.firstIndex(of: ":") else { continue }
        apply(key, String(line[line.index(after: colon)...]), to: &meta)
    }
    let bodyStart = min(endLine + 1, lines.count)
    let body = lines[bodyStart...].joined(separator: "\n")
    return (meta, body)
}

// Patches the original lines: Jot's keys are updated in place (a line whose value didn't change keeps the
// author's own spelling), a key back at its default is dropped, newly set keys are appended, and every
// other line — unknown keys, comments, lists, blank lines — is kept verbatim and in order.
func formatFrontmatter(_ meta: NoteMeta) -> String {
    var out: [String] = []
    var seen = Set<String>()
    for line in meta.rawLines {
        guard let key = frontmatterKey(line), jotFrontmatterKeys.contains(key), let colon = line.firstIndex(of: ":") else {
            out.append(line); continue
        }
        if !seen.insert(key).inserted { continue }                                   // a repeated Jot key: keep the first
        guard let wanted = canonicalLine(key, meta) else { continue }                // back at its default: drop it
        var original = NoteMeta()
        apply(key, String(line[line.index(after: colon)...]), to: &original)
        out.append(canonicalLine(key, original) == wanted ? line : wanted)           // unchanged → the author's spelling
    }
    for key in jotFrontmatterKeys where !seen.contains(key) {
        if let line = canonicalLine(key, meta) { out.append(line) }
    }
    if out.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { return "" }   // nothing left worth a fence
    return (["---"] + out + ["---"]).joined(separator: meta.lineEnding) + meta.lineEnding
}

// ============================================================================
// MARK: - NotesStore  (each note = one .md file)
// ============================================================================
final class NotesStore {
    let dir: URL
    var onWriteError: ((Error) -> Void)?
    // Recently Deleted lives beside Notes: ~/Library/Application Support/Jot/RecentlyDeleted
    let trashDir: URL
    init(dir: URL = jotDir, trashDir: URL? = nil) {
        self.dir = dir
        self.trashDir = trashDir ?? dir.deletingLastPathComponent().appendingPathComponent("RecentlyDeleted")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: self.trashDir, withIntermediateDirectories: true)
    }
    private func mdFiles(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { $0.pathExtension == "md" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    }
    func all() -> [URL] { mdFiles(in: dir) }
    func create() throws -> URL {
        let u = dir.appendingPathComponent("\(UUID().uuidString).md")
        try "".write(to: u, atomically: true, encoding: .utf8)
        return u
    }
    func readRaw(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "" }
    func read(_ u: URL) -> String { parseFrontmatter(readRaw(u)).body }
    func readMeta(_ u: URL) -> NoteMeta { parseFrontmatter(readRaw(u)).meta }
    func isUndecoratedBlank(_ u: URL) -> Bool {
        guard let raw = try? String(contentsOf: u, encoding: .utf8) else { return false }
        let (meta, body) = parseFrontmatter(raw)
        return !meta.isDecorated && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    @discardableResult
    func write(_ body: String, to u: URL) -> Bool {
        do {
            let meta = FileManager.default.fileExists(atPath: u.path)
                ? parseFrontmatter(try String(contentsOf: u, encoding: .utf8)).meta : NoteMeta()
            try (formatFrontmatter(meta) + body).write(to: u, atomically: true, encoding: .utf8)
            return true
        } catch { onWriteError?(error); return false }
    }
    // Editor autosaves may only update a note that still exists. Reading must succeed before
    // replacing the file: an unreadable note is not an empty note, and a deleted one stays deleted.
    func saveExisting(_ body: String, to u: URL) throws {
        let raw = try String(contentsOf: u, encoding: .utf8)
        let full = formatFrontmatter(parseFrontmatter(raw).meta) + body
        if full == raw { return }          // unchanged: no write, so merely visiting a note doesn't move it to the top of the list
        try full.write(to: u, atomically: true, encoding: .utf8)
    }
    @discardableResult
    func writeMeta(_ meta: NoteMeta, to u: URL) -> Bool {
        do {
            let body = parseFrontmatter(try String(contentsOf: u, encoding: .utf8)).body
            try (formatFrontmatter(meta) + body).write(to: u, atomically: true, encoding: .utf8)
            return true
        } catch { onWriteError?(error); return false }
    }

    // MARK: Recently Deleted (kept 30 days, then purged). delete() moves the note here — NOT to the
    // system Trash — and stamps the file's modification date as the deletion time.
    // Returns where the note went, so the caller can offer Undo.
    @discardableResult
    func delete(_ u: URL) throws -> URL {
        let dest = uniqueURL(in: trashDir, preferredName: u.lastPathComponent)
        // A failed recoverable move must leave the original intact, never fall back to unlinking it.
        try FileManager.default.moveItem(at: u, to: dest)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path)
        return dest
    }
    // Always asked of the file system. A URL instance CACHES resource values, so the same URL asked again after a write still
    // reports the old date — see GOTCHAS.md ("a URL remembers its old modification date").
    func modificationDate(_ u: URL) -> Date? { (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date }
    func fileSize(_ u: URL) -> Int? { ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.intValue }
    func trashedAll() -> [URL] { mdFiles(in: trashDir) }
    func deletedDate(_ u: URL) -> Date { modificationDate(u) ?? .distantPast }
    // "Restore" from the list bumps the note to the top (modified now). Undo passes the note's own name and old modification
    // date, so it lands exactly where it was in the list — under a different name only if that one has been taken since.
    func restore(_ u: URL, as original: URL? = nil, modified: Date? = nil) throws -> URL {
        let dest = uniqueURL(in: dir, preferredName: (original ?? u).lastPathComponent)
        try FileManager.default.moveItem(at: u, to: dest)
        try? FileManager.default.setAttributes([.modificationDate: modified ?? Date()], ofItemAtPath: dest.path)
        return dest
    }
    func deletePermanently(_ u: URL) { try? FileManager.default.trashItem(at: u, resultingItemURL: nil) }
    func purgeTrash(olderThanDays days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for u in trashedAll() where deletedDate(u) < cutoff { try? FileManager.default.removeItem(at: u) }
    }
    private func uniqueURL(in folder: URL, preferredName: String) -> URL {
        var dest = folder.appendingPathComponent(preferredName)
        let base = (preferredName as NSString).deletingPathExtension
        let ext = (preferredName as NSString).pathExtension
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent("\(base)-\(n).\(ext)"); n += 1
        }
        return dest
    }
}
