#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${HER_DESKTOP_APP_DIR:-$ROOT/.build/app/HerDesktop.app}"
EXECUTABLE="$APP_DIR/Contents/MacOS/HerDesktop"
RESOURCE_BUNDLE="$APP_DIR/Contents/Resources/HerDesktop_HerDesktop.bundle"

if [[ ! -x "$EXECUTABLE" ]]; then
  echo "Missing app executable: $EXECUTABLE" >&2
  echo "Run scripts/build-app.sh first." >&2
  exit 1
fi

if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "Missing app resource bundle: $RESOURCE_BUNDLE" >&2
  exit 1
fi

for resource in SOUL.md INFINITI.md vibe-plugin-creator.plugin.json workspace.plugin.json; do
  if [[ ! -f "$RESOURCE_BUNDLE/$resource" ]]; then
    echo "Missing bundled resource: $resource" >&2
    exit 1
  fi
done

RUNTIME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/her-desktop-app-smoke.XXXXXX")"
CONFIG_PATH="$RUNTIME_DIR/config.json"
LOG_PATH="$RUNTIME_DIR/app.log"
cleanup() {
  if [[ -n "${PID:-}" ]] && kill -0 "$PID" >/dev/null 2>&1; then
    kill "$PID" >/dev/null 2>&1 || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$RUNTIME_DIR"
}
trap cleanup EXIT
chmod 700 "$RUNTIME_DIR"

cat > "$CONFIG_PATH" <<'JSON'
{
  "agentLLMBaseURL": "https://agentllm.linkyun.co",
  "agentLLMAPIKey": "",
  "agentLLMModel": "linkyun-default",
  "agentMemBaseURL": "https://agentmem.oyii.ai",
  "agentMemAPIKey": "",
  "agentCode": "her-desktop-smoke",
  "userID": "",
  "pluginDirectory": ".her/plugins",
  "speakAssistantReplies": false,
  "speechVoiceIdentifier": ""
}
JSON
chmod 600 "$CONFIG_PATH"

HER_CONFIG_PATH="$CONFIG_PATH" HER_DESKTOP_WORKSPACE_DIR="$RUNTIME_DIR" "$EXECUTABLE" >"$LOG_PATH" 2>&1 &
PID="$!"

sleep "${HER_APP_SMOKE_SECONDS:-4}"

if ! kill -0 "$PID" >/dev/null 2>&1; then
  echo "Her Desktop exited during launch smoke." >&2
  sed -n '1,160p' "$LOG_PATH" >&2 || true
  exit 1
fi

if [[ -e "/.her" ]]; then
  echo "Unexpected /.her exists; packaged app must not use the filesystem root for runtime state." >&2
  exit 1
fi

echo "Her Desktop app launch smoke passed (pid $PID, runtime $RUNTIME_DIR)."
