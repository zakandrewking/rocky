#!/usr/bin/env bash
# Wraps `xcodegen generate` with the two things plain xcodegen can't do:
#   1. Bake the real OPENAI_API_KEY from the repo root .env into the built app's Info.plist
#      (project.yml's RockyOpenAIKey) so the phone can mint its own ephemeral Realtime secret
#      directly from OpenAI -- no laptop server needed at runtime. Personal-use tradeoff: unlike
#      services/device-api's whole reason for existing, this key is not scoped or revocable
#      without rotating it, so this only belongs on a phone you control (see project history).
#   2. Regenerate Rocky/Resources/RealtimeSessionConfig.json from the one real definition of
#      Rocky's persona (services/device-api/src/session.ts), so the two apps never drift.
# Falls through to a plain `xcodegen generate` if .env has no OPENAI_API_KEY yet -- the app still
# builds, voice just fails to connect until a key is baked in.

set -euo pipefail
cd "$(dirname "$0")/.."

ENV_FILE="../../.env"
API_KEY=""
if [ -f "$ENV_FILE" ]; then
  API_KEY=$(grep -E '^OPENAI_API_KEY=' "$ENV_FILE" | head -n1 | cut -d= -f2-)
fi
# Always exported, even empty: XcodeGen only expands ${VAR} when the variable is present in its
# process environment at all -- an unset (not just empty) var is left as the literal, unexpanded
# "${ROCKY_OPENAI_KEY_IOS}" string baked into the plist, which the app would then treat as a real
# (garbage) key instead of "none configured".
export ROCKY_OPENAI_KEY_IOS="$API_KEY"
if [ -n "$API_KEY" ]; then
  echo "==> Baking OPENAI_API_KEY from .env into the build (personal-device use only)"
fi

echo "==> Regenerating Rocky/Resources/RealtimeSessionConfig.json from session.ts"
node --disable-warning=MODULE_TYPELESS_PACKAGE_JSON scripts/dump-session-config.mjs

xcodegen generate
