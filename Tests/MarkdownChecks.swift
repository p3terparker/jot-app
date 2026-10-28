import Foundation

// ============================================================================
// Markdown scanner checks (blocks, inline spans) — goldens plus a seeded structural fuzz.
// Descriptions show the span kind and the text of its content, so a failure reads like the input.
// ============================================================================

func kindName(_ k: MDLine.Kind) -> String {
    switch k {
    case .blank: return "blank"
    case .paragraph: return "para"
    case .heading(let n): return "h\(n)"
    case .bullet: return "bullet"
    case .ordered(let n): return "ol\(n)"
    case .task(let c): return c ? "task[x]" : "task[ ]"
    case .quote(let d): return "quote\(d)"
    case .rule: return "rule"
    case .fence(let o): return o ? "fence+" : "fence-"
    case .code: return "code"
    case .tableRow: return "row"
    case .tableSeparator: return "sep"
    }
}
func blockKinds(_ text: String) -> [String] { MarkdownScanner.blocks(text).map { kindName($0.kind) } }

func describeSpan(_ text: String, _ span: MDSpan) -> String {
    let ns = text as NSString
    let content = ns.substring(with: span.content)
    switch span.kind {
    case .strong: return "strong(\(content))"
    case .emphasis: return "emphasis(\(content))"
    case .strike: return "strike(\(content))"
    case .code: return "code(\(content))"
    case .link: return "link(\(content)|\(span.url.map { ns.substring(with: $0) } ?? ""))"
    }
}
func inlineSpans(_ text: String) -> [String] {
    MarkdownScanner.blocks(text).flatMap { MarkdownScanner.spans(text, line: $0).map { describeSpan(text, $0) } }
}

func runMarkdownScannerChecks() {
    // ---- blocks ---------------------------------------------------------------------------------------------
    let everything = "# Title\n\ntext\n- a\n* b\n+ c\n1. one\n2) two\n- [ ] todo\n- [x] done\n> quote\n---\n```\ncode\n```\n| a | b |\n|---|---|"
    check(blockKinds(everything) == ["h1", "blank", "para", "bullet", "bullet", "bullet", "ol1", "ol2", "task[ ]", "task[x]", "quote1", "rule", "fence+", "code", "fence-", "row", "sep"],
          "Every block kind is recognised; got \(blockKinds(everything))")
    check(blockKinds("a\n") == ["para", "blank"] && blockKinds("") == ["blank"] && blockKinds("a") == ["para"], "A trailing newline leaves one empty line where the caret can sit")
    check(blockKinds("#hashtag\n####### seven\n#\n##  spaced") == ["para", "para", "h1", "h2"], "Heading edge cases: no space, seven #, bare #, extra spaces")
    check(blockKinds("```\n# not a heading\n```") == ["fence+", "code", "fence-"], "Nothing inside a fence is a block")
    check(blockKinds("~~~\n```\n~~~") == ["fence+", "code", "fence-"] && blockKinds("````\n```\n````") == ["fence+", "code", "fence-"], "A fence closes only on the same character at least as long")
    check(blockKinds("```\na\nb") == ["fence+", "code", "code"], "An unclosed fence runs to the end")
    check(blockKinds("***\n- - -\n- -\n**bold**\n*italic*\n* item") == ["rule", "rule", "bullet", "para", "para", "bullet"], "Rules, bullets and emphasis are told apart")
    check(blockKinds("- [ ]\n- [x]\n- [X] done\n- [] x\n- [y] x\n- [ ]text") == ["task[ ]", "task[x]", "task[x]", "bullet", "bullet", "bullet"], "Task edge cases")
    check(blockKinds("1. a\n10. b\n1) c\n1.a\n12345678901. x") == ["ol1", "ol10", "ol1", "para", "para"], "Ordered-list edge cases")
    check(blockKinds("> a\n>> a\n> > a\n>no space") == ["quote1", "quote2", "quote2", "quote1"], "Quote depth")
    check(blockKinds("|a|b|\n|---|:-:|\n|a") == ["row", "sep", "para"], "Table rows need two pipes")

    // Ranges and columns.
    let task = MarkdownScanner.blocks("  - [ ] todo item")[0]
    check(task.indent == 2 && task.marker == NSRange(location: 2, length: 6) && task.body == NSRange(location: 8, length: 9)
          && task.checkbox == NSRange(location: 4, length: 3) && task.bodyColumn == 8, "A task's marker, checkbox, body and column; got \(task)")
    let crlf = MarkdownScanner.blocks("a\r\nb")
    check(crlf.count == 2 && crlf[0].range == NSRange(location: 0, length: 3) && crlf[0].content == NSRange(location: 0, length: 1) && crlf[1].range == NSRange(location: 3, length: 1), "CRLF is one terminator")
    let tabbed = MarkdownScanner.blocks("\t- x")[0]
    check(tabbed.indent == 4 && tabbed.bodyColumn == 6, "A tab counts as four columns")
    let emoji = MarkdownScanner.blocks("- 日本語 😀")[0]
    check(emoji.body == NSRange(location: 2, length: 6), "Ranges are UTF-16 (the emoji is two units); got \(emoji.body)")

    // ---- inline ----------------------------------------------------------------------------------------------------
    let cases: [(String, [String])] = [
        ("**bold**", ["strong(bold)"]),
        ("*it*", ["emphasis(it)"]),
        ("_it_ and __bold__", ["emphasis(it)", "strong(bold)"]),
        ("***both***", ["emphasis(**both**)", "strong(both)"]),
        ("**bold *nested* more**", ["strong(bold *nested* more)", "emphasis(nested)"]),
        ("*a **b** c*", ["emphasis(a **b** c)", "strong(b)"]),
        ("**a** and **b**", ["strong(a)", "strong(b)"]),
        ("snake_case_word", []),
        ("snake__case__word", []),
        ("2 * 3 * 4", []),
        ("*unclosed", []),
        ("a*b*c", ["emphasis(b)"]),
        ("~~gone~~", ["strike(gone)"]),
        ("~one~", []),
        ("`code **not bold**`", ["code(code **not bold**)"]),
        ("``a`b``", ["code(a`b)"]),
        ("`unclosed", []),
        ("\\*not\\* emphasis", []),
        ("\\\\*x*", ["emphasis(x)"]),
        ("[text](https://x.com/a_b_c)", ["link(text|https://x.com/a_b_c)"]),
        ("[**b** link](u)", ["link(**b** link|u)", "strong(b)"]),
        ("![alt](pic.png)", ["link(alt|pic.png)"]),
        ("[a](b(c)d)", ["link(a|b(c)d)"]),
        ("[unclosed](", []),
        ("[no url]", []),
        ("*[a*](u)", ["link(a*|u)"]),                       // emphasis cannot straddle a link boundary
        ("*see [a](u)*", ["emphasis(see [a](u))", "link(a|u)"]),
        ("**日本語** と *😀*", ["strong(日本語)", "emphasis(😀)"]),
        ("*(parenthesised)*", ["emphasis((parenthesised))"]),
    ]
    for (text, expected) in cases {
        let got = inlineSpans(text)
        check(got == expected, "Inline spans of \(text.debugDescription): expected \(expected), got \(got)")
    }
    // Exact ranges.
    let span = MarkdownScanner.spans("x **y**", line: MarkdownScanner.blocks("x **y**")[0])[0]
    check(span.full == NSRange(location: 2, length: 5) && span.open == NSRange(location: 2, length: 2) && span.close == NSRange(location: 5, length: 2) && span.content == NSRange(location: 4, length: 1),
          "A span's full/open/close/content ranges; got \(span)")
    let image = MarkdownScanner.spans("![alt](p)", line: MarkdownScanner.blocks("![alt](p)")[0])[0]
    check(image.open == NSRange(location: 0, length: 2) && image.close == NSRange(location: 5, length: 4), "An image's open is `![` and its close is `](src)`")
    // Spans are relative to the whole text, not the line, and skip the block marker.
    check(inlineSpans("# Hello **world**\n- *item*") == ["strong(world)", "emphasis(item)"], "Spans ignore block markers and use whole-text offsets")
    check(MarkdownScanner.spans("**x**", line: MarkdownScanner.blocks("**x**")[0], limit: 3).isEmpty, "A body longer than the limit is not parsed")
    check(inlineSpans("```\n**not bold**\n```").isEmpty, "Nothing inside a fence has inline spans")

    // Linear time: a 50 KB single line with thousands of delimiters must not take long.
    var big = ""
    for n in 0..<4000 { big += n % 3 == 0 ? "**b\(n)** " : n % 3 == 1 ? "*i\(n)* " : "plain\(n) " }
    let started = Date()
    let bigLine = MarkdownScanner.blocks(big)[0]
    let bigSpans = MarkdownScanner.spans(big, line: bigLine, limit: Int.max)
    check(bigSpans.count == 2667 && Date().timeIntervalSince(started) < 1.0, "A 36 KB line parses in linear time (\(bigSpans.count) spans in \(Date().timeIntervalSince(started)) s)")
    check(MarkdownScanner.spans(big, line: bigLine).isEmpty, "The default limit skips inline parsing of a line that long")

    // ---- structural fuzz: whatever the input, ranges stay coherent and spans nest -------------------------------------
    var seed: UInt64 = 0x9E3779B97F4A7C15
    func random() -> UInt64 { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return seed }
    let alphabet = Array("**__~~``[]()\\ ab\n#->+1.!|\t日😀")
    for _ in 0..<3000 {
        let length = Int(random() % 40)
        var text = ""
        for _ in 0..<length { text.append(alphabet[Int(random() % UInt64(alphabet.count))]) }
        let ns = text as NSString
        let lines = MarkdownScanner.blocks(text)
        var cursor = 0
        for line in lines {
            check(line.range.location == cursor && NSMaxRange(line.range) <= ns.length + 0 && NSMaxRange(line.content) <= NSMaxRange(line.range), "Fuzz: lines are contiguous for \(text.debugDescription)")
            check(line.marker.location >= line.content.location && NSMaxRange(line.marker) == line.body.location && NSMaxRange(line.body) == NSMaxRange(line.content), "Fuzz: marker then body fill the content for \(text.debugDescription)")
            cursor = NSMaxRange(line.range)
            let spans = MarkdownScanner.spans(ns, line: line)
            for sp in spans {
                let inside = sp.full.location >= line.body.location && NSMaxRange(sp.full) <= NSMaxRange(line.body)
                let ordered = sp.open.location == sp.full.location && NSMaxRange(sp.close) == NSMaxRange(sp.full)
                    && NSMaxRange(sp.open) <= sp.content.location && NSMaxRange(sp.content) <= sp.close.location
                check(inside && ordered && sp.open.length > 0 && sp.close.length > 0, "Fuzz: a span's ranges are coherent for \(text.debugDescription): \(sp)")
            }
            for (i, a) in spans.enumerated() {
                for b in spans[(i + 1)...] {
                    let disjoint = NSMaxRange(a.full) <= b.full.location
                    let nested = NSMaxRange(b.full) <= NSMaxRange(a.full)
                    check(disjoint || nested, "Fuzz: spans never partly overlap in \(text.debugDescription): \(a) vs \(b)")
                }
            }
        }
        check(cursor == ns.length, "Fuzz: the lines cover the whole text for \(text.debugDescription)")
    }

    // ---- plain titles: the header, sidebar rows and file names show words, not Markdown ------------------------------------------
    func title(_ text: String, _ expected: String) {
        let got = MarkdownPlain.title(text)
        check(got == expected, "title of \(text.debugDescription): expected \(expected.debugDescription), got \(got.debugDescription)")
    }
    title("# Welcome to Jot\nbody", "Welcome to Jot")
    title("## **Bold** and *italic* `code`", "Bold and italic code")
    title("- [ ] Buy milk", "Buy milk")
    title("> A quote", "A quote")
    title("1. First", "First")
    title("A [link](https://x.y) here", "A link here")
    title("![alt text](img.png)", "alt text")
    title("~~gone~~ text", "gone text")
    title("\n\n  \n  Third line\nfourth", "Third line")                       // leading blank lines skipped
    title("---\nreal title", "real title")                                       // a rule isn't a title
    title("```swift\nlet x = 1\n```", "let x = 1")                              // a fence line isn't a title; the code is
    title("", "New Note")
    title("   \n\n", "New Note")
    title("#", "New Note")                                                        // a bare marker has no words
    title(String(repeating: "x", count: 200), String(repeating: "x", count: 80))
    title("snake_case_word and 2 * 3 * 4", "snake_case_word and 2 * 3 * 4")      // not emphasis

    // ---- row snippets: the line under the title, plain ------------------------------------------------------------------------------
    func snippet(_ text: String, _ expected: String) {
        let got = MarkdownPlain.snippet(text)
        check(got == expected, "snippet of \(text.debugDescription): expected \(expected.debugDescription), got \(got.debugDescription)")
    }
    snippet("# Title\nFirst **line** of body\nsecond", "First line of body")
    snippet("# Title", "")
    snippet("Just one line", "")
    snippet("Title\n\n\n- [ ] a task\nmore", "a task")
    snippet("Title\n---\n> quoted words", "quoted words")
    snippet("Title\n  lots   of    space  ", "lots of space")
    snippet("```\ncode here\n```\nafter", "after")                                    // fence lines are skipped, so the code is the title
    snippet("Title\n" + String(repeating: "word ", count: 60), String(String(repeating: "word ", count: 60).split(separator: " ").joined(separator: " ").prefix(100)))
}
