#!/bin/bash
# Developer ID build -> notarize -> staple -> disk image -> notarize -> staple.
# Needs your Developer ID certificate and a notarytool keychain profile. Try --dry-run first: it prints
# every step and runs none of them.
#   ./release.sh --identity "Developer ID Application: Your Name (TEAMID)" --notary-profile PROFILE [--dry-run]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
exec /usr/bin/python3 "$HERE/jot_build.py" release "$@"
