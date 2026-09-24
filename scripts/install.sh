#!/bin/bash
# install.sh — install mux0.app from the release zip into /Applications.
# Ships inside dist/ next to the zip. See usage() below for flags.
#
# The app is ad-hoc signed (no Developer ID, no notarization), so the only
# thing a user has to clear is the quarantine attribute — which this script
# strips after unpacking. Double-clicking mux0.app in Finder instead would
# need the right-click → Open dance on first launch.
set -euo pipefail

# Re-exec under bash when started through another shell (`zsh install.sh`),
# which is the default login shell on macOS.
if [ -z "${BASH_VERSION:-}" ]; then
    _mux0_self="$0"
    if [ -n "${ZSH_VERSION:-}" ]; then
        eval '_mux0_zself="${(%):-%x}"' 2>/dev/null || _mux0_zself=""
        if [ -f "$_mux0_zself" ]; then _mux0_self="$_mux0_zself"; fi
    fi
    exec bash "$_mux0_self" "$@"
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
ZIP=""
DEST=""
OPEN_APP=1
DRY_RUN=0
FORCE=0

usage() {
    cat <<'USAGE'
Usage: ./install.sh [options]

  --zip PATH     zip to install (default: the newest Mux0-*.zip next to me,
                 then mux0-*.zip, then any other *.zip)
  --dest DIR     where to put mux0.app (default: /Applications, falling back
                 to ~/Applications when /Applications is not writable)
  --no-open      install but do not launch the app
  --force        install even while mux0 is running (not recommended: the
                 running process keeps the old bundle open, and its window
                 state can be rewritten over the new install)
  --dry-run      print what would happen, change nothing
  -h, --help     this text

What it does: refuses to touch a running mux0, moves the previous app aside
as mux0-<old version>-backup.app, unpacks the zip with ditto, strips the
quarantine attribute, verifies the code signature and prints the version.
USAGE
}

die() { echo "install.sh: $*" >&2; exit 1; }
note() { echo "install.sh: $*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --zip)    ZIP="${2:?--zip needs a path}"; shift 2 ;;
        --dest)   DEST="${2:?--dest needs a path}"; shift 2 ;;
        --no-open) OPEN_APP=0; shift ;;
        --force)  FORCE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

# --- refuse to install over a running app -----------------------------------
# Replacing the bundle under a live process is how you get a window that looks
# like the old build and a settings file written by two versions at once, so
# the safe default is to stop and tell the user to quit mux0 first.
if [ "$FORCE" != "1" ]; then
    RUNNING=$(pgrep -x mux0 2>/dev/null || true)
    if [ -n "$RUNNING" ]; then
        # Only count processes that really are this app, not any binary named
        # mux0 (a checkout's test helper, for instance).
        LIVES=""
        for pid in $RUNNING; do
            path=$(ps -o comm= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//')
            case "$path" in
                */mux0.app/Contents/MacOS/mux0) LIVES="$LIVES $pid" ;;
            esac
        done
        if [ -n "$LIVES" ]; then
            note "mux0 is running (pid$LIVES) — quit it with Cmd-Q first,"
            note "or re-run with --force to install anyway."
            exit 1
        fi
    fi
fi

# --- locate the zip ---------------------------------------------------------
if [ -z "$ZIP" ]; then
    for pattern in 'Mux0-*.zip' 'mux0-*.zip' '*.zip'; do
        ZIP=$(ls -1t "$SCRIPT_DIR"/$pattern 2>/dev/null | grep -v '\.dmg$' | head -1 || true)
        [ -n "$ZIP" ] && break
    done
fi
[ -n "$ZIP" ] && [ -f "$ZIP" ] || die "no mux0 zip found next to install.sh (pass --zip PATH)"
note "package: $ZIP"

# --- pick the destination ---------------------------------------------------
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

# --- unpack to a temp dir, verify, then swap ---------------------------------
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

plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null || echo "?"; }
VERSION=$(plist_value CFBundleShortVersionString "$NEW/Contents/Info.plist")
BUILD=$(plist_value CFBundleVersion "$NEW/Contents/Info.plist")
note "version: v$VERSION (build $BUILD)"

if ! codesign --verify --deep --strict "$NEW" 2>/dev/null; then
    note "warning: code signature does not verify (the app may still run)"
fi

if [ "$DRY_RUN" = "1" ]; then
    [ -e "$TARGET" ] && note "would back up $TARGET as $(basename "$DEST")/mux0-$(plist_value CFBundleShortVersionString "$TARGET/Contents/Info.plist")-backup.app"
    note "would install v$VERSION to $TARGET"
    [ "$OPEN_APP" = "1" ] && note "would open $TARGET"
    exit 0
fi

# Back up whatever is there now. A previous install is *not* deleted outright:
# it is renamed aside, named after the version it carries, so rolling back is
# one `mv` and it is obvious which version you are rolling back to.
if [ -e "$TARGET" ]; then
    OLD_VERSION=$(plist_value CFBundleShortVersionString "$TARGET/Contents/Info.plist")
    OLD_BUILD=$(plist_value CFBundleVersion "$TARGET/Contents/Info.plist")
    BACKUP="$DEST/mux0-$OLD_VERSION-backup.app"
    if [ -e "$BACKUP" ]; then
        BACKUP="$DEST/mux0-$OLD_VERSION-backup-$(date +%Y%m%d-%H%M%S).app"
    fi
    note "existing mux0 v$OLD_VERSION (build $OLD_BUILD) → $(basename "$BACKUP")"
    mv "$TARGET" "$BACKUP"
    # Keep at most 3 backups so repeated installs cannot fill the disk.
    ls -1dt "$DEST"/mux0-*-backup*.app 2>/dev/null | tail -n +4 | while read -r old; do
        note "pruning old backup $(basename "$old")"
        rm -rf "$old"
    done
fi

note "installing to $TARGET"
# ditto (not cp) keeps the bundle's metadata and code signature intact.
ditto "$NEW" "$TARGET"

# Read the version back out of the *installed* bundle — that is the number the
# user's About panel will show, so it is the one worth printing.
note "installed: v$(plist_value CFBundleShortVersionString "$TARGET/Contents/Info.plist") \
(build $(plist_value CFBundleVersion "$TARGET/Contents/Info.plist")) at $TARGET"
codesign --verify --deep --strict "$TARGET" 2>/dev/null \
    && note "signature: ok" \
    || note "warning: signature does not verify on the installed copy"

if [ "$OPEN_APP" = "1" ]; then
    note "launching $TARGET"
    open "$TARGET"
else
    note "done — run it with: open '$TARGET'"
fi
