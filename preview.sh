#!/bin/bash
# Isolated Jot walkthrough. Runs the BUILT bundle against a throwaway home, defaults suite, notes
# folder, pasteboard and notification stub (see Sources/Preview.swift). It never touches your notes,
# preferences, reminders or clipboard, registers no hotkey, and parks every window off-screen.
#
#   ./preview.sh [path/to/Jot.app] [output-dir]
#
# Writes PNGs and walkthrough.txt to the output directory. The exit status is non-zero unless the
# report ends with PREVIEW WALKTHROUGH OK. Build first: ./build.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${1:-$ROOT/build/native/Jot.app}"
OUT="${2:-$(mktemp -d "${TMPDIR:-/tmp}/jot-preview.XXXXXX")}"
BIN="$APP/Contents/MacOS/Jot"
[ -x "$BIN" ] || { echo "error: $BIN not found. Run ./build.sh first." >&2; exit 2; }
mkdir -p "$OUT"
FAKE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/jot-home.XXXXXX")"
trap 'rm -rf "$FAKE_HOME"' EXIT

# Metadata only (names, sizes, modification times): proves whether anything under your real Jot data
# or preferences moved while the walkthrough ran. Contents are never read.
REAL="$HOME/Library/Application Support/Jot"
PREFS="$HOME/Library/Preferences/com.jacob.jot.plist"
fingerprint() {
  { find "$REAL" -type f -exec stat -f '%N %z %m' {} + 2>/dev/null || true
    stat -f '%N %z %m' "$PREFS" 2>/dev/null || true; } | sort
}
BEFORE="$(fingerprint)"

set +e
HOME="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" \
  "$BIN" --jot-preview --jot-preview-snapshots "$OUT" 2> "$OUT/stderr.txt"
STATUS=$?
set -e

AFTER="$(fingerprint)"
if [ "$BEFORE" != "$AFTER" ]; then
  echo "note: a file under your real Jot data or preferences changed while this ran." >&2
  echo "      A running Jot may have autosaved; the preview itself only uses its own temporary tree." >&2
fi

VERDICT="$(tail -n 1 "$OUT/walkthrough.txt" 2>/dev/null || echo 'no report written')"
echo "$VERDICT   (exit $STATUS; report and PNGs: $OUT)"
[ "$VERDICT" = "PREVIEW WALKTHROUGH OK" ] || exit 1
