#!/bin/bash
# package-release.sh — build mux0.app in Release, ad-hoc sign it, and emit the
# distributable artifacts into dist/ (zip + install.sh + sha256 + checksum file).
#
# This is the *fork* release path: upstream ships through GitHub Actions
# (.github/workflows/release.yml) with a Developer ID + notarization + Sparkle
# appcast. This fork is built and distributed locally, so the artifact is
# ad-hoc signed and users install with scripts/install.sh instead of Sparkle.
#
# Usage:
#   ./scripts/package-release.sh              # build + package
#   SKIP_BUILD=1 ./scripts/package-release.sh # repackage the last build
#
# Environment:
#   CONFIG=Release              build configuration
#   CODE_SIGN_IDENTITY="-"      ad-hoc signing identity (default)
#   MUX0_SPM_DIR=/tmp/mux0-spm  pre-resolved SwiftPM dir holding Sparkle
#                               offline (see docs/build.md#sparkle-离线解析)
#   DERIVED_DATA=<path>         Xcode DerivedData (default: Xcode's own)
#   SKIP_BUILD=1                reuse the product already in DerivedData
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONFIG="${CONFIG:-Release}"
DIST="$ROOT/dist"
SPM_DIR="${MUX0_SPM_DIR:-/tmp/mux0-spm}"
# Ad-hoc by default. `${VAR-default}` (not `:-`) so an empty value still means
# "sign ad-hoc": xcodebuild treats CODE_SIGN_IDENTITY="" as "no identity".
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY-}"
if [ -z "$CODE_SIGN_IDENTITY" ]; then CODE_SIGN_IDENTITY="-"; fi

say() { echo "package-release: $*"; }
die() { echo "package-release: $*" >&2; exit 1; }

cd "$ROOT"
[ -d mux0.xcodeproj ] || die "mux0.xcodeproj missing — run: xcodegen generate"
[ -f Vendor/ghostty/lib/libghostty.a ] || die "Vendor/ghostty/lib/libghostty.a missing — run ./scripts/build-vendor.sh first"

# --- build ---------------------------------------------------------------
# Universal by default, same as upstream's release job (ARCHS="arm64 x86_64"
# ONLY_ACTIVE_ARCH=NO) — Vendor/ghostty/lib/libghostty.a ships both slices.
# Override with ARCHS=arm64 for a faster host-only build.
ARCHS="${ARCHS:-arm64 x86_64}"
BUILD_ARGS=(-project mux0.xcodeproj -scheme mux0 -configuration "$CONFIG"
            -destination 'platform=macOS'
            ARCHS="$ARCHS" ONLY_ACTIVE_ARCH=NO
            CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY"
            CODE_SIGN_STYLE=Manual
            DEVELOPMENT_TEAM="")
# Sparkle is fetched from GitHub, which is unreachable on the build box; point
# SwiftPM at the pre-resolved checkout + binary artifact instead. See docs/build.md.
if [ -d "$SPM_DIR" ]; then
    say "using pre-resolved SwiftPM packages at $SPM_DIR"
    BUILD_ARGS+=(-clonedSourcePackagesDirPath "$SPM_DIR"
                 -scmProvider system -skipPackageUpdates)
    export GIT_CONFIG_COUNT="${GIT_CONFIG_COUNT:-1}"
    export GIT_CONFIG_KEY_0="${GIT_CONFIG_KEY_0:-url.$HOME/worker/cache/spm/Sparkle.git.insteadOf}"
    export GIT_CONFIG_VALUE_0="${GIT_CONFIG_VALUE_0:-https://github.com/sparkle-project/Sparkle}"
fi
if [ -n "${DERIVED_DATA:-}" ]; then
    BUILD_ARGS+=(-derivedDataPath "$DERIVED_DATA")
fi

if [ "${SKIP_BUILD:-0}" != "1" ]; then
    say "building ${CONFIG}…"
    xcodebuild "${BUILD_ARGS[@]}" build
fi

# --- locate the product --------------------------------------------------
SETTINGS_ARGS=(-project mux0.xcodeproj -scheme mux0 -configuration "$CONFIG")
[ -n "${DERIVED_DATA:-}" ] && SETTINGS_ARGS+=(-derivedDataPath "$DERIVED_DATA")
# -showBuildSettings prints "    KEY = VALUE"; cut on the first "=" instead of
# word-splitting so values containing spaces survive.
SETTINGS=$(xcodebuild "${SETTINGS_ARGS[@]}" -showBuildSettings 2>/dev/null)
setting() { echo "$SETTINGS" | sed -n "s/^ *$1 = //p" | head -1; }
PRODUCT_DIR=$(setting TARGET_BUILD_DIR)
WRAPPER=$(setting WRAPPER_NAME)
VERSION=$(setting MARKETING_VERSION)
BUILD_NO=$(setting CURRENT_PROJECT_VERSION)
APP="${PRODUCT_DIR:-}/${WRAPPER:-}"
[ -d "$APP" ] || die "built app not found (looked at $APP)"
say "product: $APP (v$VERSION build $BUILD_NO)"

# --- verify before packaging --------------------------------------------
PLIST="$APP/Contents/Info.plist"
got() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || echo ""; }
[ "$(got CFBundleShortVersionString)" = "$VERSION" ] || die "version mismatch in Info.plist"
codesign --verify --deep --strict --verbose=1 "$APP" || die "signature does not verify"

# The agent hook layer ships as a bundle resource; a missing file here means
# every agent icon silently stays grey in the field.
for f in agent-hooks/agent-hook.sh agent-hooks/pi-wrapper.sh \
         agent-hooks/pi-extension/mux0-status.js agent-hooks/grok-wrapper.sh \
         agent-hooks/agent-hook.py; do
    [ -e "$APP/Contents/Resources/$f" ] || die "bundle is missing Resources/$f"
done

ARCHS=$(lipo -archs "$APP/Contents/MacOS/"* 2>/dev/null | head -1)
say "architectures: ${ARCHS:-unknown}"
say "signature: $(codesign -dv "$APP" 2>&1 | awk -F= '/^Signature=/||/^Identifier=/{print $2}' | head -1)"

# --- assemble dist/ ------------------------------------------------------
mkdir -p "$DIST"
ZIP_NAME="mux0-${VERSION}-universal.zip"
ZIP="$DIST/$ZIP_NAME"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/mux0-pkg.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

# Work on a copy so the shipped bundle never carries build-machine xattrs, and
# strip quarantine so the first launch on *this* box is not blocked either.
ditto "$APP" "$STAGE/mux0.app"
xattr -cr "$STAGE/mux0.app" 2>/dev/null || true

say "writing $ZIP_NAME"
# --keepParent keeps mux0.app as the zip's single top-level entry, which is
# what install.sh and Finder's double-click expect.
ditto -c -k --keepParent "$STAGE/mux0.app" "$ZIP"

DMG_NAME="mux0-${VERSION}-universal.dmg"
# Upstream's release asset is mux0-<version>-universal.dmg (create-dmg + Developer
# ID + notarization on CI). Without a signing identity we cannot notarize, but we
# can still hand out the same container so muscle memory and any tooling that
# expects a .dmg keep working. install.sh reads the zip because a zip survives
# being copied around without the quarantine hula of a mounted volume.
DMG_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/mux0-dmg.XXXXXX")
mkdir -p "$DMG_STAGE/vol"
ditto "$STAGE/mux0.app" "$DMG_STAGE/vol/mux0.app"
ln -s /Applications "$DMG_STAGE/vol/Applications"
say "writing $DMG_NAME"
hdiutil create -quiet -volname "mux0 $VERSION" -srcfolder "$DMG_STAGE/vol" \
    -ov -format UDZO "$DIST/$DMG_NAME"
rm -rf "$DMG_STAGE"

install -m 0755 "$ROOT/scripts/install.sh" "$DIST/install.sh"
( cd "$DIST" && shasum -a 256 "$ZIP_NAME" "$DMG_NAME" > SHA256SUMS )
cat "$DIST/SHA256SUMS"

cat > "$DIST/RELEASE-NOTES-$VERSION.md" <<EOF
# mux0 $VERSION (build $BUILD_NO)

What's new
- **pi** is now a first-class agent: sidebar quick-action button, Settings → Agents
  toggle, live status (running / idle / needs input / finished with exit code),
  hover tooltip with the running tool and the last reply, and session resume.
  Injected per process via \`pi -e\`, so your own \`~/.pi\` is untouched.
- **Grok CLI** likewise: same status set plus resume (\`grok --resume <id>\`).
  Runs through a private \`GROK_HOME\` overlay, so \`~/.grok\` is untouched and the
  sessions it writes stay visible to \`grok --resume\` outside mux0.
- Both follow the existing per-agent switches: turn on the notifications toggle
  (auto-enabled on upgrade if you already had another agent on) and, separately,
  the resume toggle (off by default — it types a command into your new tabs).

Install
    unzip mux0-${VERSION}-universal.zip        # optional; install.sh does it
    ./install.sh                                 # → /Applications/mux0.app

Ad-hoc signed, not notarized: install.sh removes the quarantine attribute so a
plain double-click works. If you unzip by hand and Finder complains, right-click
→ Open once. Existing settings, workspaces and themes are preserved; installing
over an older mux0 moves the previous app to \`mux0.app.bak-<timestamp>\`.

Update checks are off in this build: the appcast in Info.plist belongs to the
upstream repo, and letting it run would replace this fork with an upstream
release. Settings → Update says so instead of offering a dead button.
EOF

say "dist/ contents:"
ls -lh "$DIST" | tail -n +2
say "ok"
