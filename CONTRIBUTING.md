# Contributing to Jot

Read README.md and AGENTS.md first. Keep changes focused and use temporary fixtures for notes, preferences, reminders and the pasteboard. Never commit credentials, personal notes, user preferences, generated installers or local caches.

Run `./check.sh` for code changes. For UI changes, also run `./build.sh && ./preview.sh` in a macOS GUI session and look at the screenshots it writes. For packaging changes, run `./package.sh` and `hdiutil verify dist/Jot.dmg`. Document tested behavior and remaining limitations in docs/AUDIT.md.

App behavior is separate from Apple notarization. Local ad-hoc signing supports development; it does not remove recipient Gatekeeper prompts. Developer ID signing and notarization are done by the maintainer with `./release.sh` (see docs/RELEASE.md).

Changes to Jot are contributed under the repository's MIT license.
