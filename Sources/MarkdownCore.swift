import Foundation

// ============================================================================
// MarkdownCore — Jot's Markdown understanding, as pure Foundation code (no AppKit), so the tests can
// pin it down. Everything is expressed in UTF-16 `NSRange`s over the ORIGINAL text, because that is
// what NSTextView speaks; the text itself is never rewritten by the scanner.
//
//   MarkdownScanner.blocks(_:)  one MDLine per line: heading / list / task / quote / rule / fence / …,
//                               with the block marker and body ranges (fence state carried line to line)
//   MarkdownScanner.spans(…)    inline spans inside a line's body: strong, emphasis, strike, code, links
//   MarkdownEdit                what the formatting buttons and Return/Delete do (see MarkdownEdit.swift)
//
// The inline parser follows CommonMark's delimiter-run rules (left/right flanking, `_` not opening inside
// a word) rather than regexes: `snake_case_word` and `2 * 3 * 4` are plain text, `***x***` is emphasis
// around strong, and the work is linear in the line length — no catastrophic backtracking on a 50 KB line.
// ============================================================================

enum MDInlineKind: Equatable { case strong, emphasis, strike, code, link }

struct MDSpan: Equatable {
    var kind: MDInlineKind
    var full: NSRange          // open marker … close marker
    var open: NSRange          // `**`, `*`, `~~`, a backtick run, or `[` (`![` for an image)
    var close: NSRange         // the matching marker; for a link `](url)`
    var content: NSRange       // between the markers (a link's visible text)
    var url: NSRange? = nil    // links only: the destination inside the parentheses
}

struct MDLine: Equatable {
    enum Kind: Equatable {
        case blank, paragraph
        case heading(Int)
        case bullet
        case ordered(Int)
        case task(checked: Bool)
        case quote(depth: Int)
        case rule
        case fence(opening: Bool)
        case code                  // inside a fenced block
        case tableRow, tableSeparator
    }
    var kind: Kind
    var range: NSRange             // the whole line including its terminator
    var content: NSRange           // the line without its terminator
    var marker: NSRange            // block marker with its trailing whitespace ("## ", "- [ ] ", "> ", "1. "); zero length if none
    var body: NSRange              // what follows the marker: the area inline scanning sees
    var indent: Int                // leading whitespace in columns (a tab counts 4)
    var checkbox: NSRange?         // tasks: the "[ ]" / "[x]"
    var bodyColumn: Int            // column where the body starts (for hanging indents)

    var isListItem: Bool {
        switch kind { case .bullet, .ordered, .task: return true; default: return false }
    }
}

enum MarkdownScanner {
    // MARK: Blocks ----------------------------------------------------------------------------------------------

    static func blocks(_ text: NSString) -> [MDLine] {
        var chars = [unichar](repeating: 0, count: text.length)
        if text.length > 0 { text.getCharacters(&chars, range: NSRange(location: 0, length: text.length)) }
        return blocks(chars)
    }
    static func blocks(_ text: String) -> [MDLine] { blocks(Array(text.utf16)) }

    static func blocks(_ s: [unichar]) -> [MDLine] {
        let n = s.count
        var out: [MDLine] = []
        var fence: (ch: unichar, len: Int)? = nil
        var pos = 0
        while true {
            var contentEnd = pos
            while contentEnd < n, !isBreak(s[contentEnd]) { contentEnd += 1 }
            var lineEnd = contentEnd
            if contentEnd < n { lineEnd = (s[contentEnd] == 13 && contentEnd + 1 < n && s[contentEnd + 1] == 10) ? contentEnd + 2 : contentEnd + 1 }
            out.append(classify(s, start: pos, contentEnd: contentEnd, lineEnd: lineEnd, fence: &fence))
            if lineEnd >= n {
                if contentEnd < n {   // a trailing terminator leaves one more (empty) line where the caret can sit
                    out.append(MDLine(kind: .blank, range: NSRange(location: n, length: 0), content: NSRange(location: n, length: 0),
                                      marker: NSRange(location: n, length: 0), body: NSRange(location: n, length: 0), indent: 0, checkbox: nil, bodyColumn: 0))
                }
                break
            }
            pos = lineEnd
        }
        return out
    }

    private static func isBreak(_ c: unichar) -> Bool { c == 10 || c == 13 || c == 0x2028 || c == 0x2029 || c == 0x85 }
    private static func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }

    private static func classify(_ s: [unichar], start: Int, contentEnd: Int, lineEnd: Int, fence: inout (ch: unichar, len: Int)?) -> MDLine {
        let n = contentEnd
        // Leading whitespace.
        var i = start, indent = 0
        while i < n, isSpace(s[i]) { indent += s[i] == 0x09 ? 4 : 1; i += 1 }
        let indentEnd = i
        func line(_ kind: MDLine.Kind, markerEnd: Int? = nil, checkbox: NSRange? = nil) -> MDLine {
            let m = markerEnd ?? indentEnd
            var column = 0
            var j = start
            while j < m { column += s[j] == 0x09 ? 4 : 1; j += 1 }
            return MDLine(kind: kind, range: NSRange(location: start, length: lineEnd - start), content: NSRange(location: start, length: n - start),
                          marker: NSRange(location: indentEnd, length: m - indentEnd), body: NSRange(location: m, length: n - m),
                          indent: indent, checkbox: checkbox, bodyColumn: column)
        }

        // Fenced code: ``` or ~~~ (3+), closed by the same character at least as long.
        if i < n, s[i] == 0x60 || s[i] == 0x7E {
            var run = 0
            while i + run < n, s[i + run] == s[i] { run += 1 }
            if run >= 3 {
                if let open = fence {
                    if open.ch == s[i], run >= open.len, s[(i + run)..<n].allSatisfy(isSpace) { fence = nil; return line(.fence(opening: false), markerEnd: n) }
                } else {
                    fence = (s[i], run); return line(.fence(opening: true), markerEnd: n)
                }
            }
        }
        if fence != nil { return line(.code, markerEnd: indentEnd) }

        if i >= n { return line(.blank, markerEnd: n) }   // only whitespace (or nothing)

        let first = s[i]
        // Thematic break: 3+ of - * _ separated by optional spaces, nothing else.
        if first == 0x2D || first == 0x2A || first == 0x5F {
            var count = 0, j = i, onlyRule = true
            while j < n { if s[j] == first { count += 1 } else if !isSpace(s[j]) { onlyRule = false; break }; j += 1 }
            if onlyRule, count >= 3 { return line(.rule, markerEnd: n) }
        }
        // ATX heading: 1–6 #, then a space/tab or the end of the line.
        if first == 0x23 {
            var run = 0
            while i + run < n, s[i + run] == 0x23 { run += 1 }
            if run <= 6, i + run == n || isSpace(s[i + run]) {
                var m = i + run
                while m < n, isSpace(s[m]) { m += 1 }
                return line(.heading(run), markerEnd: m)
            }
        }
        // Bullet / task: - * + then a space (or the end of the line).
        if first == 0x2D || first == 0x2A || first == 0x2B, i + 1 == n || isSpace(s[i + 1]) {
            var m = i + 1
            while m < n, isSpace(s[m]) { m += 1 }
            // Task: "[ ]" / "[x]" / "[X]", then a space or the end of the line.
            if m + 3 <= n, s[m] == 0x5B, s[m + 2] == 0x5D, s[m + 1] == 0x20 || s[m + 1] == 0x78 || s[m + 1] == 0x58,
               m + 3 == n || isSpace(s[m + 3]) {
                var end = m + 3
                while end < n, isSpace(s[end]) { end += 1 }
                return line(.task(checked: s[m + 1] != 0x20), markerEnd: end, checkbox: NSRange(location: m, length: 3))
            }
            return line(.bullet, markerEnd: m)
        }
        // Ordered: 1–9 digits, then . or ), then a space or the end.
        if first >= 0x30, first <= 0x39 {
            var j = i, value = 0
            while j < n, s[j] >= 0x30, s[j] <= 0x39, j - i < 9 { value = value * 10 + Int(s[j] - 0x30); j += 1 }
            if j < n, s[j] == 0x2E || s[j] == 0x29, j + 1 == n || isSpace(s[j + 1]) {
                var m = j + 1
                while m < n, isSpace(s[m]) { m += 1 }
                return line(.ordered(value), markerEnd: m)
            }
        }
        // Quote: one or more > (each optionally followed by one space).
        if first == 0x3E {
            var m = i, depth = 0
            while m < n, s[m] == 0x3E { depth += 1; m += 1; if m < n, s[m] == 0x20 { m += 1 } }
            return line(.quote(depth: depth), markerEnd: m)
        }
        // Table rows: the line starts with | and holds another |.
        if first == 0x7C, s[i..<n].filter({ $0 == 0x7C }).count >= 2 {
            let separator = s[i..<n].allSatisfy { $0 == 0x7C || $0 == 0x2D || $0 == 0x3A || isSpace($0) } && s[i..<n].contains(0x2D)
            return line(separator ? .tableSeparator : .tableRow, markerEnd: indentEnd)
        }
        return line(.paragraph, markerEnd: indentEnd)
    }
}

// MARK: Inline spans -----------------------------------------------------------------------------------------------

extension MarkdownScanner {
    // Inline spans in a line's body (none for blank, code, fence, rule and table-separator lines). `limit` bounds the
    // body length that is parsed at all; the work is linear in it either way.
    static func spans(_ text: NSString, line: MDLine, limit: Int = 20_000) -> [MDSpan] {
        switch line.kind {
        case .blank, .code, .fence, .rule, .tableSeparator: return []
        default: break
        }
        guard line.body.length > 0, line.body.length <= limit else { return [] }
        var chars = [unichar](repeating: 0, count: line.body.length)
        text.getCharacters(&chars, range: line.body)
        return inline(chars, base: line.body.location)
    }
    static func spans(_ text: String, line: MDLine, limit: Int = 20_000) -> [MDSpan] { spans(text as NSString, line: line, limit: limit) }

    // 0 = whitespace (or the edge of the line), 1 = punctuation/symbol, 2 = anything else (letters, digits, emoji, CJK…).
    private static func category(_ s: [unichar], _ i: Int) -> Int {
        guard i >= 0, i < s.count else { return 0 }
        let c = s[i]
        if c == 0x20 || c == 0x09 || c == 0xA0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200A) || c == 0x2028 || c == 0x2029 || c == 0x202F || c == 0x205F || c == 0x3000 { return 0 }
        if c < 0x80 { return (c >= 0x21 && c <= 0x2F) || (c >= 0x3A && c <= 0x40) || (c >= 0x5B && c <= 0x60) || (c >= 0x7B && c <= 0x7E) ? 1 : 2 }
        if c >= 0xD800 && c <= 0xDFFF { return 2 }       // half of a surrogate pair (emoji…): treated like a letter
        guard let scalar = Unicode.Scalar(UInt32(c)) else { return 2 }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation, .finalPunctuation,
             .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol: return 1
        case .spaceSeparator, .lineSeparator, .paragraphSeparator: return 0
        default: return 2
        }
    }

    static func inline(_ s: [unichar], base: Int) -> [MDSpan] {
        let n = s.count
        var spans: [MDSpan] = []
        var protected = [Bool](repeating: false, count: n)    // inside code spans and link destinations: never a delimiter
        func isEscaped(_ i: Int) -> Bool { var k = 0, j = i - 1; while j >= 0, s[j] == 0x5C { k += 1; j -= 1 }; return k % 2 == 1 }
        func at(_ r: Range<Int>) -> NSRange { NSRange(location: base + r.lowerBound, length: r.count) }

        // 1. Code spans: a backtick run closed by a run of exactly the same length.
        var i = 0
        while i < n {
            if s[i] == 0x60 {
                var run = 0
                while i + run < n, s[i + run] == 0x60 { run += 1 }
                var j = i + run, found = -1
                while j < n {
                    if s[j] == 0x60 {
                        var r2 = 0
                        while j + r2 < n, s[j + r2] == 0x60 { r2 += 1 }
                        if r2 == run { found = j; break }
                        j += r2
                    } else { j += 1 }
                }
                if found >= 0 {
                    for k in i..<(found + run) { protected[k] = true }
                    spans.append(MDSpan(kind: .code, full: at(i..<(found + run)), open: at(i..<(i + run)), close: at(found..<(found + run)), content: at((i + run)..<found)))
                    i = found + run
                } else { i += run }
            } else if s[i] == 0x5C, i + 1 < n { i += 2 }      // an escaped character can't open a code span
            else { i += 1 }
        }

        // 2. Links and images: [text](destination). The destination is protected from emphasis parsing; the text is not,
        //    but emphasis inside a link's text can only pair with other delimiters inside that same text (its own region).
        var region = [Int](repeating: -1, count: n)
        var linkCount = 0
        var k = 0
        while k < n {
            if s[k] == 0x5B, !protected[k], !isEscaped(k) {
                var depth = 0, j = k, close = -1
                while j < n {
                    if protected[j] { j += 1; continue }
                    if s[j] == 0x5C { j += 2; continue }
                    if s[j] == 0x5B { depth += 1 } else if s[j] == 0x5D { depth -= 1; if depth == 0 { close = j; break } }
                    j += 1
                }
                if close >= 0, close + 1 < n, s[close + 1] == 0x28 {
                    var parens = 0, m = close + 1, urlEnd = -1
                    while m < n {
                        if s[m] == 0x5C { m += 2; continue }
                        if s[m] == 0x28 { parens += 1 } else if s[m] == 0x29 { parens -= 1; if parens == 0 { urlEnd = m; break } }
                        m += 1
                    }
                    if urlEnd >= 0 {
                        let openStart = (k > 0 && s[k - 1] == 0x21) ? k - 1 : k        // ![alt](src)
                        spans.append(MDSpan(kind: .link, full: at(openStart..<(urlEnd + 1)), open: at(openStart..<(k + 1)),
                                            close: at(close..<(urlEnd + 1)), content: at((k + 1)..<close), url: at((close + 2)..<urlEnd)))
                        for q in (close + 2)..<urlEnd { protected[q] = true }
                        for q in (k + 1)..<close { region[q] = linkCount }
                        linkCount += 1
                        k = urlEnd + 1; continue
                    }
                }
            }
            k += 1
        }

        // 3. Emphasis, strong and strikethrough from delimiter runs (CommonMark's flanking rules).
        struct Delim { var start: Int; var count: Int; var ch: unichar; var canOpen: Bool; var canClose: Bool; var region: Int }
        var delims: [Delim] = []
        var p = 0
        while p < n {
            let c = s[p]
            if (c == 0x2A || c == 0x5F || c == 0x7E), !protected[p] {
                if isEscaped(p) { p += 1; continue }
                var run = 0
                while p + run < n, s[p + run] == c, !protected[p + run] { run += 1 }
                let before = category(s, p - 1), after = category(s, p + run)
                let left = after != 0 && (after != 1 || before == 0 || before == 1)
                let right = before != 0 && (before != 1 || after == 0 || after == 1)
                var canOpen = left, canClose = right
                if c == 0x5F { canOpen = left && (!right || before == 1); canClose = right && (!left || after == 1) }
                if c == 0x7E, run < 2 { canOpen = false; canClose = false }
                delims.append(Delim(start: p, count: run, ch: c, canOpen: canOpen, canClose: canClose, region: region[p]))
                p += run
            } else { p += 1 }
        }
        var stack: [Int] = []                                   // indices into `delims` of potential openers
        for ci in 0..<delims.count {
            var si = stack.count - 1
            while delims[ci].canClose, delims[ci].count > 0, si >= 0 {
                let oi = stack[si]
                guard delims[oi].ch == delims[ci].ch, delims[oi].count > 0, delims[oi].region == delims[ci].region else { si -= 1; continue }
                let tilde = delims[ci].ch == 0x7E
                if tilde, delims[oi].count < 2 || delims[ci].count < 2 { si -= 1; continue }
                let use = tilde ? 2 : ((delims[oi].count >= 2 && delims[ci].count >= 2) ? 2 : 1)
                let openStart = delims[oi].start + delims[oi].count - use, closeStart = delims[ci].start
                spans.append(MDSpan(kind: use == 2 ? (tilde ? .strike : .strong) : .emphasis,
                                    full: at(openStart..<(closeStart + use)), open: at(openStart..<(openStart + use)),
                                    close: at(closeStart..<(closeStart + use)), content: at((openStart + use)..<closeStart)))
                delims[oi].count -= use
                delims[ci].start += use; delims[ci].count -= use
                stack.removeSubrange((si + 1)...)                // openers between the pair can no longer match
                if delims[oi].count == 0 { stack.removeLast() }
                si = stack.count - 1
            }
            if delims[ci].canOpen, delims[ci].count > 0 { stack.append(ci) }
        }
        spans.sort { $0.full.location != $1.full.location ? $0.full.location < $1.full.location : $0.full.length > $1.full.length }
        return spans
    }
}

// MARK: Plain text ------------------------------------------------------------------------------------------------------

// A note's words without its Markdown: what the header, the sidebar rows and Save As show. One rule everywhere.
enum MarkdownPlain {
    // A line's text with its block marker (`## `, `- [ ] `, `> `) and inline markers (`**`, `~~`, backticks, link/image syntax) removed.
    static func plain(line text: String) -> String {
        let ns = text as NSString
        guard let line = MarkdownScanner.blocks(ns).first else { return "" }
        let body = line.body
        var skip: [NSRange] = []
        for span in MarkdownScanner.spans(ns, line: line) { skip.append(span.open); skip.append(span.close) }
        skip.sort { $0.location < $1.location }
        var out = "", cursor = body.location
        for r in skip where r.location >= cursor && NSMaxRange(r) <= NSMaxRange(body) {
            out += ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
            cursor = NSMaxRange(r)
        }
        if cursor < NSMaxRange(body) { out += ns.substring(with: NSRange(location: cursor, length: NSMaxRange(body) - cursor)) }
        return out.trimmingCharacters(in: .whitespaces)
    }

    // The first line that has words in it, as plain text, capped at `limit` characters; "New Note" when there is none.
    // Stops at the first hit, so a 200 KB note costs no more than a short one.
    static func title(_ text: String, limit: Int = 80) -> String {
        var found: String?
        text.enumerateLines { raw, stop in
            switch MarkdownScanner.blocks(raw).first?.kind {
            case .some(.fence), .some(.rule), .some(.tableSeparator), .some(.blank), .none: return
            default: break
            }
            let words = plain(line: raw)
            if !words.isEmpty { found = String(words.prefix(limit)); stop = true }
        }
        return found ?? "New Note"
    }

    // The line after the title line, as plain text: what a sidebar row shows under the title. Empty when the note has one line.
    // Fenced code counts as text (its fence lines don't); stops at the first hit like `title`.
    static func snippet(_ text: String, limit: Int = 100) -> String {
        var seenTitle = false
        var found = ""
        text.enumerateLines { raw, stop in
            switch MarkdownScanner.blocks(raw).first?.kind {
            case .some(.fence), .some(.rule), .some(.tableSeparator), .some(.blank), .none: return
            default: break
            }
            let words = plain(line: raw)
            if words.isEmpty { return }
            if !seenTitle { seenTitle = true; return }
            found = String(words.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ").prefix(limit)); stop = true
        }
        return found
    }
}
