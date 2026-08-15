#!/usr/bin/env bash
# Wraps `xcodegen generate` with the two things plain xcodegen can't do:
#   1. Bake secrets from the repo root .env into the built app's Info.plist (see project.yml's
#      Rocky* keys) so the phone needs no laptop server at runtime: OPENAI_API_KEY to mint its own
#      ephemeral Realtime secret, and the Hume credentials for Rocky's actual voice. Personal-use
#      tradeoff: unlike services/device-api's whole reason for existing, these keys are not scoped
#      or revocable without rotating them, so this only belongs on a phone you control.
#   2. Regenerate Rocky/Resources/RealtimeSessionConfig.json from the one real definition of
#      Rocky's persona (services/device-api/src/session.ts), so the two apps never drift.
# Anything missing from .env is baked as empty rather than failing -- the app still builds and
# degrades honestly (no OpenAI key: no voice at all; no Hume key: OpenAI's own voice instead).

set -euo pipefail
cd "$(dirname "$0")/.."

ENV_FILE="../../.env"

# Reads one KEY=value out of .env, or empty if the file or key is absent.
read_env() {
  [ -f "$ENV_FILE" ] || return 0
  grep -E "^$1=" "$ENV_FILE" | head -n1 | cut -d= -f2-
}

# Always exported, even empty: XcodeGen only expands ${VAR} when the variable is present in its
# process environment at all -- an unset (not just empty) var is left as the literal, unexpanded
# "${ROCKY_OPENAI_KEY_IOS}" string baked into the plist, which the app would then treat as a real
# (garbage) value instead of "none configured".
export ROCKY_OPENAI_KEY_IOS="$(read_env OPENAI_API_KEY)"
export ROCKY_HUME_KEY_IOS="$(read_env HUME_API_KEY)"
export ROCKY_HUME_VOICE_ID_IOS="$(read_env HUME_VOICE_ID)"

[ -n "$ROCKY_OPENAI_KEY_IOS" ] && echo "==> Baking OPENAI_API_KEY from .env (personal-device use only)"
if [ -n "$ROCKY_HUME_KEY_IOS" ] && [ -n "$ROCKY_HUME_VOICE_ID_IOS" ]; then
  echo "==> Baking Hume credentials from .env (Rocky speaks in her own voice)"
else
  echo "==> No Hume credentials in .env -- falling back to OpenAI's built-in voice"
fi

echo "==> Regenerating Rocky/Resources/RealtimeSessionConfig.json from session.ts"
node --disable-warning=MODULE_TYPELESS_PACKAGE_JSON scripts/dump-session-config.mjs

xcodegen generate
