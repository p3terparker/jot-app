import Cocoa   // RTF decoding is AppKit's; the rest of the migration is plain Foundation

// ============================================================================
// LegacyRTF — Jot ≤ 2.9 could keep a note as base64-encoded RTF with `rtfMode: true` in its
// frontmatter. Jot 3 edits Markdown only; RTF survives as an EXPORT format.
//
// Converting such a note is the one place Jot rewrites your files on its own, so it is deliberately
// conservative:
//   • a byte-identical backup of the original file is written AND READ BACK before anything changes;
//   • any failure (undecodable body, backup problem, write error) leaves the note exactly as it was;
//   • the rewrite keeps every other frontmatter line and the file's modification date (the list order
//     must not move), and only drops `rtfMode`;
//   • it runs once at launch, before any editor loads, and is idempotent (a converted note no longer
//     has `rtfMode`).
// Backups live in `…/Jot/Backups/RTF/<timestamp>/`, next to a plain `.rtf` copy you can open in TextEdit.
// ============================================================================
enum LegacyRTF {
    struct Report {
        var converted: [URL] = []
        var failed: [(url: URL, reason: String)] = []
        var backupDirectory: URL?
        var isEmpty: Bool { converted.isEmpty && failed.isEmpty }
    }

    static func backupRoot(for store: NotesStore) -> URL {
        store.dir.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true).appendingPathComponent("RTF", isDirectory: true)
    }

    static func migrate(_ store: NotesStore, now: Date = Date()) -> Report {
        var report = Report()
        let fm = FileManager.default
        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
            return f.string(from: now)
        }()
        let runDirectory = backupRoot(for: store).appendingPathComponent(stamp, isDirectory: true)

        for url in store.all() {
            guard let original = try? Data(contentsOf: url), let raw = String(data: original, encoding: .utf8) else { continue }   // unreadable: not ours to touch
            let (meta, body) = parseFrontmatter(raw)
            guard meta.rtfMode else { continue }
            let encoded = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let rtfData = Data(base64Encoded: encoded), let attrs = NSAttributedString(rtf: rtfData, documentAttributes: nil) else {
                report.failed.append((url, "its rich-text body could not be read")); continue
            }
            let markdown = toMarkdown(attrs)

            // 1. Back up first, and prove the backup before touching the note.
            let backup = runDirectory.appendingPathComponent(url.lastPathComponent)
            do {
                try fm.createDirectory(at: runDirectory, withIntermediateDirectories: true)
                try original.write(to: backup, options: .atomic)
                guard try Data(contentsOf: backup) == original else { throw CocoaError(.fileWriteUnknown) }
                try? rtfData.write(to: runDirectory.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".rtf"), options: .atomic)
            } catch {
                report.failed.append((url, "its backup could not be written (\(error.localizedDescription))")); continue
            }

            // 2. Rewrite: Markdown body, `rtfMode` gone, everything else in the frontmatter kept, same modification date.
            var converted = meta
            converted.rtfMode = false
            let modified = store.modificationDate(url)
            do { try (formatFrontmatter(converted) + markdown).write(to: url, atomically: true, encoding: .utf8) }
            catch { report.failed.append((url, "it could not be rewritten (\(error.localizedDescription))")); continue }
            if let modified = modified { try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
            report.converted.append(url)
            report.backupDirectory = runDirectory
        }
        return report
    }

    // Paragraph by paragraph: headings from the largest font in the paragraph (relative to the body size,
    // the font size covering the most characters), bold / italic / links from runs. Whitespace stays outside
    // the markers (`** bold **` isn't emphasis in Markdown).
    static func toMarkdown(_ attrs: NSAttributedString) -> String {
        let ns = attrs.string as NSString
        guard ns.length > 0 else { return "" }
        var weight: [CGFloat: Int] = [:]
        attrs.enumerateAttribute(.font, in: NSRange(location: 0, length: ns.length)) { value, range, _ in
            if let font = value as? NSFont { weight[(font.pointSize * 2).rounded() / 2, default: 0] += range.length }
        }
        let base = weight.max { $0.value < $1.value }?.key ?? 13

        func isBreak(_ c: unichar) -> Bool { c == 10 || c == 13 || c == 0x2028 || c == 0x2029 }
        var out = ""
        var location = 0
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            var content = line
            while content.length > 0, isBreak(ns.character(at: NSMaxRange(content) - 1)) { content.length -= 1 }
            let terminator = ns.substring(with: NSRange(location: NSMaxRange(content), length: NSMaxRange(line) - NSMaxRange(content)))
            out += paragraph(attrs, ns, content, base: base) + terminator
            location = NSMaxRange(line)
        }
        return out
    }

    private static func paragraph(_ attrs: NSAttributedString, _ ns: NSString, _ range: NSRange, base: CGFloat) -> String {
        guard range.length > 0 else { return "" }
        var largest: CGFloat = 0
        attrs.enumerateAttribute(.font, in: range) { value, _, _ in
            if let font = value as? NSFont { largest = max(largest, font.pointSize) }
        }
        let ratio = base > 0 ? largest / base : 1
        let level = ratio >= 1.5 ? 1 : ratio >= 1.38 ? 2 : ratio >= 1.25 ? 3 : ratio >= 1.15 ? 4 : 0

        var text = ""
        attrs.enumerateAttributes(in: range) { attributes, run, _ in
            let piece = ns.substring(with: run)
            let core = piece.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else { text += piece; return }
            let leading = String(piece.prefix(while: { $0 == " " || $0 == "\t" }))
            let trailing = String(piece.reversed().prefix(while: { $0 == " " || $0 == "\t" }).reversed())
            var styled = core
            if let font = attributes[.font] as? NSFont, level == 0 {          // a heading is bold already
                let traits = font.fontDescriptor.symbolicTraits
                let marker = traits.contains(.bold) && traits.contains(.italic) ? "***" : traits.contains(.bold) ? "**" : traits.contains(.italic) ? "*" : ""
                styled = marker + core + marker
            }
            if let link = attributes[.link] {
                let target = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                if !target.isEmpty { styled = "[\(core)](\(target))" }
            }
            text += leading + styled + trailing
        }
        return level > 0 ? String(repeating: "#", count: level) + " " + text : text
    }
}
