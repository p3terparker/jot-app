#!/bin/bash
# jot-update — replace Jot on this Mac with the newest build from GitHub, in one command.
#
#   jot-update              the newest passing build (the "Current build" pre-release)
#   jot-update --dry-run    say what it would do; change nothing
#   jot-update --force      reinstall even if this build is already installed
#
# It runs only when you ask (or when Claude has just finished a wave of changes and runs it for you); it does not check on a
# schedule. Run it straight from GitHub so there is never an old copy: curl -fsSL <raw URL of this file> | bash
#
# Why it avoids the "unidentified developer" dialog and the password: the disk image is fetched with curl, which does not
# mark it as quarantined (a browser download does), so Gatekeeper never looks at it; and Jot is replaced where it already
# lives (/Applications is writable by admin users; otherwise ~/Applications, which is yours). Settings and notes are in your
# user folders, so they stay. Needs only what macOS ships: bash, curl, hdiutil, ditto, shasum, osascript, codesign.
#
# Privacy permissions: macOS ties Accessibility / Automation grants to the app's signature, and the CI build is ad-hoc signed,
# so a plain update would ask for them again. Set JOT_SIGNING_IDENTITY to a code-signing certificate from your keychain (see
# GOTCHAS.md) and this script re-signs the new copy with it, which keeps the grants across updates.
#
# Override with environment variables: JOT_REPO (default p3terparker/jot-app), JOT_DEST (the .app to replace).
set -euo pipefail

REPO="${JOT_REPO:-p3terparker/jot-app}"
BUNDLE_ID="com.jacob.jot"
STATE_DIR="$HOME/Library/Application Support/Jot Updater"
STATE="$STATE_DIR/installed"
channel="current-build"; dry=0; force=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry=1 ;;
        --force)   force=1 ;;
        -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "jot-update: unknown option $arg (try --help)" >&2; exit 2 ;;
    esac
done

say() { printf '%s\n' "$*"; }
die() { printf 'jot-update: %s\n' "$*" >&2; exit 1; }

api="https://api.github.com/repos/$REPO/releases/tags/$channel"
work="$(mktemp -d "${TMPDIR:-/tmp}/jot-update.XXXXXX")"
mount_point=""
cleanup() {
    if [ -n "$mount_point" ]; then hdiutil detach "$mount_point" -quiet -force >/dev/null 2>&1 || true; fi
    rm -rf "$work"
}
trap cleanup EXIT

# --- what is the newest build? (the release is recreated on every passing build, so its publish time says which one it is)
curl -fsSL -H 'Accept: application/vnd.github+json' "$api" -o "$work/release.json" \
    || die "couldn't read $api — are you online, and has a build passed? (no '$channel' release yet means none has)"
field() { grep -o "\"$1\": *\"[^\"]*\"" "$work/release.json" | head -1 | sed 's/^[^:]*: *"//; s/"$//' || true; }
published="$(field published_at)"
title="$(field name)"
dmg_url="$(grep -o '"browser_download_url": *"[^"]*\.dmg"' "$work/release.json" | head -1 | sed 's/^[^:]*: *"//; s/"$//' || true)"
[ -n "$dmg_url" ] || die "that release has no .dmg attached"
[ -n "$published" ] || published="unknown"
# The checksum the build workflow prints in the notes (escaped newlines in the JSON), when there is one.
want_sha="$(grep -o '"body": *"[^"]*\(\\"[^"]*\)*"' "$work/release.json" | grep -o '[0-9a-f]\{64\}' | head -1 || true)"

# --- where is Jot, and what is installed?
dest="${JOT_DEST:-}"
if [ -z "$dest" ]; then
    if [ -d "/Applications/Jot.app" ]; then dest="/Applications/Jot.app"
    elif [ -d "$HOME/Applications/Jot.app" ]; then dest="$HOME/Applications/Jot.app"
    else dest="$HOME/Applications/Jot.app"; fi
fi
installed=""; [ -f "$STATE" ] && installed="$(cat "$STATE")"
current_version="not installed"
if [ -d "$dest" ]; then
    current_version="$(defaults read "$dest/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?') ($(defaults read "$dest/Contents/Info" CFBundleVersion 2>/dev/null || echo '?'))"
fi

say "Newest:    ${title:-$channel} — published $published"
say "Installed: $current_version at $dest"
if [ "$installed" = "$published" ] && [ -d "$dest" ] && [ "$force" = 0 ]; then
    say "Already up to date."
    exit 0
fi
if [ "$dry" = 1 ]; then
    say "Would download $dmg_url"
    say "Would check SHA-256 ${want_sha:-(none listed in the release notes)}"
    say "Would quit Jot if it is running, replace $dest and open it again."
    exit 0
fi

# --- download (curl: not quarantined) and check it
say "Downloading…"
dmg="$work/Jot.dmg"
curl -fL --progress-bar "$dmg_url" -o "$dmg" || die "download failed"
if [ -n "$want_sha" ]; then
    got="$(shasum -a 256 "$dmg" | cut -d' ' -f1)"
    [ "$got" = "$want_sha" ] || die "checksum mismatch (got $got, release says $want_sha) — not installing"
    say "Checksum OK."
else
    say "No checksum in the release notes; skipping that check."
fi

mount_point="$work/mount"; mkdir -p "$mount_point"
hdiutil attach "$dmg" -nobrowse -readonly -quiet -mountpoint "$mount_point" || die "couldn't open the disk image"
src="$mount_point/Jot.app"
[ -d "$src" ] || die "no Jot.app inside the disk image"

# --- quit Jot (if it is running), swap, relaunch
if pgrep -x Jot >/dev/null 2>&1; then
    say "Quitting Jot…"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 40); do pgrep -x Jot >/dev/null 2>&1 || break; sleep 0.25; done
    pgrep -x Jot >/dev/null 2>&1 && die "Jot didn't quit — close it and run this again"
fi

mkdir -p "$(dirname "$dest")"
staged="$dest.updating"
rm -rf "$staged"
ditto "$src" "$staged" || die "couldn't copy the new Jot next to $dest"
xattr -cr "$staged" 2>/dev/null || true             # belt and braces: no quarantine mark, whatever fetched it
if [ -n "${JOT_SIGNING_IDENTITY:-}" ]; then
    # Same plain signature `./build.sh --identity` makes for a local certificate: it keeps macOS's Accessibility and Automation grants.
    codesign --force --sign "$JOT_SIGNING_IDENTITY" "$staged" || { rm -rf "$staged"; die "couldn't sign with \"$JOT_SIGNING_IDENTITY\" — is it in your keychain?"; }
    say "Signed with $JOT_SIGNING_IDENTITY (permissions you granted Jot are kept)."
else
    say "Note: this build is ad-hoc signed, so macOS may ask for Accessibility again (only the Stickies path needs it). Set JOT_SIGNING_IDENTITY to avoid that."
fi
if [ -d "$dest" ]; then
    rm -rf "$dest" || { rm -rf "$staged"; die "couldn't replace $dest (try JOT_DEST=\"$HOME/Applications/Jot.app\")"; }
fi
mv "$staged" "$dest"
mkdir -p "$STATE_DIR"; printf '%s' "$published" > "$STATE"

new_version="$(defaults read "$dest/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?') ($(defaults read "$dest/Contents/Info" CFBundleVersion 2>/dev/null || echo '?'))"
say "Installed $new_version. Opening Jot…"
open "$dest"
