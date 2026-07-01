#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_DIR="$ROOT/.build/app/HerDesktop.app"
ZIP_PATH="$ROOT/.build/dist/HerDesktop.zip"
NOTARIZED_ZIP_PATH="$ROOT/.build/dist/HerDesktop-notarized.zip"

fail() {
  echo "notarize-app: $*" >&2
  exit 1
}

need_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required tool: $1"
}

need_tool xcrun
need_tool codesign
need_tool ditto
need_tool spctl

CODESIGN_IDENTITY="${HER_CODESIGN_IDENTITY:-}"
if [[ -z "$CODESIGN_IDENTITY" || "$CODESIGN_IDENTITY" == "-" ]]; then
  fail "set HER_CODESIGN_IDENTITY to a Developer ID Application identity before notarizing"
fi

HER_CODESIGN_IDENTITY="$CODESIGN_IDENTITY" "$ROOT/scripts/build-app.sh"

signature_details="$(codesign -dv "$APP_DIR" 2>&1 || true)"
if echo "$signature_details" | grep -q "Signature=adhoc"; then
  fail "app is ad-hoc signed; notarization requires Developer ID signing"
fi

auth_args=()
if [[ -n "${HER_NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  auth_args+=(--keychain-profile "$HER_NOTARY_KEYCHAIN_PROFILE")
elif [[ -n "${HER_NOTARY_KEY:-}" && -n "${HER_NOTARY_KEY_ID:-}" ]]; then
  auth_args+=(--key "$HER_NOTARY_KEY" --key-id "$HER_NOTARY_KEY_ID")
  if [[ -n "${HER_NOTARY_ISSUER:-}" ]]; then
    auth_args+=(--issuer "$HER_NOTARY_ISSUER")
  fi
elif [[ -n "${HER_NOTARY_APPLE_ID:-}" && -n "${HER_NOTARY_TEAM_ID:-}" ]]; then
  auth_args+=(--apple-id "$HER_NOTARY_APPLE_ID" --team-id "$HER_NOTARY_TEAM_ID")
  if [[ -n "${HER_NOTARY_PASSWORD:-}" ]]; then
    auth_args+=(--password "$HER_NOTARY_PASSWORD")
  fi
else
  fail "set HER_NOTARY_KEYCHAIN_PROFILE, or HER_NOTARY_KEY/HER_NOTARY_KEY_ID, or HER_NOTARY_APPLE_ID/HER_NOTARY_TEAM_ID"
fi

wait_flag="${HER_NOTARY_WAIT:-1}"
timeout="${HER_NOTARY_TIMEOUT:-30m}"
submit_args=(submit "$ZIP_PATH" "${auth_args[@]}")
if [[ "$wait_flag" == "1" ]]; then
  submit_args+=(--wait --timeout "$timeout")
fi

xcrun notarytool "${submit_args[@]}"

if [[ "$wait_flag" == "1" ]]; then
  xcrun stapler staple "$APP_DIR"
  xcrun stapler validate "$APP_DIR"
  spctl --assess --type execute --verbose=2 "$APP_DIR"
  rm -f "$NOTARIZED_ZIP_PATH"
  ditto -c -k --keepParent --sequesterRsrc --rsrc "$APP_DIR" "$NOTARIZED_ZIP_PATH"
  echo "Notarized archive: $NOTARIZED_ZIP_PATH"
else
  echo "Submitted for notarization without waiting. Staple after acceptance with: xcrun stapler staple \"$APP_DIR\""
fi

