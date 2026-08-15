#!/usr/bin/env bash
# Wraps `xcodegen generate` with the one thing plain xcodegen can't do: pull the phone's
# device-api token out of the repo root .env so it's baked into the built app's Info.plist
# (project.yml's RockyDeviceToken) and never has to be typed on the phone or committed to git.
# Falls through to a plain `xcodegen generate` if .env or the rocky-ios token isn't there yet --
# the app still works, just falls back to manual entry (see ContentView.swift).

set -euo pipefail
cd "$(dirname "$0")/.."

ENV_FILE="../../.env"
IOS_TOKEN=""
if [ -f "$ENV_FILE" ]; then
  TOKENS_LINE=$(grep -E '^ROCKY_DEVICE_TOKENS=' "$ENV_FILE" | head -n1 | cut -d= -f2-)
  # ROCKY_DEVICE_TOKENS is deviceId:token pairs, comma-separated -- pull out the one for "rocky-ios".
  IOS_TOKEN=$(echo "$TOKENS_LINE" | tr ',' '\n' | grep '^rocky-ios:' | head -n1 | cut -d: -f2-)
fi
# Always exported, even empty: XcodeGen only expands ${VAR} when the variable is present in its
# process environment at all -- an unset (not just empty) var is left as the literal, unexpanded
# "${ROCKY_DEVICE_TOKEN_IOS}" string baked into the plist, which the app would then treat as a
# real (garbage) token instead of "none configured, fall back to manual entry".
export ROCKY_DEVICE_TOKEN_IOS="$IOS_TOKEN"
if [ -n "$IOS_TOKEN" ]; then
  echo "==> Baking rocky-ios device token from .env into the build"
fi

xcodegen generate
