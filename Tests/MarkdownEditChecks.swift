import Foundation

// ============================================================================
// MarkdownEdit checks. Test strings use ‹…› for a selection and ¦ for a caret, so every golden reads like
// the editor: before → after, with the selection after the edit shown the same way.
// ============================================================================

func parseMarked(_ s: String) -> (text: String, selection: NSRange) {
    var text = "", start = -1, end = -1, caret = -1
    var len = 0
    for ch in s {
        switch ch {
        case "‹": start = len
        case "›": end = len
        case "¦": caret = len
        default: text.append(ch); len += ch.utf16.count
        }
    }
    if caret >= 0 { return (text, NSRange(location: caret, length: 0)) }
    return (text, NSRange(location: max(start, 0), length: max(end - max(start, 0), 0)))
}
func renderMarked(_ text: String, _ sel: NSRange) -> String {
    let ns = text as NSString
    if sel.length == 0 { return ns.substring(to: sel.location) + "¦" + ns.substring(from: sel.location) }
    return ns.substring(to: sel.location) + "‹" + ns.substring(with: sel) + "›" + ns.substring(from: NSMaxRange(sel))
}
/// Applies an edit produced from a marked string; returns the marked result, or nil when there was nothing to do.
func edited(_ marked: String, _ make: (String, NSRange) -> TextEdit?) -> String? {
    let (text, sel) = parseMarked(marked)
    guard let edit = make(text, sel) else { return nil }
    return renderMarked(edit.applied(to: text), edit.selection)
}

func runMarkdownEditChecks() {
    func inline(_ style: InlineStyle, _ input: String, _ expected: String?, line: UInt = #line) {
        let got = edited(input) { MarkdownEdit.toggleInline(style, in: $0, selection: $1) }
        check(got == expected, "toggle \(style) on \(input.debugDescription): expected \((expected ?? "nil").debugDescription), got \((got ?? "nil").debugDescription)")
    }
    // ---- wrap ---------------------------------------------------------------------------------------------------
    inline(.strong, "a ‹b› c", "a **‹b›** c")
    inline(.emphasis, "a ‹b› c", "a *‹b›* c")
    inline(.strike, "a ‹b› c", "a ~~‹b›~~ c")
    inline(.code, "a ‹b› c", "a `‹b›` c")
    inline(.strong, "‹a b›", "**‹a b›**")
    inline(.strong, "a ‹ b › c", "a  **‹b›**  c")                  // whitespace stays outside the markers
    inline(.strong, "‹  ›", nil)                                       // nothing but whitespace selected
    // ---- unwrap -------------------------------------------------------------------------------------------------------
    inline(.strong, "a **‹b›** c", "a ‹b› c")
    inline(.strong, "a ‹**b**› c", "a ‹b› c")                          // the markers themselves selected
    inline(.emphasis, "‹*x*›", "‹x›")
    inline(.strong, "**‹a b›**", "‹a b›")
    // ---- split a span around the selection ------------------------------------------------------------------------------
    inline(.strong, "**a b ‹c› d e**", "**a b** ‹c› **d e**")
    inline(.strong, "**a ‹b c›**", "**a** ‹b c›")                      // selection runs to the end of the span
    inline(.strong, "**‹a b› c**", "‹a b› **c**")
    // ---- merge ---------------------------------------------------------------------------------------------------------
    inline(.strong, "‹a **b** c›", "**‹a b c›**")                      // inner bold absorbed, no `****`
    inline(.strong, "**a** ‹b›", "**a** **‹b›**")
    inline(.strong, "‹x **a**›", "**‹x a›**")
    inline(.strong, "**a‹b› c**d", "**a**‹b› **c**d")                 // the span splits; nothing is invented between a and b
    inline(.emphasis, "***‹x›***", "**‹x›**")
    // ---- bold + italic -------------------------------------------------------------------------------------------------
    inline(.strong, "*‹x›*", "***‹x›***")
    inline(.strong, "***‹x›***", "*‹x›*")
    // ---- caret ---------------------------------------------------------------------------------------------------------
    inline(.strong, "wo¦rd here", "**‹word›** here")                   // a caret inside a word formats the word
    inline(.strong, "word¦ here", "**‹word›** here")                   // …or right after it
    inline(.strong, "a ¦ b", "a **¦** b")                              // between words: an empty pair with the caret inside
    inline(.emphasis, "a ¦ b", "a *¦* b")
    inline(.strong, "**wo¦rd**", "wo¦rd")                              // inside a span: unwrap
    inline(.strong, "**word¦**", "word¦")
    inline(.code, "x ¦ y", "x `¦` y")
    // ---- several lines: each line wrapped on its own, block markers left alone ---------------------------------------------
    inline(.strong, "‹a\nb›", "**‹a**\n**b›**")
    inline(.strong, "- ‹a\n- b›", "- **‹a**\n- **b›**")
    inline(.strong, "‹a\n\nb›", "**‹a**\n\n**b›**")                  // blank lines skipped
    inline(.strong, "# ‹Title›", "# **‹Title›**")
    // ---- never inside a code block or on a rule -----------------------------------------------------------------------------
    inline(.strong, "```\n‹a›\n```", nil)
    inline(.strong, "‹---›", nil)
    // ---- unicode ----------------------------------------------------------------------------------------------------------
    inline(.strong, "x ‹日本語 😀› y", "x **‹日本語 😀›** y")
    inline(.strong, "日¦本語", "**‹日本語›**")

    // ---- block styles ---------------------------------------------------------------------------------------------------------
    func block(_ style: BlockStyle, _ input: String, _ expected: String?) {
        let got = edited(input) { MarkdownEdit.setBlock(style, in: $0, selection: $1) }
        check(got == expected, "set \(style) on \(input.debugDescription): expected \((expected ?? "nil").debugDescription), got \((got ?? "nil").debugDescription)")
    }
    block(.heading(1), "Ti¦tle", "# Ti¦tle")
    block(.heading(2), "Ti¦tle", "## Ti¦tle")
    block(.heading(1), "# Ti¦tle", "Ti¦tle")                                   // the same level toggles off
    block(.heading(2), "# Ti¦tle", "## Ti¦tle")                                // another level replaces
    block(.heading(1), "- It¦em", "# It¦em")                                   // a heading replaces a list marker
    block(.body, "## Ti¦tle", "Ti¦tle")
    block(.body, "- It¦em", "It¦em")
    block(.bullet, "It¦em", "- It¦em")
    block(.bullet, "- It¦em", "It¦em")                                         // toggles off
    block(.bullet, "1. It¦em", "- It¦em")
    block(.bullet, "# It¦em", "- It¦em")
    block(.bullet, "  It¦em", "  - It¦em")                                     // indent kept
    block(.ordered, "‹a\nb\nc›", "1. ‹a\n2. b\n3. c›")
    block(.ordered, "1. ‹a\n2. b›", "‹a\nb›")                                  // all ordered → toggle off
    block(.ordered, "- ‹a\n- b›", "1. ‹a\n2. b›")
    block(.task, "It¦em", "- [ ] It¦em")
    block(.task, "- [ ] It¦em", "It¦em")
    block(.task, "- It¦em", "- [ ] It¦em")
    block(.quote, "Qu¦ote", "> Qu¦ote")
    block(.quote, "> Qu¦ote", "Qu¦ote")
    block(.quote, "- It¦em", "> - It¦em")                                      // quote is a separate layer
    block(.bullet, "> It¦em", "> - It¦em")                                     // …so a list inside a quote keeps the quote
    block(.heading(1), "> ‹a›", "> # ‹a›")
    block(.bullet, "‹a\n\nb›", "- ‹a\n\n- b›")                                 // blank lines are left blank
    block(.bullet, "‹a\nb\n›", "- ‹a\n- b\n›")                                 // a selection ending at a line start excludes that line
    block(.bullet, "¦", "- ¦")                                                  // an empty line still takes a marker
    block(.bullet, "```\n¦a\n```", nil)

    // ---- Return --------------------------------------------------------------------------------------------------------------
    func ret(_ input: String, _ expected: String?) {
        let got = edited(input) { MarkdownEdit.continueList(in: $0, caret: $1.location) }
        check(got == expected, "Return in \(input.debugDescription): expected \((expected ?? "nil").debugDescription), got \((got ?? "nil").debugDescription)")
    }
    ret("- item¦", "- item\n- ¦")
    ret("* item¦", "* item\n* ¦")
    ret("1. one¦", "1. one\n2. ¦")
    ret("9) nine¦", "9) nine\n10) ¦")
    ret("- [x] done¦", "- [x] done\n- [ ] ¦")                                     // a new task starts unchecked
    ret("  - nested¦", "  - nested\n  - ¦")                                       // indent kept
    ret("- ab¦cd", "- ab\n- ¦cd")                                                // the item splits at the caret
    ret("- ¦", "¦")                                                              // an empty item ends the list (no extra blank line)
    ret("1. ¦", "¦")
    ret("  - ¦", "- ¦")                                                         // an empty nested item outdents first
    ret("¦- x", "\n¦- x")                                                        // before the marker: no `- - x`
    ret("-¦ x", "\n-¦ x")
    ret("> quote¦", "> quote\n> ¦")
    ret("> ¦", "¦")
    ret("> - item¦", "> - item\n> - ¦")
    ret("plain¦", nil)
    ret("# Title¦", nil)
    ret("```\n- x¦\n```", nil)

    // ---- Backspace at a marker ------------------------------------------------------------------------------------------------
    func back(_ input: String, _ expected: String?) {
        let got = edited(input) { MarkdownEdit.backspaceMarker(in: $0, caret: $1.location) }
        check(got == expected, "Backspace in \(input.debugDescription): expected \((expected ?? "nil").debugDescription), got \((got ?? "nil").debugDescription)")
    }
    back("- ¦item", "¦item")
    back("1. ¦item", "¦item")
    back("- [ ] ¦item", "¦item")
    back("## ¦Title", "¦Title")
    back("> ¦quote", "¦quote")
    back("  - ¦item", "¦item")
    back("-¦ item", nil)                                                        // not at the body start: ordinary Backspace
    back("- it¦em", nil)
    back("plain¦", nil)

    // ---- indent / outdent --------------------------------------------------------------------------------------------------
    func indentEdit(_ outdent: Bool, _ input: String, _ expected: String?) {
        let got = edited(input) { MarkdownEdit.indent(outdent: outdent, in: $0, selection: $1) }
        check(got == expected, "\(outdent ? "outdent" : "indent") \(input.debugDescription): expected \((expected ?? "nil").debugDescription), got \((got ?? "nil").debugDescription)")
    }
    indentEdit(false, "‹a\nb›", "‹  a\n  b›")
    indentEdit(false, "a¦", "  a¦")
    indentEdit(false, "‹a\n\nb›", "‹  a\n\n  b›")                      // blank lines stay blank
    indentEdit(false, "¦", nil)
    indentEdit(true, "  a¦", "a¦")
    indentEdit(true, "    a¦", "  a¦")
    indentEdit(true, "\t- x¦", "- x¦")
    indentEdit(true, "a¦", nil)
    indentEdit(true, " a¦", "a¦")                                           // a single space is removed too

    // ---- link -----------------------------------------------------------------------------------------------------------------
    func link(_ input: String, _ expected: String?, url: String? = nil) {
        let got = edited(input) { MarkdownEdit.toggleLink(in: $0, selection: $1, url: url) }
        check(got == expected, "link on \(input.debugDescription): expected \((expected ?? "nil").debugDescription), got \((got ?? "nil").debugDescription)")
    }
    link("wo¦rd", "[word](‹url›)")                                                // a caret on a word links the word, URL ready to type
    link("a ‹big word› b", "a [big word](‹url›) b")
    link("# ‹Title›", "# [Title](‹url›)")
    link("‹https://x.y›", "[¦](https://x.y)")                                     // a selected URL becomes the destination
    link("a ¦ b", "a [¦]() b")                                                    // between words: an empty link
    link("[te¦xt](http://x.y)", "‹text›")                                         // inside a link: back to its text
    link("a ‹[t](u)› b", "a ‹t› b")
    link("wo¦rd", "[word](https://a.b)¦", url: "https://a.b")                     // a known destination: caret after the link
    link("‹a\nb›", nil)                                                           // a link can't span lines
    link("```\n¦a\n```", nil)
    link("‹  ›", nil)

    // ---- divider / table / code block -------------------------------------------------------------------------------------------
    func insertion(_ input: String, _ expected: String, _ make: (String, Int) -> TextEdit) {
        let got = edited(input) { make($0, $1.location) }
        check(got == expected, "insert into \(input.debugDescription): expected \(expected.debugDescription), got \((got ?? "nil").debugDescription)")
    }
    insertion("para¦", "para\n\n---\n¦") { MarkdownEdit.insertDivider(in: $0, caret: $1) }          // never straight under a paragraph (that would make it a heading)
    insertion("para¦\nnext", "para\n\n---\n¦next") { MarkdownEdit.insertDivider(in: $0, caret: $1) }
    insertion("¦", "---\n¦") { MarkdownEdit.insertDivider(in: $0, caret: $1) }
    insertion("para\n¦", "para\n\n---\n¦") { MarkdownEdit.insertDivider(in: $0, caret: $1) }
    insertion("a\n\n¦\nb", "a\n\n---\n¦b") { MarkdownEdit.insertDivider(in: $0, caret: $1) }          // an empty line is replaced in place
    insertion("para¦", "para\n\n| ‹Col1› | Col2 | Col3 |\n|------|------|------|\n|      |      |      |\n") { MarkdownEdit.insertTable(in: $0, caret: $1) }
    insertion("para¦\nnext", "para\n\n| ‹Col1› | Col2 | Col3 |\n|------|------|------|\n|      |      |      |\n\nnext") { MarkdownEdit.insertTable(in: $0, caret: $1) }   // a blank line keeps `next` out of the table
    func code(_ input: String, _ expected: String?) {
        let got = edited(input) { MarkdownEdit.toggleCodeBlock(in: $0, selection: $1) }
        check(got == expected, "code block on \(input.debugDescription): expected \((expected ?? "nil").debugDescription), got \((got ?? "nil").debugDescription)")
    }
    code("‹a\nb›", "```\n‹a\nb›\n```")
    code("a¦", "```\na¦\n```")
    code("a\nb¦\nc", "a\n```\nb¦\n```\nc")
    code("¦", "```\n¦\n```")
    code("‹a ``` b›", "````\n‹a ``` b›\n````")                                      // a longer fence when the text holds one
    code("```\n¦a\n```", "¦a")                                                    // inside a block: the fences come off
    code("```\nx\n¦y\n```\nafter", "x\n¦y\nafter")
    code("```\n¦```\nafter", "¦after")                                              // an empty block disappears
    code("a\n```\n¦\n```", "a\n¦")
    code("```\n¦a", "¦a")                                                         // an unclosed fence
    code("before\n```swift\nlet x = 1¦\n```", "before\nlet x = 1¦")                       // nothing followed the closing fence, so nothing trails the text
    check(MarkdownEdit.state(in: "```\nco", selection: NSRange(location: 6, length: 0)).codeBlock, "A line in a fenced block reports a code block")

    // ---- state ---------------------------------------------------------------------------------------------------------------
    func state(_ input: String) -> FormatState {
        let (t, s) = parseMarked(input)
        return MarkdownEdit.state(in: t, selection: s)
    }
    check(state("**wo¦rd**").strong && !state("**wo¦rd**").emphasis, "A caret inside bold reports bold")
    check(state("***x¦***").strong && state("***x¦***").emphasis, "Bold italic reports both")
    check(state("plain ‹te›xt").strong == false, "Plain text reports no style")
    check(state("# ti¦tle").block == .heading(1) && state("## ti¦tle").block == .heading(2), "Heading level")
    check(state("- it¦em").block == .bullet && state("1. it¦em").block == .ordered && state("- [ ] it¦em").block == .task, "List kinds")
    check(state("> - it¦em").quote && state("> - it¦em").block == .bullet, "A list inside a quote reports both")
    check(state("a ‹**b**› c").strong, "A selection covering a span reports it")
    check(state("a **b** ‹c› d").strong == false, "A selection outside the span reports none")
    check(state("`co¦de`").code && !state("`co¦de`").strong, "Inline code")

    // ---- seeded fuzz: whatever the input, edits stay in bounds and only ever add or remove marker characters ----------------------
    var seed: UInt64 = 0xD1B54A32D192ED03
    func random() -> UInt64 { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return seed }
    let tokens = ["a", "bc", " ", " ", "**", "*", "~~", "`", "\n", "- ", "# ", "> ", "1. ", "[x](y)", "日本", "😀", "\t"]
    func markerFree(_ s: String) -> String { s.filter { $0 != "*" && $0 != "~" && $0 != "`" } }
    for _ in 0..<2500 {
        var text = ""
        for _ in 0..<Int(random() % 14) { text += tokens[Int(random() % UInt64(tokens.count))] }
        let ns = text as NSString
        let location = Int(random() % UInt64(ns.length + 1))
        let length = random() % 3 == 0 ? 0 : Int(random() % UInt64(ns.length - location + 1))
        let selection = NSRange(location: location, length: length)
        // Selections never start or end inside a surrogate pair (an editor can't produce that).
        func splitsPair(_ i: Int) -> Bool { i > 0 && i < ns.length && ns.character(at: i - 1) >= 0xD800 && ns.character(at: i - 1) <= 0xDBFF && ns.character(at: i) >= 0xDC00 && ns.character(at: i) <= 0xDFFF }
        if splitsPair(selection.location) || splitsPair(NSMaxRange(selection)) { continue }
        var edits: [(String, TextEdit?)] = []
        for style in [InlineStyle.strong, .emphasis, .strike, .code] { edits.append(("toggle \(style)", MarkdownEdit.toggleInline(style, in: text, selection: selection))) }
        for style in [BlockStyle.heading(1), .heading(3), .body, .bullet, .ordered, .task, .quote] { edits.append(("block \(style)", MarkdownEdit.setBlock(style, in: text, selection: selection))) }
        edits.append(("indent", MarkdownEdit.indent(outdent: false, in: text, selection: selection)))
        edits.append(("outdent", MarkdownEdit.indent(outdent: true, in: text, selection: selection)))
        edits.append(("link", MarkdownEdit.toggleLink(in: text, selection: selection)))
        edits.append(("code block", MarkdownEdit.toggleCodeBlock(in: text, selection: selection)))
        edits.append(("divider", MarkdownEdit.insertDivider(in: text, caret: selection.location)))
        edits.append(("table", MarkdownEdit.insertTable(in: text, caret: selection.location)))
        if length == 0 {
            edits.append(("return", MarkdownEdit.continueList(in: text, caret: location)))
            edits.append(("backspace", MarkdownEdit.backspaceMarker(in: text, caret: location)))
        }
        for (name, maybe) in edits {
            guard let edit = maybe else { continue }
            let inBounds = edit.range.location >= 0 && NSMaxRange(edit.range) <= ns.length
            check(inBounds, "Fuzz: \(name) range \(edit.range) is inside \(text.debugDescription)")
            guard inBounds else { continue }
            let result = edit.applied(to: text)
            let rl = (result as NSString).length
            check(edit.selection.location >= 0 && NSMaxRange(edit.selection) <= rl, "Fuzz: \(name) on selection \(selection) leaves the selection \(edit.selection) inside the \(rl)-long result of \(text.debugDescription) → \(result.debugDescription) (edit \(edit.range) → \(edit.replacement.debugDescription))")
            if name.hasPrefix("toggle") {
                check(markerFree(result) == markerFree(text), "Fuzz: \(name) only adds or removes markers: \(text.debugDescription) → \(result.debugDescription)")
            }
        }
    }
}
