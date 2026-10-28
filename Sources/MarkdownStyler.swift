import Cocoa

// ============================================================================
// MarkdownStyler — live Markdown display for the editor, on top of MarkdownScanner.
//
// The text is never changed: styling is attributes only, so copy, undo, find and save all see plain
// Markdown. In FORMATTED mode, markers (`#`, `**`, `*`, `~~`, backticks…) are tagged `.jotConceal` and
// hidden by ConcealLayoutDelegate (zero-width `.null` glyphs) — except those you are editing: block
// markers on the caret's line, and inline markers of any span the caret/selection touches, INCLUDING
// the span's edges (so arrowing into a span never takes a key press that visibly does nothing).
// In RAW mode every marker is shown, dimmed, in one uniform font.
// ============================================================================

extension NSAttributedString.Key {
    static let jotConceal = NSAttributedString.Key("jotConceal")   // marker characters hidden by ConcealLayoutDelegate
    static let jotKind = NSAttributedString.Key("jotKind")         // a line's block kind (Int): lets an edit restyle only the lines that changed
    static let jotBullet = NSAttributedString.Key("jotBullet")     // a bullet list's `-` / `*` / `+`: drawn as • (the text stays what you typed)
}

// Hides glyphs carrying `.jotConceal` by giving them the zero-width, non-drawing `.null` glyph property,
// so markers disappear while the underlying text stays real plain-text Markdown. Stateless → shared.
final class ConcealLayoutDelegate: NSObject, NSLayoutManagerDelegate {
    func layoutManager(_ lm: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard let ts = lm.textStorage else { return 0 }
        var modified = false
        let props = UnsafeMutablePointer<NSLayoutManager.GlyphProperty>.allocate(capacity: glyphRange.length)
        let out = UnsafeMutablePointer<CGGlyph>.allocate(capacity: glyphRange.length)
        defer { props.deallocate(); out.deallocate() }
        var bullet: CGGlyph? = nil                      // the font's • glyph, looked up once per run
        for i in 0..<glyphRange.length {
            let ci = characterIndexes[i]
            var p = properties[i], g = glyphs[i]
            if ci < ts.length {
                if ts.attribute(.jotConceal, at: ci, effectiveRange: nil) != nil { p = .null; modified = true }
                else if ts.attribute(.jotBullet, at: ci, effectiveRange: nil) != nil {
                    if bullet == nil {
                        var ch: UniChar = 0x2022, glyph: CGGlyph = 0
                        bullet = CTFontGetGlyphsForCharacters(font as CTFont, &ch, &glyph, 1) ? glyph : 0
                    }
                    if let b = bullet, b != 0 { g = b; modified = true }
                }
            }
            props[i] = p; out[i] = g
        }
        if !modified { return 0 }
        lm.setGlyphs(out, properties: props, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        return glyphRange.length
    }
}
let concealLayoutDelegate = ConcealLayoutDelegate()

final class MarkdownStyler: NSObject, NSTextStorageDelegate {
    enum Mode: String { case formatted, raw }

    var mode: Mode = .formatted
    var isSuspended = false               // true while the caller replaces the whole text and will call styleAll itself
    var baseFont: () -> NSFont = { .monospacedSystemFont(ofSize: 13, weight: .regular) }
    var textColor: () -> NSColor = { .white }
    // The caret/selection: markers it touches stay visible. NSNotFound = none (an export reveals nothing).
    private(set) var selection = NSRange(location: NSNotFound, length: 0)
    static var styleAllCount = 0          // instrumentation: full styling passes (the walkthrough budgets these per note load)

    private static let headingScale: [CGFloat] = [1.6, 1.45, 1.3, 1.2, 1.12, 1.06]
    private static let revealLimit = 2_000      // a selection longer than this reveals nothing (it would reflow the whole text)
    private static let revealLineLimit = 60

    // MARK: caches ------------------------------------------------------------------------------------------------
    private var generation = 0
    private var cachedBlocks: (generation: Int, lines: [MDLine])?
    private struct Fonts { var base: NSFont, bold: NSFont, italic: NSFont, boldItalic: NSFont, mono: NSFont, headings: [NSFont] }
    private var cachedFonts: Fonts?

    private func fonts() -> Fonts {
        let base = baseFont()
        if let f = cachedFonts, f.base == base { return f }
        let fm = NSFontManager.shared
        let bold = fm.convert(base, toHaveTrait: .boldFontMask)
        let f = Fonts(base: base, bold: bold, italic: fm.convert(base, toHaveTrait: .italicFontMask), boldItalic: fm.convert(bold, toHaveTrait: .italicFontMask),
                      mono: NSFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular),
                      headings: MarkdownStyler.headingScale.map { fm.convert(NSFont.systemFont(ofSize: base.pointSize * $0, weight: .bold), toHaveTrait: .boldFontMask) })
        cachedFonts = f
        return f
    }
    // The width a list/quote prefix takes in the base font, cached (the same few prefixes — "- ", "  - ", "1. " — repeat all through a note).
    private var hangingCache: (font: NSFont, widths: [String: CGFloat]) = (.systemFont(ofSize: 13), [:])
    private func hangingWidth(_ prefix: String, _ font: NSFont) -> CGFloat {
        if hangingCache.font != font { hangingCache = (font, [:]) }
        if let w = hangingCache.widths[prefix] { return w }
        let w = (prefix as NSString).size(withAttributes: [.font: font]).width
        hangingCache.widths[prefix] = w
        return w
    }
    private func blocks(_ ts: NSTextStorage) -> [MDLine] {
        if let c = cachedBlocks, c.generation == generation { return c.lines }
        let lines = MarkdownScanner.blocks(ts.string as NSString)
        cachedBlocks = (generation, lines)
        return lines
    }

    // MARK: public API --------------------------------------------------------------------------------------------

    func resetReveal() { selection = NSRange(location: NSNotFound, length: 0) }

    func styleAll(_ ts: NSTextStorage) {
        MarkdownStyler.styleAllCount += 1
        generation += 1
        guard ts.length > 0 else { return }
        let ns = ts.string as NSString
        let lines = blocks(ts)
        let f = fonts(), color = textColor()
        ts.beginEditing()
        for line in lines { restyle(ts, ns, line, f, color) }
        ts.endEditing()
        invalidate(ts, NSRange(location: 0, length: ts.length))
    }

    func setMode(_ newMode: Mode, in ts: NSTextStorage) {
        guard newMode != mode else { return }
        mode = newMode
        styleAll(ts)
    }

    // The caret/selection moved: restyle the lines it left and the lines it entered — each on its own, never the
    // text in between (the old paragraph-hull restyle made moving from line 1 to line 5,000 restyle everything).
    func selectionChanged(_ newSelection: NSRange, in ts: NSTextStorage) {
        let old = selection
        selection = newSelection
        guard mode == .formatted, ts.length > 0, old != newSelection else { return }
        let ns = ts.string as NSString
        let lines = blocks(ts)
        var spans: [ClosedRange<Int>] = []
        for sel in [old, newSelection] {
            guard sel.location != NSNotFound, sel.length <= MarkdownStyler.revealLimit else { continue }
            let first = lineIndex(sel.location, lines)
            let last = lineIndex(sel.length > 0 ? NSMaxRange(sel) - 1 : sel.location, lines)
            if last - first <= MarkdownStyler.revealLineLimit { spans.append(first...max(first, last)) }
        }
        var seen = Set<Int>()
        let f = fonts(), color = textColor()
        ts.beginEditing()
        for span in spans {
            for i in span where seen.insert(i).inserted { restyle(ts, ns, lines[i], f, color); invalidate(ts, lines[i].range) }
        }
        ts.endEditing()
    }

    // MARK: editing -----------------------------------------------------------------------------------------------

    func textStorage(_ ts: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard mask.contains(.editedCharacters) else { return }
        generation += 1
        guard !isSuspended else { return }
        // The caret, after the edit, is at the end of what was typed (or where text was removed). The text view
        // reports the real selection right afterwards; this keeps the markers you're typing visible meanwhile.
        selection = NSRange(location: editedRange.location + editedRange.length, length: 0)
        guard ts.length > 0 else { return }
        let ns = ts.string as NSString
        let lines = blocks(ts)
        let first = lineIndex(editedRange.location, lines)
        let last = lineIndex(editedRange.length > 0 ? NSMaxRange(editedRange) - 1 : editedRange.location, lines)
        let f = fonts(), color = textColor()
        for i in first...max(first, last) { restyle(ts, ns, lines[i], f, color) }
        // A fence opening or closing changes what the lines AFTER it are: carry on until a line already has the right kind.
        var i = max(first, last) + 1
        while i < lines.count, lines[i].range.length > 0,
              (ts.attribute(.jotKind, at: lines[i].range.location, effectiveRange: nil) as? Int) != kindCode(lines[i].kind) {
            restyle(ts, ns, lines[i], f, color)
            i += 1
        }
    }

    // MARK: one line ------------------------------------------------------------------------------------------------

    private func lineIndex(_ offset: Int, _ lines: [MDLine]) -> Int {
        for (i, line) in lines.enumerated() where offset < NSMaxRange(line.range) { return i }
        return lines.count - 1
    }
    private func kindCode(_ k: MDLine.Kind) -> Int {
        switch k {
        case .blank: return 0
        case .paragraph: return 1
        case .heading(let n): return 10 + n
        case .bullet: return 20
        case .ordered: return 21
        case .task(let checked): return checked ? 31 : 30
        case .quote(let depth): return 40 + min(depth, 9)
        case .rule: return 50
        case .fence(let opening): return opening ? 61 : 60
        case .code: return 70
        case .tableRow: return 80
        case .tableSeparator: return 81
        }
    }
    private func touchesSelection(_ r: NSRange) -> Bool {
        guard selection.location != NSNotFound, selection.length <= MarkdownStyler.revealLimit else { return false }
        if selection.length == 0 { return r.location <= selection.location && selection.location <= NSMaxRange(r) }
        return NSIntersectionRange(r, selection).length > 0
    }
    private func invalidate(_ ts: NSTextStorage, _ range: NSRange) {
        for lm in ts.layoutManagers {
            lm.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
            lm.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        }
    }

    private func restyle(_ ts: NSTextStorage, _ ns: NSString, _ line: MDLine, _ f: Fonts, _ color: NSColor) {
        let range = line.range
        guard range.length > 0 else { return }
        let formatted = mode == .formatted
        let dim = color.withAlphaComponent(0.3)
        var attributes: [NSAttributedString.Key: Any] = [.font: f.base, .foregroundColor: color, .jotKind: kindCode(line.kind)]
        if formatted, case .heading(let level) = line.kind, range.location > 0 {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacingBefore = f.base.pointSize * (level == 1 ? 0.6 : level == 2 ? 0.45 : 0.3)
            attributes[.paragraphStyle] = p
        }
        // A wrapped list item or quote line lines up under its text, not under its marker.
        switch line.kind {
        case .bullet, .ordered, .task, .quote:
            let prefix = ns.substring(with: NSRange(location: line.content.location, length: line.body.location - line.content.location))
            let width = hangingWidth(prefix, f.base)
            if width > 0 { let p = NSMutableParagraphStyle(); p.headIndent = width; attributes[.paragraphStyle] = p }
        default: break
        }
        ts.setAttributes(attributes, range: range)    // also clears any conceal / strike / background left from before

        func hide(_ r: NSRange, revealed: Bool) {
            guard r.length > 0 else { return }
            if formatted && !revealed { ts.addAttribute(.jotConceal, value: true, range: r) }
            else { ts.addAttribute(.foregroundColor, value: dim, range: r) }
        }
        let lineRevealed = touchesSelection(line.content)

        switch line.kind {
        case .heading(let level):
            if formatted { ts.addAttribute(.font, value: f.headings[min(level, 6) - 1], range: line.content) }
            hide(line.marker, revealed: lineRevealed)
        case .task:
            if let box = line.checkbox, box.length == 3 {
                let checked = ns.character(at: box.location + 1) != 0x20
                ts.addAttribute(.foregroundColor, value: checked ? NSColor.systemGreen : dim, range: box)
            }
        case .quote:
            ts.addAttribute(.foregroundColor, value: dim, range: line.marker)
        case .rule, .tableSeparator, .fence:
            ts.addAttribute(.foregroundColor, value: dim, range: line.content)
        case .bullet:
            // The marker character itself (after any indentation) is drawn as •; Raw mode keeps the plain character.
            if formatted, line.marker.length > 0 {
                let c = ns.character(at: line.marker.location)
                if c == 0x2D || c == 0x2A || c == 0x2B { ts.addAttribute(.jotBullet, value: true, range: NSRange(location: line.marker.location, length: 1)) }
            }
        case .code, .blank, .paragraph, .ordered, .tableRow:
            break
        }

        // Inline spans (outer first, so a bold run inside an italic one ends up bold italic).
        switch line.kind {
        case .blank, .code, .fence, .rule, .tableSeparator: return
        default: break
        }
        for sp in MarkdownScanner.spans(ns, line: line) {
            let revealed = !formatted || touchesSelection(sp.full)
            if formatted {
                switch sp.kind {
                case .strong: addTrait(ts, sp.content, .boldFontMask)
                case .emphasis: addTrait(ts, sp.content, .italicFontMask)
                case .strike: ts.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: sp.content)
                case .code:
                    ts.addAttributes([.jotChip: color.withAlphaComponent(0.1), .font: f.mono], range: sp.content)
                case .link:
                    ts.addAttributes([.foregroundColor: NSColor.controlAccentColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: sp.content)
                }
            }
            hide(sp.open, revealed: revealed)
            hide(sp.close, revealed: revealed)
        }
    }

    private func addTrait(_ ts: NSTextStorage, _ range: NSRange, _ trait: NSFontTraitMask) {
        guard range.length > 0 else { return }
        let wanted: NSFontDescriptor.SymbolicTraits = trait == .boldFontMask ? .bold : .italic
        ts.enumerateAttribute(.font, in: range, options: []) { value, sub, _ in
            guard let font = value as? NSFont, !font.fontDescriptor.symbolicTraits.contains(wanted) else { return }
            ts.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: sub)
        }
    }
}

// Adapter kept for the call sites in both editors: the selection changed, so the markers you can see may need to change.
func revealActiveParagraph(_ tv: NSTextView, _ styler: MarkdownStyler) {
    guard let ts = tv.textStorage else { return }
    styler.selectionChanged(tv.selectedRange(), in: ts)
}
