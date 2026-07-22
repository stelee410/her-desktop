#!/usr/bin/env bash
set -euo pipefail

# Package the built HerDesktop.app into a distributable .dmg.
#
# Signs with a Developer ID Application identity when available (better than
# ad-hoc for download distribution), but does NOT overwrite the local
# /Applications install — a different signing identity would change the
# CDHash and silently invalidate the user's microphone TCC grant.
#
# Usage:
#   scripts/make-dmg.sh [version]
# Env:
#   HER_CODESIGN_IDENTITY  override the signing identity (default: Developer ID, else default resolution)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-0.1.0}"
APP_DIR="$ROOT/.build/app/HerDesktop.app"
DIST_DIR="$ROOT/.build/dist"
STAGE_DIR="$ROOT/.build/dmg-stage"
DMG_PATH="$DIST_DIR/HerDesktop-$VERSION.dmg"

# Prefer a Developer ID Application identity for downloadable builds.
if [[ -z "${HER_CODESIGN_IDENTITY:-}" ]]; then
  DEVID="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
  if [[ -n "$DEVID" ]]; then
    export HER_CODESIGN_IDENTITY="$DEVID"
    echo "make-dmg: signing with Developer ID: $DEVID"
  fi
fi

# Build the app bundle but leave the user's /Applications install untouched.
HER_SKIP_INSTALL=1 "$ROOT/scripts/build-app.sh"

[[ -d "$APP_DIR" ]] || { echo "make-dmg: missing $APP_DIR" >&2; exit 1; }

# Re-sign with the hardened runtime + secure timestamp — mandatory for Apple
# notarization. build-app.sh signs without these for the daily-driver install,
# so we re-sign here (Developer ID only; ad-hoc can't be notarized anyway).
if [[ -n "${HER_CODESIGN_IDENTITY:-}" && "${HER_CODESIGN_IDENTITY}" != "-" ]]; then
  codesign --force --options=runtime --timestamp --deep \
    --sign "$HER_CODESIGN_IDENTITY" "$APP_DIR" >/dev/null
  codesign --verify --deep --strict --verbose=2 "$APP_DIR" >/dev/null
fi

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR" "$DIST_DIR"
ditto "$APP_DIR" "$STAGE_DIR/HerDesktop.app"
ln -s /Applications "$STAGE_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "Her Desktop" \
  -srcfolder "$STAGE_DIR" \
  -ov -format UDZO \
  "$DMG_PATH" >/dev/null

rm -rf "$STAGE_DIR"

# Sign the DMG itself when we have a real identity (harmless if ad-hoc).
if [[ -n "${HER_CODESIGN_IDENTITY:-}" && "${HER_CODESIGN_IDENTITY}" != "-" ]]; then
  codesign --force --timestamp --sign "$HER_CODESIGN_IDENTITY" "$DMG_PATH" >/dev/null || true
fi

# Notarize + staple so the download opens with no Gatekeeper prompt. Uses a
# pre-configured notarytool keychain profile (default: notarytool-creds,
# shared with the VerveFlow project). Skip with HER_SKIP_NOTARIZE=1.
NOTARY_PROFILE="${NOTARYTOOL_KEYCHAIN_PROFILE:-notarytool-creds}"
if [[ "${HER_SKIP_NOTARIZE:-0}" != "1" ]] \
  && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "make-dmg: submitting to Apple notary service (this can take a few minutes)…"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  echo "make-dmg: notarized and stapled."
else
  echo "make-dmg: skipping notarization (profile '$NOTARY_PROFILE' unavailable or HER_SKIP_NOTARIZE=1)."
fi

echo "Created $DMG_PATH"
du -h "$DMG_PATH" | awk '{print $1}'
