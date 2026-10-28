import Cocoa

// ============================================================================
// EditorKit — the one place an editor's text system is assembled.
//
// Jot edits through TextKit 1 on purpose: hiding Markdown markers is done per glyph (`.null` glyphs from a
// layout-manager delegate), which TextKit 2 has no equivalent for. `NSTextView(frame:)` starts life on
// TextKit 2 on macOS 13+ and silently falls back to TextKit 1 the first time `.layoutManager` is touched.
// Building the stack explicitly means there is never a fallback: `textLayoutManager` is nil from the first
// moment, and the preview walkthrough asserts it.
// ============================================================================
enum EditorKit {
    static func makeTextView(frame: NSRect) -> JotTextView {
        let storage = NSTextStorage()
        let layout = JotLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        return JotTextView(frame: frame, textContainer: container)
    }
}

extension NSAttributedString.Key {
    static let jotChip = NSAttributedString.Key("jotChip")   // NSColor: paint a rounded chip behind this run (inline code)
}

// ============================================================================
// JotLayoutManager — paints what TextKit 1 has no attribute for (or draws unreliably):
//   • `.jotChip` runs: the rounded tint behind `inline code`. TextKit's own `.backgroundColor` is not used for
//     this. With concealed (`.null`) marker glyphs in play, a background (and the rects
//     `enumerateEnclosingRects` hands back for a range that ends in a concealed glyph) went missing in the
//     preview harness's bitmap snapshots, so the chip is built from the glyph positions of the VISIBLE
//     glyphs only — see GOTCHAS.md.
// ============================================================================
final class JotLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let ts = textStorage, glyphsToShow.length > 0 else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        ts.enumerateAttribute(.jotChip, in: chars, options: []) { value, range, _ in
            guard let color = value as? NSColor, range.length > 0 else { return }
            color.setFill()
            for rect in self.runRects(characters: range) {
                NSBezierPath(roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -1, dy: 1.5), xRadius: 3, yRadius: 3).fill()
            }
        }
    }

    // One rect per line fragment the run touches, in text-container coordinates: from the first visible glyph's
    // position to the start of the glyph after the run's last visible glyph (or the fragment's used width when
    // the run wraps on).
    func runRects(characters range: NSRange) -> [NSRect] {
        guard range.length > 0, numberOfGlyphs > 0 else { return [] }
        let first = glyphIndexForCharacter(at: range.location)
        let last = glyphIndexForCharacter(at: NSMaxRange(range) - 1)
        guard first <= last else { return [] }
        var rects: [NSRect] = []
        var g = first
        while g <= last {
            var fragmentGlyphs = NSRange()
            let fragment = lineFragmentRect(forGlyphAt: g, effectiveRange: &fragmentGlyphs)
            let used = lineFragmentUsedRect(forGlyphAt: g, effectiveRange: nil)
            let end = min(last, NSMaxRange(fragmentGlyphs) - 1)
            let startX = fragment.minX + location(forGlyphAt: g).x
            let endX = end + 1 < NSMaxRange(fragmentGlyphs) ? fragment.minX + location(forGlyphAt: end + 1).x : used.maxX
            if endX > startX { rects.append(NSRect(x: startX, y: fragment.minY, width: endX - startX, height: fragment.height)) }
            g = end + 1
        }
        return rects
    }
}

extension JotTextView {
    // Big notes lay out only what's on screen (a keystroke in a 200 KB note costs 8 ms instead of 61); short notes keep TextKit's
    // contiguous layout, which has no estimated-height scroller or caret surprises and is just as fast for them.
    static let nonContiguousThreshold = 50_000
    func adaptLayout(toTextLength length: Int) {
        layoutManager?.allowsNonContiguousLayout = length > JotTextView.nonContiguousThreshold
    }
}
