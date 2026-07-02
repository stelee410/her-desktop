#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TEST_FLAGS="${SWIFT_TEST_FLAGS:---jobs 1}"
BUILD_FLAGS="${SWIFT_BUILD_FLAGS:---jobs 1}"

read -r -a SWIFT_TEST_FLAGS_ARRAY <<< "$TEST_FLAGS"
read -r -a SWIFT_BUILD_FLAGS_ARRAY <<< "$BUILD_FLAGS"

echo "==> Checking tracked files for secrets"
scripts/check-secrets.sh

if command -v swift-format >/dev/null 2>&1; then
  echo "==> Running swift-format lint"
  swift-format lint --recursive Sources Tests Package.swift
else
  echo "==> swift-format not found; skipping optional lint"
fi

echo "==> Running Swift tests"
swift test "${SWIFT_TEST_FLAGS_ARRAY[@]}"

echo "==> Building app bundle"
SWIFT_BUILD_FLAGS="$BUILD_FLAGS" scripts/build-app.sh

if [[ "${HER_VERIFY_APP_LAUNCH:-0}" == "1" ]]; then
  echo "==> Running packaged app launch smoke"
  scripts/smoke-app-launch.sh
fi

echo "==> Local verification passed"
