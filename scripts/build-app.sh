#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BIN_DIR="$(swift build -c release --show-bin-path)"
RESOURCE_BUNDLE_NAME="HerDesktop_HerDesktop.bundle"
rm -rf "$BIN_DIR/$RESOURCE_BUNDLE_NAME"
swift build -c release

APP_DIR="$ROOT/.build/app/HerDesktop.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
RESOURCE_BUNDLE="$BIN_DIR/$RESOURCE_BUNDLE_NAME"
APP_ICON="$ROOT/Assets/AppIcon.icns"

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

cp "$BIN_DIR/HerDesktop" "$MACOS/HerDesktop"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" "$RESOURCES/$RESOURCE_BUNDLE_NAME"
else
  echo "Missing SwiftPM resource bundle: $RESOURCE_BUNDLE" >&2
  exit 1
fi
if [[ -f "$APP_ICON" ]]; then
  cp "$APP_ICON" "$RESOURCES/AppIcon.icns"
else
  echo "Missing app icon: $APP_ICON" >&2
  exit 1
fi
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>HerDesktop</string>
  <key>CFBundleIdentifier</key>
  <string>co.linkyun.her-desktop</string>
  <key>CFBundleName</key>
  <string>Her Desktop</string>
  <key>CFBundleDisplayName</key>
  <string>Her Desktop</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Her Desktop uses the microphone for local voice dictation when you press the mic button.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Her Desktop uses speech recognition to turn your voice into composer text.</string>
</dict>
</plist>
PLIST

bundled_manifests=()
while IFS= read -r manifest; do
  bundled_manifests+=("$manifest")
done < <(find "$ROOT/Sources/HerDesktop/Resources/BuiltinPlugins" -name '*.plugin.json' -type f -exec basename {} \; | sort)
if [[ "${#bundled_manifests[@]}" -eq 0 ]]; then
  echo "No bundled plugin manifests found" >&2
  exit 1
fi

for manifest in "${bundled_manifests[@]}"; do
  if [[ ! -f "$RESOURCES/$RESOURCE_BUNDLE_NAME/$manifest" ]]; then
    echo "Missing bundled plugin manifest: $manifest" >&2
    exit 1
  fi
done

for resource in workspace-plan.SKILL.md partner-brief.SKILL.md; do
  if [[ ! -f "$RESOURCES/$RESOURCE_BUNDLE_NAME/$resource" ]]; then
    echo "Missing bundled plugin resource: $resource" >&2
    exit 1
  fi
done
if [[ ! -f "$RESOURCES/AppIcon.icns" ]]; then
  echo "Missing app icon in bundle resources" >&2
  exit 1
fi

plutil -lint "$CONTENTS/Info.plist" >/dev/null

if [[ "${HER_SKIP_CODESIGN:-0}" != "1" ]]; then
  CODESIGN_IDENTITY="${HER_CODESIGN_IDENTITY:--}"
  codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP_DIR" >/dev/null
  codesign --verify --deep --strict --verbose=2 "$APP_DIR" >/dev/null
fi

DIST_DIR="$ROOT/.build/dist"
ZIP_PATH="$DIST_DIR/HerDesktop.zip"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
ditto -c -k --keepParent --sequesterRsrc --rsrc "$APP_DIR" "$ZIP_PATH"

echo "Built $APP_DIR"
echo "Archived $ZIP_PATH"
