import Foundation

// ============================================================================
// MarkdownEdit — what the formatting buttons, shortcuts, Return and Delete do to the text.
// Pure Foundation: every function takes the text and a selection and returns ONE replace
// (`TextEdit`), so applying it is a single undo step, or nil when there is nothing to do.
// All offsets are UTF-16 over the ORIGINAL text. Built on MarkdownScanner (MarkdownCore.swift).
// ============================================================================

struct TextEdit: Equatable {
    var range: NSRange          // in the original text
    var replacement: String
    var selection: NSRange      // the selection AFTER the edit, in the new text
    func applied(to text: String) -> String { (text as NSString).replacingCharacters(in: range, with: replacement) }
}

enum InlineStyle {
    case strong, emphasis, strike, code
    var marker: String {
        switch self { case .strong: return "**"; case .emphasis: return "*"; case .strike: return "~~"; case .code: return "`" }
    }
    var kind: MDInlineKind {
        switch self { case .strong: return .strong; case .emphasis: return .emphasis; case .strike: return .strike; case .code: return .code }
    }
}

enum BlockStyle: Equatable { case heading(Int), body, bullet, ordered, task, quote }

struct FormatState: Equatable {
    var strong = false, emphasis = false, strike = false, code = false, link = false
    var block: BlockStyle? = nil     // heading / bullet / ordered / task, or nil for a plain paragraph
    var quote = false                // the line sits inside a block quote
    var codeBlock = false            // the line is part of a fenced code block (fences included)
}

enum MarkdownEdit {
    // MARK: Line helpers ------------------------------------------------------------------------------------------

    // The line that holds an offset. A caret at the end of a line's content belongs to that line; the very end of the text
    // belongs to the last line (which is an empty one when the text ends with a newline).
    private static func lineIndex(_ offset: Int, _ lines: [MDLine]) -> Int {
        for (i, line) in lines.enumerated() where offset < NSMaxRange(line.range) { return i }
        return lines.count - 1
    }
    // The lines a selection touches. A selection that ends right after a newline does not include the next line.
    private static func targetLines(_ sel: NSRange, _ lines: [MDLine]) -> [Int] {
        let first = lineIndex(sel.location, lines)
        let last = lineIndex(sel.length > 0 ? NSMaxRange(sel) - 1 : sel.location, lines)
        return Array(first...max(first, last))
    }
    private static func acceptsInline(_ kind: MDLine.Kind) -> Bool {
        switch kind {
        case .blank, .rule, .fence, .code, .tableSeparator: return false
        default: return true
        }
    }
    private static func acceptsBlock(_ kind: MDLine.Kind) -> Bool {
        switch kind {
        case .rule, .fence, .code, .tableRow, .tableSeparator: return false
        default: return true
        }
    }
    private static func isWhitespace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 || c == 0xA0 }

    // A line's block as seen after any quote prefix: `> - item` is a quote whose inner block is a bullet.
    private struct Inner {
        var prefix: NSRange        // indentation + quote markers, absolute (empty when the line isn't a quote)
        var line: MDLine           // the inner block, ranges absolute
    }
    private static func inner(_ ns: NSString, _ line: MDLine) -> Inner {
        guard case .quote = line.kind else { return Inner(prefix: NSRange(location: line.content.location, length: 0), line: line) }
        let remainder = ns.substring(with: line.body)
        var inner = MarkdownScanner.blocks(remainder)[0]
        let shift = line.body.location
        inner.range.location += shift; inner.content.location += shift; inner.marker.location += shift; inner.body.location += shift
        if let box = inner.checkbox { inner.checkbox = NSRange(location: box.location + shift, length: box.length) }
        return Inner(prefix: NSRange(location: line.content.location, length: line.body.location - line.content.location), line: inner)
    }
    private static func blockStyle(_ kind: MDLine.Kind) -> BlockStyle? {
        switch kind {
        case .heading(let n): return .heading(n)
        case .bullet: return .bullet
        case .ordered: return .ordered
        case .task: return .task
        default: return nil
        }
    }

    // MARK: Words and trimming ------------------------------------------------------------------------------------

    private static func isWordUnit(_ ns: NSString, _ i: Int) -> Bool {
        let c = ns.character(at: i)
        if c >= 0xD800 && c <= 0xDFFF { return true }                         // emoji and other non-BMP: part of the word
        if c == 0x5F { return true }
        if let scalar = Unicode.Scalar(UInt32(c)), CharacterSet.alphanumerics.contains(scalar) { return true }
        if c == 0x27 || c == 0x2019, i > 0, i + 1 < ns.length {                // an apostrophe between letters (don't)
            let a = ns.character(at: i - 1), b = ns.character(at: i + 1)
            func letter(_ u: unichar) -> Bool { Unicode.Scalar(UInt32(u)).map { CharacterSet.alphanumerics.contains($0) } ?? false }
            return letter(a) && letter(b)
        }
        return false
    }
    private static func wordRange(_ ns: NSString, at c: Int, within body: NSRange) -> NSRange? {
        func word(_ i: Int) -> Bool { i >= body.location && i < NSMaxRange(body) && isWordUnit(ns, i) }
        guard word(c - 1) || word(c) else { return nil }
        var s = c, e = c
        while word(s - 1) { s -= 1 }
        while word(e) { e += 1 }
        return NSRange(location: s, length: e - s)
    }
    private static func trimmed(_ r: NSRange, _ ns: NSString) -> NSRange {
        var s = r.location, e = NSMaxRange(r)
        while s < e, isWhitespace(ns.character(at: s)) { s += 1 }
        while e > s, isWhitespace(ns.character(at: e - 1)) { e -= 1 }
        return NSRange(location: s, length: e - s)
    }

    // MARK: Inline toggle -----------------------------------------------------------------------------------------

    static func toggleInline(_ style: InlineStyle, in text: String, selection: NSRange) -> TextEdit? {
        let ns = text as NSString
        let lines = MarkdownScanner.blocks(ns)
        var sel = selection
        if sel.length == 0 {
            let line = lines[lineIndex(sel.location, lines)]
            guard acceptsInline(line.kind) else { return nil }
            let spans = MarkdownScanner.spans(ns, line: line).filter { $0.kind == style.kind }
            // Inside (or touching) a span of this style: unwrap it, the caret staying on its text.
            if let hit = spans.filter({ $0.full.location <= sel.location && sel.location <= NSMaxRange($0.full) }).min(by: { $0.full.length < $1.full.length }) {
                let caret = hit.full.location + min(max(sel.location - hit.content.location, 0), hit.content.length)
                return TextEdit(range: hit.full, replacement: ns.substring(with: hit.content), selection: NSRange(location: caret, length: 0))
            }
            if let word = wordRange(ns, at: sel.location, within: line.body) { sel = word }     // on a word: format the word
            else {                                                                                // between words: an empty pair
                let m = style.marker
                return TextEdit(range: NSRange(location: sel.location, length: 0), replacement: m + m,
                                selection: NSRange(location: sel.location + m.utf16.count, length: 0))
            }
        }
        return toggleInline(style, ns: ns, lines: lines, selection: sel)
    }

    private struct Op { var range: NSRange; var text: String }

    private static func toggleInline(_ style: InlineStyle, ns: NSString, lines: [MDLine], selection sel: NSRange) -> TextEdit? {
        struct Segment { var line: MDLine; var range: NSRange; var spans: [MDSpan]; var all: [MDSpan]; var container: MDSpan? }
        var segments: [Segment] = []
        for li in targetLines(sel, lines) {
            let line = lines[li]
            guard acceptsInline(line.kind) else { continue }
            let seg = trimmed(NSIntersectionRange(sel, line.body), ns)
            guard seg.length > 0 else { continue }
            let all = MarkdownScanner.spans(ns, line: line)
            let same = all.filter { $0.kind == style.kind }
            let container = same.filter { seg.location >= $0.full.location && NSMaxRange(seg) <= NSMaxRange($0.full) }.min { $0.full.length < $1.full.length }
            segments.append(Segment(line: line, range: seg, spans: same, all: all, container: container))
        }
        guard !segments.isEmpty else { return nil }
        let marker = style.marker
        let markerLength = marker.utf16.count
        var ops: [Op] = []

        if segments.allSatisfy({ $0.container != nil }) {
            // ---- every line is already in this style: toggle it OFF -----------------------------------------------
            for seg in segments {
                let c = seg.container!
                // Characters that are another span's markup don't count as text when deciding what's left of the span.
                var markup = Set<Int>()
                for sp in seg.all { for r in [sp.open, sp.close] { for k in r.location..<NSMaxRange(r) { markup.insert(k) } } }
                func isText(_ i: Int) -> Bool { !isWhitespace(ns.character(at: i)) && !markup.contains(i) }
                let textRange = (c.content.location..<NSMaxRange(c.content)).filter(isText)
                let covers = textRange.isEmpty || (seg.range.location <= textRange.first! && NSMaxRange(seg.range) > textRange.last!)
                if covers {
                    ops.append(Op(range: c.open, text: "")); ops.append(Op(range: c.close, text: ""))
                } else {
                    // Split the span around the selection: close it before, reopen it after (or drop a marker when nothing is left).
                    // A selection that starts inside the opening marker (or ends inside the closing one) has no text on that side.
                    let beforeEnd = max(c.content.location, min(seg.range.location, NSMaxRange(c.content)))
                    let afterStart = min(NSMaxRange(c.content), max(NSMaxRange(seg.range), c.content.location))
                    let before = (c.content.location..<beforeEnd).filter(isText).last
                    let after = (afterStart..<NSMaxRange(c.content)).filter(isText).first
                    if let b = before { ops.append(Op(range: NSRange(location: b + 1, length: 0), text: marker)) } else { ops.append(Op(range: c.open, text: "")) }
                    if let a = after { ops.append(Op(range: NSRange(location: a, length: 0), text: marker)) } else { ops.append(Op(range: c.close, text: "")) }
                }
            }
            let (edit, map) = compose(ops, ns)
            let first = segments.first!.range, last = segments.last!.range
            return TextEdit(range: edit.range, replacement: edit.replacement,
                            selection: NSRange(location: map.start(first.location), length: map.end(NSMaxRange(last)) - map.start(first.location)))
        }

        // ---- ON: wrap each line's selection, absorbing same-style spans it touches ---------------------------------------
        var innerPositions: [(op: Int, inner: Int)] = []            // for each op: where the inner text starts and its length
        for seg in segments {
            var whole = seg.range
            for sp in seg.spans where NSIntersectionRange(sp.full, seg.range).length > 0 { whole = NSUnionRange(whole, sp.full) }
            var inner = ""
            var cursor = whole.location
            let contained = seg.spans.filter { $0.full.location >= whole.location && NSMaxRange($0.full) <= NSMaxRange(whole) }
            for sp in contained {
                inner += ns.substring(with: NSRange(location: cursor, length: sp.open.location - cursor)) + ns.substring(with: sp.content)
                cursor = NSMaxRange(sp.close)
            }
            inner += ns.substring(with: NSRange(location: cursor, length: NSMaxRange(whole) - cursor))
            ops.append(Op(range: whole, text: marker + inner + marker))
            innerPositions.append((ops.count - 1, inner.utf16.count))
        }
        let (edit, _) = compose(ops, ns)
        var delta = 0
        var innerStart = 0, innerEnd = 0
        for (i, op) in ops.enumerated() {
            let newStart = op.range.location + delta
            if i == 0 { innerStart = newStart + markerLength }
            if i == ops.count - 1 { innerEnd = newStart + markerLength + innerPositions[i].inner }
            delta += op.text.utf16.count - op.range.length
        }
        return TextEdit(range: edit.range, replacement: edit.replacement, selection: NSRange(location: innerStart, length: innerEnd - innerStart))
    }

    // Combines non-overlapping ops into one replace over their hull, plus a mapper from old offsets to new ones.
    private struct OffsetMap {
        var ops: [Op]      // sorted by location
        // A selection start counts an insert exactly at it (the insert lands before the text); an end does not.
        // An offset inside a removed range collapses to the point where that range was.
        private func map(_ x: Int, start: Bool) -> Int {
            var shift = 0
            for op in ops {
                if op.range.length == 0 {
                    guard start ? op.range.location <= x : op.range.location < x else { break }
                    shift += op.text.utf16.count
                } else if NSMaxRange(op.range) <= x {
                    shift += op.text.utf16.count - op.range.length
                } else if op.range.location < x {
                    return op.range.location + shift
                } else { break }
            }
            return x + shift
        }
        func start(_ x: Int) -> Int { map(x, start: true) }
        func end(_ x: Int) -> Int { map(x, start: false) }
    }
    private static func compose(_ raw: [Op], _ ns: NSString) -> (TextEdit, OffsetMap) {
        let ops = raw.sorted { $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length < $1.range.length }
        let start = ops.first!.range.location
        let end = ops.map { NSMaxRange($0.range) }.max()!
        var text = "", cursor = start
        for op in ops {
            text += ns.substring(with: NSRange(location: cursor, length: op.range.location - cursor)) + op.text
            cursor = NSMaxRange(op.range)
        }
        text += ns.substring(with: NSRange(location: cursor, length: end - cursor))
        return (TextEdit(range: NSRange(location: start, length: end - start), replacement: text, selection: NSRange(location: 0, length: 0)), OffsetMap(ops: ops))
    }

    // MARK: Block styles ------------------------------------------------------------------------------------------

    static func setBlock(_ style: BlockStyle, in text: String, selection: NSRange) -> TextEdit? {
        let ns = text as NSString
        let lines = MarkdownScanner.blocks(ns)
        var targets = targetLines(selection, lines)
        let onlyBlank = targets.count == 1 && lines[targets[0]].kind == .blank
        targets = targets.filter { acceptsBlock(lines[$0].kind) && (lines[$0].kind != .blank || onlyBlank) }
        guard !targets.isEmpty else { return nil }

        struct Parts { var index: Int; var prefix: String; var indent: String; var marker: String; var body: String; var kind: MDLine.Kind; var quoted: Bool; var bodyStartOld: Int }
        var parts: [Parts] = []
        for li in targets {
            let line = lines[li]
            let x = inner(ns, line)
            let prefix = ns.substring(with: x.prefix)
            let indent = ns.substring(with: NSRange(location: x.line.content.location, length: x.line.marker.location - x.line.content.location))
            let marker: String
            switch x.line.kind {
            case .paragraph, .blank: marker = ""
            default: marker = ns.substring(with: x.line.marker)
            }
            let bodyRange = NSRange(location: NSMaxRange(x.line.marker), length: NSMaxRange(x.line.content) - NSMaxRange(x.line.marker))
            let isQuote: Bool; if case .quote = line.kind { isQuote = true } else { isQuote = false }
            parts.append(Parts(index: li, prefix: prefix, indent: indent, marker: marker,
                               body: x.line.kind == .paragraph || x.line.kind == .blank ? ns.substring(with: NSRange(location: x.line.marker.location, length: NSMaxRange(x.line.content) - x.line.marker.location)) : ns.substring(with: bodyRange),
                               kind: x.line.kind, quoted: isQuote, bodyStartOld: NSMaxRange(x.line.marker)))
        }

        var rebuilt: [Int: String] = [:]
        func kindIs(_ p: Parts, _ test: (MDLine.Kind) -> Bool) -> Bool { test(p.kind) }
        switch style {
        case .quote:
            let allQuoted = parts.allSatisfy { $0.quoted }
            for p in parts {
                let line = lines[p.index]
                let original = ns.substring(with: line.content)
                if allQuoted {
                    // Remove one level: the first ">" and the space after it.
                    var s = original
                    if let gt = s.firstIndex(of: ">") {
                        var end = s.index(after: gt)
                        if end < s.endIndex, s[end] == " " { end = s.index(after: end) }
                        s.removeSubrange(gt..<end)
                    }
                    rebuilt[p.index] = s
                } else if p.quoted {
                    rebuilt[p.index] = original
                } else {
                    rebuilt[p.index] = "> " + original
                }
            }
        case .heading(let level):
            let allSame = parts.allSatisfy { $0.kind == .heading(level) }
            for p in parts { rebuilt[p.index] = p.prefix + (allSame ? "" : String(repeating: "#", count: level) + " ") + p.body }
        case .body:
            for p in parts { rebuilt[p.index] = p.prefix + p.indent + p.body }
        case .bullet:
            let allSame = parts.allSatisfy { $0.kind == .bullet }
            for p in parts {
                let keepIndent: String; if case .heading = p.kind { keepIndent = "" } else { keepIndent = p.indent }
                rebuilt[p.index] = p.prefix + keepIndent + (allSame ? "" : "- ") + p.body
            }
        case .task:
            let allSame = parts.allSatisfy { if case .task = $0.kind { return true }; return false }
            for p in parts {
                if case .task = p.kind, !allSame { rebuilt[p.index] = p.prefix + p.indent + p.marker + p.body; continue }
                let keepIndent: String; if case .heading = p.kind { keepIndent = "" } else { keepIndent = p.indent }
                rebuilt[p.index] = p.prefix + keepIndent + (allSame ? "" : "- [ ] ") + p.body
            }
        case .ordered:
            let allSame = parts.allSatisfy { if case .ordered = $0.kind { return true }; return false }
            var number = 1
            if case .ordered(let n) = parts[0].kind { number = n }
            for p in parts {
                let keepIndent: String; if case .heading = p.kind { keepIndent = "" } else { keepIndent = p.indent }
                if allSame { rebuilt[p.index] = p.prefix + keepIndent + p.body }
                else { rebuilt[p.index] = p.prefix + keepIndent + "\(number). " + p.body; number += 1 }
            }
        }

        // One replace over the lines from the first to the last changed one; lines between that weren't touched stay as they were.
        let firstIndex = parts.first!.index, lastIndex = parts.last!.index
        var newText = ""
        var deltaBefore: [Int: Int] = [:]          // old line index → characters added before it
        var running = 0
        for li in firstIndex...lastIndex {
            deltaBefore[li] = running
            let line = lines[li]
            let terminator = ns.substring(with: NSRange(location: NSMaxRange(line.content), length: NSMaxRange(line.range) - NSMaxRange(line.content)))
            if let replaced = rebuilt[li] {
                newText += replaced + terminator
                running += replaced.utf16.count - line.content.length
            } else {
                newText += ns.substring(with: line.range)
            }
        }
        let range = NSRange(location: lines[firstIndex].range.location, length: NSMaxRange(lines[lastIndex].range) - lines[firstIndex].range.location)

        // Map a position: within a changed line, a position at or after the body shifts by the marker change; one inside the marker clamps.
        func map(_ p: Int) -> Int {
            var shift = 0
            for part in parts {
                let line = lines[part.index]
                let newLength = (rebuilt[part.index] ?? "").utf16.count
                let change = newLength - line.content.length
                if p >= NSMaxRange(line.range) { shift += change; continue }
                if p >= line.content.location {
                    let newBodyStart = newLength - part.body.utf16.count
                    let oldBodyStart = part.bodyStartOld - line.content.location
                    let col = p - line.content.location
                    let newCol = col >= oldBodyStart ? col - oldBodyStart + newBodyStart : min(col, newBodyStart)
                    return line.content.location + shift + newCol
                }
                break
            }
            return p + shift
        }
        let a = map(selection.location)
        let b = selection.length > 0 ? map(NSMaxRange(selection)) : a
        return TextEdit(range: range, replacement: newText, selection: NSRange(location: a, length: max(b - a, 0)))
    }

    // MARK: Return and Backspace ----------------------------------------------------------------------------------

    // Return in a list item or quote: continue it, split it, end it, or outdent an empty nested item.
    // nil → let the text view insert an ordinary newline.
    static func continueList(in text: String, caret c: Int) -> TextEdit? {
        let ns = text as NSString
        let lines = MarkdownScanner.blocks(ns)
        let line = lines[lineIndex(c, lines)]
        guard c >= line.content.location, c <= NSMaxRange(line.content) else { return nil }
        let x = inner(ns, line)
        let prefix = ns.substring(with: x.prefix)
        let isQuote: Bool; if case .quote = line.kind { isQuote = true } else { isQuote = false }
        let innerLine = x.line
        let marker = innerLine.marker
        let bodyStart = NSMaxRange(marker)

        switch innerLine.kind {
        case .bullet, .ordered, .task:
            let indentText = ns.substring(with: NSRange(location: innerLine.content.location, length: marker.location - innerLine.content.location))
            let hasBody = trimmed(NSRange(location: bodyStart, length: max(0, NSMaxRange(innerLine.content) - bodyStart)), ns).length > 0
            if c < bodyStart {                                    // before the text: an empty line goes ABOVE the item
                return TextEdit(range: NSRange(location: line.content.location, length: 0), replacement: "\n", selection: NSRange(location: c + 1, length: 0))
            }
            if !hasBody {
                if innerLine.indent >= 2 {                        // an empty nested item moves out one level
                    let outdented = String(indentText.dropFirst(min(2, indentText.count)))
                    let markerText = ns.substring(with: marker)
                    let replacement = prefix + outdented + markerText
                    return TextEdit(range: line.content, replacement: replacement, selection: NSRange(location: line.content.location + replacement.utf16.count, length: 0))
                }
                // An empty top-level item ends the list: the marker goes, the (possibly quoted) empty line stays.
                return TextEdit(range: line.content, replacement: prefix, selection: NSRange(location: line.content.location + prefix.utf16.count, length: 0))
            }
            let markerText = ns.substring(with: marker)
            let next: String
            switch innerLine.kind {
            case .ordered(let n):
                let delimiter = markerText.first(where: { $0 == "." || $0 == ")" }) ?? "."
                next = "\(n + 1)\(delimiter) "
            case .task:
                let bullet = markerText.first(where: { $0 == "-" || $0 == "*" || $0 == "+" }) ?? "-"
                next = "\(bullet) [ ] "
            default:
                let bullet = markerText.first(where: { $0 == "-" || $0 == "*" || $0 == "+" }) ?? "-"
                next = "\(bullet) "
            }
            let insert = "\n" + prefix + indentText + next
            return TextEdit(range: NSRange(location: c, length: 0), replacement: insert, selection: NSRange(location: c + insert.utf16.count, length: 0))
        default:
            guard isQuote else { return nil }
            let bodyEmpty = trimmed(NSRange(location: bodyStart, length: max(0, NSMaxRange(innerLine.content) - bodyStart)), ns).length == 0
            if bodyEmpty, c >= bodyStart {                         // an empty quote line ends the quote
                return TextEdit(range: line.content, replacement: "", selection: NSRange(location: line.content.location, length: 0))
            }
            let insert = "\n" + prefix
            return TextEdit(range: NSRange(location: c, length: 0), replacement: insert, selection: NSRange(location: c + insert.utf16.count, length: 0))
        }
    }

    // Backspace with the caret right after a block marker removes the marker (the line becomes plain text)
    // instead of eating one character of it. nil → an ordinary Backspace.
    static func backspaceMarker(in text: String, caret c: Int) -> TextEdit? {
        let ns = text as NSString
        let lines = MarkdownScanner.blocks(ns)
        let line = lines[lineIndex(c, lines)]
        let x = inner(ns, line)
        let isQuote: Bool; if case .quote = line.kind { isQuote = true } else { isQuote = false }
        switch x.line.kind {
        case .bullet, .ordered, .task, .heading:
            guard c == NSMaxRange(x.line.marker), c > line.content.location else { return nil }
            let removeFrom = isQuote ? x.line.content.location : line.content.location        // keep the quote prefix; drop the indent otherwise
            return TextEdit(range: NSRange(location: removeFrom, length: c - removeFrom), replacement: "", selection: NSRange(location: removeFrom, length: 0))
        default:
            guard isQuote, c == NSMaxRange(line.marker), c > line.content.location else { return nil }
            return TextEdit(range: NSRange(location: line.content.location, length: c - line.content.location), replacement: "", selection: NSRange(location: line.content.location, length: 0))
        }
    }

    // MARK: Indent ------------------------------------------------------------------------------------------------

    static func indent(outdent: Bool, in text: String, selection: NSRange) -> TextEdit? {
        let ns = text as NSString
        let lines = MarkdownScanner.blocks(ns)
        let targets = targetLines(selection, lines).filter { lines[$0].kind != .blank }
        guard !targets.isEmpty else { return nil }
        var changes: [(index: Int, delta: Int, text: String)] = []
        for li in targets {
            let line = lines[li]
            let content = ns.substring(with: line.content)
            if !outdent { changes.append((li, 2, "  " + content)); continue }
            var removed = 0
            if content.hasPrefix("\t") { removed = 1 } else if content.hasPrefix("  ") { removed = 2 } else if content.hasPrefix(" ") { removed = 1 }
            if removed > 0 { changes.append((li, -removed, String(content.dropFirst(removed)))) }
        }
        guard !changes.isEmpty else { return nil }
        let firstIndex = changes.first!.index, lastIndex = changes.last!.index
        var newText = ""
        for li in firstIndex...lastIndex {
            let line = lines[li]
            if let c = changes.first(where: { $0.index == li }) {
                newText += c.text + ns.substring(with: NSRange(location: NSMaxRange(line.content), length: NSMaxRange(line.range) - NSMaxRange(line.content)))
            } else { newText += ns.substring(with: line.range) }
        }
        let range = NSRange(location: lines[firstIndex].range.location, length: NSMaxRange(lines[lastIndex].range) - lines[firstIndex].range.location)
        // A position at the start of a changed line stays there (so a selection of whole lines keeps the new indent); later ones shift.
        func map(_ p: Int) -> Int {
            var shift = 0
            for ch in changes {
                let line = lines[ch.index]
                if p > line.content.location + 0 && p >= NSMaxRange(line.range) { shift += ch.delta; continue }
                if p > line.content.location { return max(line.content.location + shift, p + shift + ch.delta) }
                break
            }
            return p + shift
        }
        let a = map(selection.location)
        let b = selection.length > 0 ? map(NSMaxRange(selection)) : a
        return TextEdit(range: range, replacement: newText, selection: NSRange(location: a, length: max(b - a, 0)))
    }

    // MARK: State (toolbar highlighting) -------------------------------------------------------------------------

    static func state(in text: String, selection: NSRange) -> FormatState {
        let ns = text as NSString
        let lines = MarkdownScanner.blocks(ns)
        let line = lines[lineIndex(selection.location, lines)]
        var st = FormatState()
        if case .quote = line.kind { st.quote = true; st.block = blockStyle(inner(ns, line).line.kind) } else { st.block = blockStyle(line.kind) }
        switch line.kind { case .code, .fence: st.codeBlock = true; default: break }
        guard acceptsInline(line.kind) else { return st }
        let spans = MarkdownScanner.spans(ns, line: line)
        func active(_ kind: MDInlineKind) -> Bool {
            spans.contains {
                $0.kind == kind && (selection.length == 0
                    ? $0.full.location <= selection.location && selection.location <= NSMaxRange($0.full)
                    : selection.location >= $0.full.location && NSMaxRange(selection) <= NSMaxRange($0.full))
            }
        }
        st.strong = active(.strong); st.emphasis = active(.emphasis); st.strike = active(.strike); st.code = active(.code); st.link = active(.link)
        return st
    }
}

// MARK: Link, divider, table, code block ---------------------------------------------------------------------------

extension MarkdownEdit {
    private static func looksLikeURL(_ s: String) -> Bool {
        let t = s.lowercased()
        return (t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("mailto:") || t.hasPrefix("www.")) && !t.contains(" ")
    }

    // The Link button toggles. Inside a link: back to its plain text. Otherwise the selection (or the word at the caret)
    // becomes `[text](url)` with `url` selected, ready to be typed over; a selection that already IS a URL becomes `[](url)`
    // with the caret in the label; a caret between words inserts `[]()`. `url` supplies the destination (say, from the
    // pasteboard) — the caret then lands after the link. nil when the selection spans lines or can't hold a link.
    static func toggleLink(in text: String, selection: NSRange, url: String? = nil) -> TextEdit? {
        let ns = text as NSString
        let lines = MarkdownScanner.blocks(ns)
        let first = lineIndex(selection.location, lines)
        let last = lineIndex(selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location, lines)
        guard first == last, acceptsInline(lines[first].kind) else { return nil }
        let line = lines[first]
        let links = MarkdownScanner.spans(ns, line: line).filter { $0.kind == .link }
        let inside = links.filter {
            selection.length == 0 ? $0.full.location <= selection.location && selection.location <= NSMaxRange($0.full)
                                  : selection.location >= $0.full.location && NSMaxRange(selection) <= NSMaxRange($0.full)
        }.min { $0.full.length < $1.full.length }
        if let link = inside {
            return TextEdit(range: link.full, replacement: ns.substring(with: link.content),
                            selection: NSRange(location: link.full.location, length: link.content.length))
        }
        var target = selection
        if target.length == 0 {
            guard let word = wordRange(ns, at: selection.location, within: line.body) else {
                return TextEdit(range: NSRange(location: selection.location, length: 0), replacement: "[]()",
                                selection: NSRange(location: selection.location + 1, length: 0))
            }
            target = word
        } else {
            target = trimmed(NSIntersectionRange(target, line.body), ns)
            guard target.length > 0 else { return nil }
        }
        let label = ns.substring(with: target)
        if looksLikeURL(label) {
            return TextEdit(range: target, replacement: "[](\(label))", selection: NSRange(location: target.location + 1, length: 0))
        }
        let destination = url ?? "url"
        let replacement = "[\(label)](\(destination))"
        let after = url == nil
            ? NSRange(location: target.location + 1 + label.utf16.count + 2, length: destination.utf16.count)
            : NSRange(location: target.location + replacement.utf16.count, length: 0)
        return TextEdit(range: target, replacement: replacement, selection: after)
    }

    // Puts `block` (no trailing newline) on its own lines below the caret's line, separated from what's above by a blank line
    // (a `---` straight under a paragraph would turn it into a heading) — on an empty line it simply takes that line's place.
    // `blankAfter` also keeps a blank line before whatever follows (a table swallows the next text line otherwise).
    private static func insertBlock(_ block: String, selecting: NSRange?, blankAfter: Bool, in ns: NSString, caret: Int) -> TextEdit {
        let lines = MarkdownScanner.blocks(ns)
        let index = lineIndex(caret, lines)
        let line = lines[index]
        let isBlank = line.kind == .blank
        let previousBlank = index == 0 || lines[index - 1].kind == .blank
        var prefix = "", at = NSMaxRange(line.content), length = 0
        if !isBlank { prefix = "\n\n" }
        else if previousBlank { at = line.content.location; length = line.content.length }
        else { prefix = "\n" }
        let hasNext = index + 1 < lines.count
        var suffix = ""
        if !hasNext { suffix = "\n" } else if blankAfter, lines[index + 1].kind != .blank { suffix = "\n" }
        let blockStart = at + prefix.utf16.count
        let blockEnd = blockStart + block.utf16.count
        let terminator = NSMaxRange(line.range) - NSMaxRange(line.content)
        let selection: NSRange
        if let inner = selecting { selection = NSRange(location: blockStart + inner.location, length: inner.length) }
        else { selection = NSRange(location: blockEnd + (suffix.isEmpty ? terminator : 1), length: 0) }
        return TextEdit(range: NSRange(location: at, length: length), replacement: prefix + block + suffix, selection: selection)
    }

    static func insertDivider(in text: String, caret: Int) -> TextEdit {
        insertBlock("---", selecting: nil, blankAfter: false, in: text as NSString, caret: caret)
    }

    static func insertTable(in text: String, caret: Int) -> TextEdit {
        let block = "| Col1 | Col2 | Col3 |\n|------|------|------|\n|      |      |      |"
        return insertBlock(block, selecting: NSRange(location: 2, length: 4), blankAfter: true, in: text as NSString, caret: caret)
    }

    // Code block: the selected lines are fenced (a longer fence when they hold one); with the caret already inside a fenced
    // block, the fences come off instead; on an empty line an empty block appears with the caret inside.
    static func toggleCodeBlock(in text: String, selection: NSRange) -> TextEdit? {
        let ns = text as NSString
        let lines = MarkdownScanner.blocks(ns)
        let first = lineIndex(selection.location, lines)
        let last = lineIndex(selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location, lines)

        func isFenceLine(_ i: Int) -> Bool { if case .fence = lines[i].kind { return true }; return false }
        func inFence(_ i: Int) -> Bool { if case .code = lines[i].kind { return true }; return isFenceLine(i) }
        if inFence(first) {
            var open = first
            while open > 0, !(lines[open].kind == .fence(opening: true)) { open -= 1 }
            guard lines[open].kind == .fence(opening: true) else { return nil }
            var close: Int? = nil
            var k = max(first, open + 1)
            while k < lines.count { if lines[k].kind == .fence(opening: false) { close = k; break }; k += 1 }
            let innerEnd = close ?? lines.count          // an unclosed fence runs to the end of the text
            var inner = ""
            if open + 1 < innerEnd {
                // The text between the fences, ending the way the closing fence line ended (nothing after it → no stray newline).
                let lastInner = lines[innerEnd - 1]
                let ending = close.map { NSMaxRange(lines[$0].range) - NSMaxRange(lines[$0].content) } ?? NSMaxRange(lastInner.range) - NSMaxRange(lastInner.content)
                let endingText = close.map { ns.substring(with: NSRange(location: NSMaxRange(lines[$0].content), length: ending)) }
                    ?? ns.substring(with: NSRange(location: NSMaxRange(lastInner.content), length: ending))
                inner = ns.substring(with: NSRange(location: lines[open + 1].range.location, length: NSMaxRange(lastInner.content) - lines[open + 1].range.location)) + endingText
            }
            let rangeEnd = close.map { NSMaxRange(lines[$0].range) } ?? ns.length
            let range = NSRange(location: lines[open].range.location, length: rangeEnd - lines[open].range.location)
            let shift = lines[open].range.length
            let innerStart = lines[open].range.location
            func map(_ p: Int) -> Int { min(max(p - shift, innerStart), innerStart + inner.utf16.count) }
            let a = map(selection.location)
            let b = selection.length > 0 ? map(NSMaxRange(selection)) : a
            return TextEdit(range: range, replacement: inner, selection: NSRange(location: a, length: max(b - a, 0)))
        }

        let firstLine = lines[first], lastLine = lines[last]
        if first == last, firstLine.kind == .blank {
            let at = firstLine.content.location
            return TextEdit(range: firstLine.content, replacement: "```\n\n```", selection: NSRange(location: at + 4, length: 0))
        }
        let bodyRange = NSRange(location: firstLine.range.location, length: NSMaxRange(lastLine.content) - firstLine.range.location)
        let body = ns.substring(with: bodyRange)
        let terminator = ns.substring(with: NSRange(location: NSMaxRange(lastLine.content), length: NSMaxRange(lastLine.range) - NSMaxRange(lastLine.content)))
        var longest = 0, run = 0
        for ch in body { if ch == "`" { run += 1; longest = max(longest, run) } else { run = 0 } }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        let opening = fence + "\n"
        let replacement = opening + body + "\n" + fence + terminator
        let shift = opening.utf16.count
        let a = selection.location + shift
        let b = selection.length > 0 ? NSMaxRange(selection) + shift : a
        return TextEdit(range: NSRange(location: bodyRange.location, length: bodyRange.length + terminator.utf16.count), replacement: replacement,
                        selection: NSRange(location: a, length: b - a))
    }
}
