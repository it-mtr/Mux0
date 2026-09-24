#!/bin/bash
# install.sh — install mux0.app from the release zip into /Applications.
#
# Ships inside dist/ next to the zip, so the whole distribution is:
#   unzip mux0-<version>-macos-universal.zip  (or just run this script)
#   ./install.sh
#
# The app is ad-hoc signed (no Developer ID, no notarization), so the only
# thing a user has to clear is the quarantine attribute — which this script
# strips after unpacking. Double-clicking mux0.app in Finder instead would
# need the right-click → Open dance on first launch.
#
# Usage:
#   ./install.sh [--zip <path>] [--dest <dir>] [--no-open] [--dry-run] [-h]
#
#   --zip PATH     zip to install (default: the newest mux0-*.zip next to me)
#   --dest DIR     where to put mux0.app (default: /Applications, falling back
#                  to ~/Applications when /Applications is not writable)
#   --no-open      install but do not launch the app
#   --dry-run      print what would happen, change nothing
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ZIP=""
DEST=""
OPEN_APP=1
DRY_RUN=0

die() { echo "install.sh: $*" >&2; exit 1; }
note() { echo "install.sh: $*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --zip)    ZIP="${2:?--zip needs a path}"; shift 2 ;;
        --dest)   DEST="${2:?--dest needs a path}"; shift 2 ;;
        --no-open) OPEN_APP=0; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help)
            sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

# --- locate the zip -------------------------------------------------------
if [ -z "$ZIP" ]; then
    ZIP=$(ls -1t "$SCRIPT_DIR"/mux0-*-universal.zip 2>/dev/null | head -1 || true)
    [ -n "$ZIP" ] || ZIP=$(ls -1t "$SCRIPT_DIR"/*.zip 2>/dev/null | head -1 || true)
fi
[ -n "$ZIP" ] && [ -f "$ZIP" ] || die "no mux0 zip found next to install.sh (pass --zip PATH)"
note "package: $ZIP"

# --- pick the destination -------------------------------------------------
if [ -z "$DEST" ]; then
    if [ -w /Applications ] || [ "$(id -u)" = "0" ]; then
        DEST=/Applications
    else
        DEST="$HOME/Applications"
        note "/Applications is not writable by $(id -un); using $DEST instead"
        note "(re-run with sudo to install system-wide: sudo ./install.sh --dest /Applications)"
    fi
fi
mkdir -p "$DEST"
TARGET="$DEST/mux0.app"

# --- unpack to a temp dir, verify, then swap ------------------------------
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/mux0-install.XXXXXX")
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

note "unpacking…"
unzip -q -o "$ZIP" -d "$STAGE"
[ -d "$STAGE/mux0.app" ] || die "zip does not contain mux0.app at its root"
NEW="$STAGE/mux0.app"

# Quarantine: set by browsers / AirDrop; blocks an ad-hoc signed app on first
# launch. Removing it is what makes "unzip → run install.sh" work with a plain
# double-click afterwards.
xattr -dr com.apple.quarantine "$NEW" 2>/dev/null || true

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
          "$NEW/Contents/Info.plist" 2>/dev/null || echo "?")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
        "$NEW/Contents/Info.plist" 2>/dev/null || echo "?")
note "version: v$VERSION (build $BUILD)"

if ! codesign --verify --deep --strict "$NEW" 2>/dev/null; then
    note "warning: code signature does not verify (the app may still run)"
fi

if [ "$DRY_RUN" = "1" ]; then
    [ -e "$TARGET" ] && note "would back up $TARGET"
    note "would install v$VERSION to $TARGET"
    [ "$OPEN_APP" = "1" ] && note "would open $TARGET"
    exit 0
fi

# Back up whatever is there now. A previous install is *not* deleted outright:
# it is renamed aside so a bad download is one `mv` away from being undone.
if [ -e "$TARGET" ]; then
    STAMP=$(date +%Y%m%d-%H%M%S)
    BACKUP="$DEST/mux0.app.bak-$STAMP"
    note "existing app found, moving it to $(basename "$BACKUP")"
    mv "$TARGET" "$BACKUP"
    # Keep at most 3 backups so repeated installs cannot fill the disk.
    ls -1dt "$DEST"/mux0.app.bak-* 2>/dev/null | tail -n +4 | while read -r old; do
        note "pruning old backup $(basename "$old")"
        rm -rf "$old"
    done
fi

note "installing to $TARGET"
# ditto (not cp) keeps the bundle's metadata and code signature intact.
ditto "$NEW" "$TARGET"

if [ "$OPEN_APP" = "1" ]; then
    note "launching $TARGET"
    open "$TARGET"
else
    note "done — run it with: open '$TARGET'"
fi
