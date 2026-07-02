#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

git ls-files -z \
  | xargs -0 grep -nE 'sk-[A-Za-z0-9_-]{20,}|mem_[0-9A-Fa-f]{16,}' \
  >"$tmp_file" || true

if [[ -s "$tmp_file" ]]; then
  echo "Secret-like values were found in tracked files:" >&2
  cat "$tmp_file" >&2
  echo >&2
  echo "Move real keys to Config/her-desktop.local.json, HER_* environment variables, or the macOS Settings UI." >&2
  exit 1
fi

echo "No AgentLLM or AgentMem key patterns found in tracked files."
