import Foundation

// ============================================================================
// MarkdownHTML — a note as clean, semantic HTML (Save As ▸ HTML). Pure Foundation, built on MarkdownScanner, so the same
// understanding of Markdown drives the editor and the export. Nothing is executed or fetched: only http, https and mailto links
// keep their address, images become their alt text, and every piece of text is escaped.
// ============================================================================
enum MarkdownHTML {
    static func document(_ markdown: String, title: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>body{font:16px/1.5 -apple-system,Helvetica,Arial,sans-serif;max-width:42em;margin:2em auto;padding:0 1em;color:#222}
        code,pre{font-family:ui-monospace,Menlo,monospace;font-size:.92em}pre{background:#f4f4f4;padding:.8em;border-radius:6px;overflow:auto}
        code{background:#f4f4f4;padding:.1em .3em;border-radius:4px}pre code{background:none;padding:0}blockquote{margin:1em 0;padding-left:1em;border-left:3px solid #ccc;color:#555}
        table{border-collapse:collapse}th,td{border:1px solid #ccc;padding:.3em .6em}li.task{list-style:none;margin-left:-1.2em}hr{border:0;border-top:1px solid #ccc}</style>
        </head><body>
        \(body(markdown))</body></html>
        """
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: inline
    private static func unescapeBackslashes(_ s: String) -> String {
        var out = "", pending = false
        for ch in s {
            if pending { if "\\`*_{}[]()#+-.!~|>".contains(ch) { out.append(ch) } else { out.append("\\"); out.append(ch) }; pending = false }
            else if ch == "\\" { pending = true } else { out.append(ch) }
        }
        if pending { out.append("\\") }
        return out
    }
    private static func inline(_ ns: NSString, _ range: NSRange, _ spans: [MDSpan]) -> String {
        guard range.length > 0 else { return "" }
        let inside = spans.filter { $0.full.location >= range.location && NSMaxRange($0.full) <= NSMaxRange(range) }
                          .sorted { $0.full.location != $1.full.location ? $0.full.location < $1.full.location : $0.full.length > $1.full.length }
        var out = "", pos = range.location
        var consumedUntil = range.location
        for span in inside where span.full.location >= consumedUntil {
            if span.full.location > pos { out += escape(unescapeBackslashes(ns.substring(with: NSRange(location: pos, length: span.full.location - pos)))) }
            let within = inside.filter { $0.full.location >= span.content.location && NSMaxRange($0.full) <= NSMaxRange(span.content) && $0 != span }
            let content = span.kind == .code ? escape(ns.substring(with: span.content)) : inline(ns, span.content, within)
            switch span.kind {
            case .strong: out += "<strong>\(content)</strong>"
            case .emphasis: out += "<em>\(content)</em>"
            case .strike: out += "<del>\(content)</del>"
            case .code: out += "<code>\(content)</code>"
            case .link:
                let isImage = ns.substring(with: span.open).hasPrefix("!")
                let address = span.url.map { ns.substring(with: $0).trimmingCharacters(in: .whitespaces) } ?? ""
                if !isImage, let url = URL(string: address), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { out += "<a href=\"\(escape(address))\">\(content)</a>" }
                else { out += content }                                         // an image, or an address that must not run: just its words
            }
            pos = NSMaxRange(span.full); consumedUntil = pos
        }
        if pos < NSMaxRange(range) { out += escape(unescapeBackslashes(ns.substring(with: NSRange(location: pos, length: NSMaxRange(range) - pos)))) }
        return out
    }
    private static func inlineHTML(_ ns: NSString, _ line: MDLine) -> String {
        inline(ns, line.body, MarkdownScanner.spans(ns, line: line))
    }

    // MARK: blocks
    static func body(_ markdown: String) -> String {
        let ns = markdown as NSString
        let lines = MarkdownScanner.blocks(ns)
        var out = ""
        var i = 0
        var listStack: [(tag: String, indent: Int)] = []
        func closeLists(to indent: Int = -1) {
            while let top = listStack.last, top.indent > indent { out += "</li></\(top.tag)>\n"; listStack.removeLast() }
        }
        while i < lines.count {
            let line = lines[i]
            switch line.kind {
            case .blank:
                closeLists(); i += 1
            case .heading(let level):
                closeLists(); out += "<h\(level)>\(inlineHTML(ns, line))</h\(level)>\n"; i += 1
            case .rule:
                closeLists(); out += "<hr>\n"; i += 1
            case .fence(let opening):
                closeLists()
                guard opening else { i += 1; continue }
                let info = ns.substring(with: line.content).trimmingCharacters(in: CharacterSet(charactersIn: "`~ \t"))
                var j = i + 1, code: [String] = []
                while j < lines.count {
                    if case .fence(false) = lines[j].kind { break }
                    code.append(ns.substring(with: lines[j].content)); j += 1
                }
                let language = info.split(separator: " ").first.map { " class=\"language-\(escape(String($0)))\"" } ?? ""
                out += "<pre><code\(language)>\(escape(code.joined(separator: "\n")))</code></pre>\n"
                i = j + 1
            case .code:
                out += ""; i += 1
            case .bullet, .ordered, .task:
                let tag: String
                if case .ordered = line.kind { tag = "ol" } else { tag = "ul" }
                while let top = listStack.last, top.indent > line.indent || (top.indent == line.indent && top.tag != tag) {
                    out += "</li></\(top.tag)>\n"; listStack.removeLast()
                }
                if let top = listStack.last, top.indent == line.indent { out += "</li>\n" }
                else { out += "<\(tag)>\n"; listStack.append((tag, line.indent)) }
                if case .task(let checked) = line.kind { out += "<li class=\"task\">\(checked ? "☑" : "☐") \(inlineHTML(ns, line))" }
                else { out += "<li>\(inlineHTML(ns, line))" }
                i += 1
            case .quote:
                closeLists()
                var j = i, rows: [String] = []
                while j < lines.count, case .quote = lines[j].kind { rows.append(inlineHTML(ns, lines[j])); j += 1 }
                out += "<blockquote>\(rows.joined(separator: "<br>\n"))</blockquote>\n"
                i = j
            case .tableRow, .tableSeparator:
                closeLists()
                var j = i, rows: [MDLine] = []
                while j < lines.count, lines[j].kind == .tableRow || lines[j].kind == .tableSeparator { rows.append(lines[j]); j += 1 }
                func cells(_ l: MDLine) -> [String] {
                    var parts = ns.substring(with: l.content).trimmingCharacters(in: .whitespaces).components(separatedBy: "|")
                    if parts.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { parts.removeFirst() }
                    if parts.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { parts.removeLast() }
                    return parts.map { escape(unescapeBackslashes($0.trimmingCharacters(in: .whitespaces))) }
                }
                let hasHeader = rows.count > 1 && rows[1].kind == .tableSeparator
                out += "<table>\n"
                for (n, row) in rows.enumerated() where row.kind == .tableRow {
                    let tag = hasHeader && n == 0 ? "th" : "td"
                    out += "<tr>" + cells(row).map { "<\(tag)>\($0)</\(tag)>" }.joined() + "</tr>\n"
                }
                out += "</table>\n"
                i = j
            case .paragraph:
                closeLists()
                var j = i, rows: [String] = []
                while j < lines.count, lines[j].kind == .paragraph { rows.append(inlineHTML(ns, lines[j])); j += 1 }
                out += "<p>\(rows.joined(separator: "<br>\n"))</p>\n"
                i = j
            }
        }
        closeLists()
        return out
    }
}
