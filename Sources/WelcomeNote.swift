import Foundation

// ============================================================================
// WelcomeNote — the first note a new install opens on: a real note, in Jot's own Markdown, that shows the formatting it
// describes and mentions the shortcut the person actually has (not a hard-coded one). Pure Foundation so test.sh can check it.
// ============================================================================
enum WelcomeNote {
    static func body(hotkey: String) -> String {
        """
        # Welcome to Jot

        Press \(hotkey) anywhere to open or close this notepad. Just start typing — it saves as you go.

        ## Write in Markdown
        Type `#` for a title, `-` for a list, `**bold**` or `*italic*` — or use the formatting bar (the **Aa** button) and these shortcuts. Click a box to tick it:

        - [ ] ⌘B bold · ⌘I italic · ⌘K link
        - [ ] ⇧⌘T title · ⇧⌘H heading · ⇧⌘7 bullets · ⇧⌘L checklist
        - [ ] ⌘/ shows the raw Markdown, and back

        ## Find your notes
        The sidebar button (or ⌃⌘S) opens your notes; ⌥⌘F searches them. Share sends a note to Apple Notes, Stickies, a file or anyone.

        Delete this note whenever you like — ⇧⌘⌫ — and you can always get it back from Recently Deleted.

        """
    }
}
