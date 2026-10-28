# Releasing Jot

Jot currently produces **local previews**: ad-hoc signed, not notarized. A build passing the checks is a necessary release input, not evidence that Jot is ready for strangers on every Mac.

## Reproducible local validation

```sh
./check.sh                       # metadata, tooling tests, Swift regression checks
./build.sh && ./preview.sh       # isolated AppKit walkthrough of the native build (needs a GUI session)
./build.sh --universal
./check.sh --built --universal   # architectures, signature, license inside the bundle
./package.sh                     # tests, universal build, dist/Jot.dmg (hdiutil-verified)
```

`Info.plist` owns the version and the stable bundle identity; `scripts/app.json` owns the frameworks, minimum macOS and entitlements file. Builds stage and validate artifacts before replacing generated output, and write only to `build/` and `dist/` inside the repository. Installation requires `--install` and refuses a running app.

Deterministic tests use disposable fixtures, never your notes, preferences, reminders, Apple Notes, Stickies or clipboard. `test.sh` also fails if a networking API appears in the sources.

## Core app acceptance

New note; typing immediately followed by quit; switching notes during autosave; note windows (one editor per note); multi-select deletion with Undo; Recently Deleted restore; a write failure; legacy RTF notes converted at launch (backup byte-identical); first run (welcome note, ⌥⌘J); restart. `./check.sh` and `./preview.sh` cover the logic; the items in [AUDIT.md](AUDIT.md) ▸ Remaining manual gaps need a person on a real Mac:

- Apple Notes and Stickies delivery, including the Automation and Accessibility prompts and other system languages.
- VoiceOver speech, light/dark and Reduce Motion appearance, macOS 13–15 (the development Mac runs macOS 26), real Intel hardware.
- Multiple displays, Spaces and a notch or crowded menu bar (status-item placement).
- Hotkey conflicts with other apps (Carbon cannot report them) and the Login Items approval flow.

Run these on the oldest supported macOS and a current one, with Intel runtime coverage if shipping Intel. Cross-compiling a universal binary does not replace them. Record exact versions and results in [AUDIT.md](AUDIT.md).

## Public distribution gates

Apple documents [Developer ID signing, hardened runtime, and notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) for distribution outside the App Store. A local or self-signed identity supports development; it is not a Developer ID release identity.

Before public shipping:

- Obtain a Developer ID Application certificate and a notarytool keychain profile (below), notarize and staple the app and the disk image, and verify a downloaded installer that keeps its quarantine flag launches normally. Removing quarantine is not the distribution workflow.
- Review entitlements against behavior. `Jot.entitlements` declares only `com.apple.security.automation.apple-events`, which sending to Apple Notes and Stickies needs under the hardened runtime (without it Apple Events fail with error -1743 and no prompt).
- Decide the owner items: support and privacy pages (the privacy position is "no network access"), the copyright line (`NSHumanReadableCopyright`), and the icon (macOS 26 prefers an Icon Composer asset).
- Choose an update mechanism. Today an update is a newer installer replacing the app; notes and settings stay in place.
- Run the gated spikes only with the owner present: S2 (Stickies, creates real stickies) and S3 (Apple Notes richer HTML, creates one real note). See [AUDIT.md](AUDIT.md) ▸ Not done.

## Releasing Jot (Developer ID)

1. Install your **Developer ID Application** certificate and store notarization credentials once:
   `xcrun notarytool store-credentials PROFILE --apple-id you@example.com --team-id TEAMID` (it asks for an app-specific password).
2. Preview the whole sequence without running it:
   `./release.sh --identity "Developer ID Application: Your Name (TEAMID)" --notary-profile PROFILE --dry-run`
3. Run it without `--dry-run`. It runs the tests, builds a universal Jot signed with the hardened runtime, a secure timestamp and `Jot.entitlements`, notarizes and staples the app, packages it into `dist/Jot.dmg`, signs, notarizes and staples the image, then runs `check --release` on the bundle.
4. Publish the result (for example `gh release create v3.0 dist/Jot.dmg --title "Jot 3.0" --notes-file docs/releases/v3.0.md`) and record its SHA-256 and the verification in [AUDIT.md](AUDIT.md).

Local builds (`build.sh`, `package.sh`) are unchanged by all of this: ad-hoc or your own stable identity, no hardened runtime unless you pass `--hardened`, not notarized. `./build.sh --hardened` is a useful local smoke test of the release configuration (hardened runtime plus entitlements, ad-hoc signed).

`./check.sh --release --universal` checks a built bundle for Developer ID, hardened runtime and a stapled ticket; it does not obtain credentials or submit anything.
