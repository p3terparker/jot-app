#!/bin/bash
# Isolated, Foundation-only regression checks. Never opens Jot, the network or the user's notes.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/jot-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

# Jot never touches the network. Keep it that way: the privacy story — "your notes never leave
# your Mac" — is only true while this stays empty.
if grep -n -E "URLSession|NSURLConnection|WKWebView|CFNetwork|NWConnection|nw_connection" "$HERE"/Sources/*.swift; then
  echo "error: a network API appeared in Jot's sources" >&2; exit 1
fi

S="$HERE/Sources"
T="$HERE/Tests"
xcrun swiftc -swift-version 5 \
  "$S/NoteStorage.swift" "$S/NoteLibrary.swift" "$S/Migrations.swift" "$S/Fixtures.swift" "$S/LegacyRTF.swift" \
  "$S/MarkdownCore.swift" "$S/MarkdownEdit.swift" "$S/SidebarGeometry.swift" "$S/WelcomeNote.swift" \
  "$S/MarkdownHTML.swift" "$S/SendErrors.swift" \
  "$T/MarkdownChecks.swift" "$T/MarkdownEditChecks.swift" "$T/main.swift" \
  -o "$TEST_DIR/jot-tests"
"$TEST_DIR/jot-tests"
