import Foundation

// ============================================================================
// Fixtures — a disposable note library for the isolated preview walkthrough and the tests.
// Foundation-only on purpose: `test.sh` compiles this file without AppKit. Nothing here ever
// reads or writes the real notes folder; callers pass the destination.
// ============================================================================

struct FixtureNote {
    let id: String                // deterministic UUID used as the file name
    let title: String             // first line as Jot shows it (used by the walkthrough to find the note)
    let frontmatter: [String]     // raw lines between the --- fences ("pin: true", "tags: [a]", …)
    let body: String
    let age: TimeInterval         // seconds before "now" for the modification date

    var fileName: String { id + ".md" }
    var raw: String {
        frontmatter.isEmpty ? body : "---\n" + frontmatter.joined(separator: "\n") + "\n---\n" + body
    }
}

enum Fixtures {
    static func id(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012X", n) }

    // A tiny legacy rich-text note: Jot ≤ 2.9 stored RTF as base64 in the body with `rtfMode: true`.
    static let legacyRTF = "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Helvetica;}}Legacy rich text with \\b bold\\b0  words.\\par Second line.\\par}"
    static var legacyRTFBase64: String { Data(legacyRTF.utf8).base64EncodedString() }

    static let tourBody = """
    # Welcome to Jot

    A quick **bold** word, some *italic*, ~~struck~~ text and `inline code`.

    ## Lists
    - First bullet
    - Second bullet with a [link](https://example.com)
      - A nested bullet
    1. Numbered one
    2. Numbered two

    ## Tasks
    - [ ] Buy milk
    - [x] Call Sam

    > A quote worth keeping.

    ---

    | Col1 | Col2 | Col3 |
    |------|------|------|
    | a    | b    | c    |

    Plain paragraph that is long enough to wrap onto a second line in the small pad, so wrapped text can be judged.
    """

    // ~200 KB of realistic markdown (headings, bullets, emphasis, links) — the largest real note is ~200 KB.
    static func bigBody(bytes: Int = 200_000) -> String {
        var out = "# Big note\n\n"
        var n = 1
        while out.utf8.count < bytes {
            out += "## Section \(n)\n\nLorem ipsum dolor sit amet, **consectetur** adipiscing elit, *sed do* eiusmod tempor `incididunt` ut labore "
            out += "et dolore magna aliqua. [Link \(n)](https://example.com/\(n)) Ut enim ad minim veniam, quis nostrud exercitation.\n\n"
            out += "- bullet a \(n)\n- bullet b \(n)\n- [ ] task \(n)\n\n"
            n += 1
        }
        return out
    }

    // One enormous paragraph with emphasis scattered through it: stresses per-paragraph regexes.
    static func longLineBody(bytes: Int = 50_000) -> String {
        var out = "One long line: "
        var n = 0
        while out.utf8.count < bytes {
            out += n % 7 == 0 ? "**bold\(n)** " : n % 11 == 0 ? "*it\(n)* " : "word\(n) "
            n += 1
        }
        return out
    }

    static func library(now: Date = Date()) -> [FixtureNote] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let tomorrow = iso.string(from: now.addingTimeInterval(86_400))
        let day: TimeInterval = 86_400
        return [
            FixtureNote(id: id(1), title: "# Welcome to Jot", frontmatter: [], body: tourBody, age: 120),
            FixtureNote(id: id(2), title: "Groceries", frontmatter: ["order: 2"],
                        body: "Groceries\n- milk\n- eggs\n- coffee beans\n- [ ] oat milk\n", age: 3_600),
            FixtureNote(id: id(3), title: "Pinned ideas", frontmatter: ["pin: true", "order: 1"],
                        body: "Pinned ideas\n\nThings I never want to lose sight of.\n", age: 2 * day),
            FixtureNote(id: id(4), title: "Call the dentist", frontmatter: ["reminder: \(tomorrow)", "order: 4"],
                        body: "Call the dentist\n\nAsk about the appointment next week.\n", age: 3 * day),
            FixtureNote(id: id(5), title: "# Meeting notes", frontmatter: ["order: 3"],
                        body: "# Meeting notes\n\n## Agenda\n- Roadmap\n- Hiring\n\n## Decisions\n1. Ship on Friday\n2. Revisit pricing\n", age: 4 * day),
            FixtureNote(id: id(6), title: "Project plan", frontmatter: ["order: 5"],
                        body: "Project plan\n\n- [x] Draft\n- [x] Review\n- [ ] Publish\n- [ ] Announce\n", age: 5 * day),
            FixtureNote(id: id(7), title: "Obsidian-style note", frontmatter: ["tags: [work, ideas]", "aliases: [Scratch]", "created: 2026-01-02"],
                        body: "Obsidian-style note\n\nThis note carries frontmatter keys Jot does not know about.\n", age: 6 * day),
            FixtureNote(id: id(8), title: "Legacy rich text with bold words.", frontmatter: ["rtfMode: true"], body: legacyRTFBase64, age: 7 * day),
            FixtureNote(id: id(9), title: "日本語のメモ 🎉 שלום", frontmatter: [],
                        body: "日本語のメモ 🎉 שלום\n\nEmoji 👩‍👩‍👧‍👦, combining é, and RTL text: שלום עולם.\n", age: 8 * day),
            FixtureNote(id: id(10), title: "# Big note", frontmatter: [], body: bigBody(), age: 9 * day),
            FixtureNote(id: id(11), title: "One long line", frontmatter: [], body: longLineBody(), age: 10 * day),
            FixtureNote(id: id(12), title: "Scratch to delete", frontmatter: [], body: "Scratch to delete\n\nSafe to remove in tests.\n", age: 30),
        ]
    }

    // Two already-deleted notes for the Recently Deleted screens.
    static func trashLibrary() -> [FixtureNote] {
        [
            FixtureNote(id: id(100), title: "Old shopping list", frontmatter: [], body: "Old shopping list\n- bread\n", age: 2 * 86_400),
            FixtureNote(id: id(101), title: "Draft email", frontmatter: [], body: "Draft email\n\nHi there,\n", age: 20 * 86_400),
        ]
    }

    // Writes fixtures into the given folders and stamps modification dates. Returns the live note URLs.
    @discardableResult
    static func install(into notes: URL, trash: URL, now: Date = Date()) throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: notes, withIntermediateDirectories: true)
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        func write(_ n: FixtureNote, to folder: URL) throws -> URL {
            let url = folder.appendingPathComponent(n.fileName)
            try n.raw.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-n.age)], ofItemAtPath: url.path)
            return url
        }
        _ = try trashLibrary().map { try write($0, to: trash) }
        return try library(now: now).map { try write($0, to: notes) }
    }
}
