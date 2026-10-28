# Working on Jot App

- Read README.md, MAP.md and docs/AUDIT.md before changing behavior.
- This is a standalone repository. Never add dependencies on a sibling checkout or absolute developer paths.
- Preserve uncommitted work. Use build.sh, check.sh and package.sh (wrappers over scripts/jot_build.py); installation requires an explicit request and a quit app.
- Keep the bundle ID (`com.jacob.jot`), stored preference keys, the notes folder and the hotkey defaults stable unless a migration is designed and verified. Notes are the user's files: a save must never drop frontmatter Jot doesn't own, and nothing may delete or rewrite a note without a verified backup or Undo.
- Compile all top-level Sources/*.swift. Metadata, frameworks and entitlements belong in Info.plist, scripts/app.json and Jot.entitlements.
- Never test against real notes, preferences, reminders, Apple Notes, Stickies or the clipboard, and never launch a second production instance. Use ./test.sh and ./preview.sh, which run isolated.
- Jot makes no network requests and test.sh enforces it. Keep it that way.
- Update MAP.md, docs/FEATURES.md, version metadata and docs/AUDIT.md for behavior changes. Add GOTCHAS entries for non-obvious fixes. Add an `expect` to the preview walkthrough for any new shortcut, window rule or storage behavior.
- The MIT license covers Jot's own code. Do not add third-party code without preserving its license and notices.
- Building on one Mac does not prove support for every macOS version or real Intel hardware. Report remaining gaps accurately.
