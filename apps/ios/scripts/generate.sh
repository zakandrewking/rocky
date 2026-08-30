#!/usr/bin/env bash
# Wraps `xcodegen generate` with the two things plain xcodegen can't do:
#   1. Bake secrets from the repo root .env into the built app's Info.plist (see project.yml's
#      Rocky* keys) so the phone needs no laptop server at runtime: OPENAI_API_KEY to mint its own
#      ephemeral Realtime secret, the selected local speech provider's credentials, and
#      GEMINI_API_KEY for the front-camera person-detection calls (PersonVision.swift, Gemini
#      Robotics-ER) -- deliberately a different model/provider than the voice session. Personal-
#      use tradeoff: unlike services/device-api's whole reason for existing, these keys are not
#      scoped or revocable without rotating them, so this only belongs on a phone you control.
#   2. Regenerate Rocky/Resources/RealtimeSessionConfig.json from the character registry and
#      session builder in services/device-api, so Rocky's session stays defined in one place.
# Anything missing from .env is baked as empty rather than failing -- the app still builds and
# degrades honestly (no OpenAI key: no session; incomplete selected speech credentials: a clear
# in-app error naming what must be regenerated).

set -euo pipefail
cd "$(dirname "$0")/.."

ENV_FILE="../../.env"

# Reads one KEY=value out of .env, or empty if the file or key is absent.
#
# The `|| true` matters: grep exits non-zero when a key simply isn't there, and under `set -e`
# that failure propagates out of the assignment and kills the build. An absent optional setting
# must read as empty, not as an error.
read_env() {
  [ -f "$ENV_FILE" ] || return 0
  grep -E "^$1=" "$ENV_FILE" | head -n1 | cut -d= -f2- || true
}

# Always exported, even empty: XcodeGen only expands ${VAR} when the variable is present in its
# process environment at all -- an unset (not just empty) var is left as the literal, unexpanded
# "${ROCKY_OPENAI_KEY_IOS}" string baked into the plist, which the app would then treat as a real
# (garbage) value instead of "none configured".
export ROCKY_OPENAI_KEY_IOS="$(read_env OPENAI_API_KEY)"
export ROCKY_HUME_KEY_IOS="$(read_env HUME_API_KEY)"
export ROCKY_HUME_VOICE_ID_IOS="$(read_env HUME_VOICE_ID)"
export ROCKY_ELEVENLABS_KEY_IOS="$(read_env ELEVENLABS_API_KEY)"
export ROCKY_ELEVENLABS_VOICE_ID_IOS="$(read_env ELEVENLABS_VOICE_ID)"
export ROCKY_ELEVENLABS_MODEL_IOS="$(read_env ROCKY_ELEVENLABS_MODEL)"
export ROCKY_SPEECH_PROVIDER_IOS="$(read_env ROCKY_SPEECH_PROVIDER)"
export ROCKY_GEMINI_KEY_IOS="$(read_env GEMINI_API_KEY)"
export ROCKY_VOICE_ENGINE_IOS="${ROCKY_VOICE_ENGINE:-$(read_env ROCKY_VOICE_ENGINE)}"

# ElevenLabs is the current release voice. The explicit setting remains one line in .env so a
# Hume rollback is deliberate and visible rather than coupled to which credentials happen to exist.
if [ -z "$ROCKY_SPEECH_PROVIDER_IOS" ]; then
  export ROCKY_SPEECH_PROVIDER_IOS="elevenlabs"
fi
if [ -z "$ROCKY_ELEVENLABS_MODEL_IOS" ]; then
  export ROCKY_ELEVENLABS_MODEL_IOS="eleven_v3_conversational"
fi
if [ -z "$ROCKY_VOICE_ENGINE_IOS" ]; then
  export ROCKY_VOICE_ENGINE_IOS="realtime"
fi

# Passed through to the dump script below.
#
# Written as if-blocks, not `[ -n "$X" ] && export ...`: under `set -e` a false test is a failing
# command, so the one-liner form aborts the whole build the moment a variable is simply unset.
for name in ROCKY_VOICE ROCKY_REALTIME_MODEL; do
  value="$(read_env "$name")"
  if [ -n "$value" ]; then
    export "$name=$value"
  fi
done

if [ -n "$ROCKY_OPENAI_KEY_IOS" ]; then
  echo "==> Baking OPENAI_API_KEY from .env (personal-device use only)"
fi
if [ "$ROCKY_SPEECH_PROVIDER_IOS" != "elevenlabs" ] && [ "$ROCKY_SPEECH_PROVIDER_IOS" != "hume" ]; then
  echo "ERROR: ROCKY_SPEECH_PROVIDER must be elevenlabs or hume" >&2
  exit 1
fi
if [ "$ROCKY_VOICE_ENGINE_IOS" != "realtime" ] && [ "$ROCKY_VOICE_ENGINE_IOS" != "er2" ]; then
  echo "ERROR: ROCKY_VOICE_ENGINE must be realtime or er2" >&2
  exit 1
fi
if [ "$ROCKY_ELEVENLABS_MODEL_IOS" != "eleven_v3_conversational" ] && [ "$ROCKY_ELEVENLABS_MODEL_IOS" != "eleven_flash_v2_5" ]; then
  echo "ERROR: ROCKY_ELEVENLABS_MODEL must be eleven_v3_conversational or eleven_flash_v2_5" >&2
  exit 1
fi
if [ "$ROCKY_SPEECH_PROVIDER_IOS" = "elevenlabs" ]; then
  if [ -n "$ROCKY_ELEVENLABS_KEY_IOS" ] && [ -n "$ROCKY_ELEVENLABS_VOICE_ID_IOS" ]; then
    echo "==> Speech provider: ElevenLabs ($ROCKY_ELEVENLABS_MODEL_IOS)"
  else
    echo "==> Speech provider: ElevenLabs, but credentials are incomplete"
  fi
elif [ -n "$ROCKY_HUME_KEY_IOS" ] && [ -n "$ROCKY_HUME_VOICE_ID_IOS" ]; then
  echo "==> Speech provider: Hume"
else
  echo "==> Speech provider: Hume, but credentials are incomplete"
fi
if [ -n "$ROCKY_GEMINI_KEY_IOS" ]; then
  echo "==> Gemini credentials found (front-camera person detection)"
else
  echo "==> No GEMINI_API_KEY in .env -- the camera panel can open but detection will fail"
fi
echo "==> Voice engine: $ROCKY_VOICE_ENGINE_IOS"

echo "==> Regenerating Rocky/Resources/RealtimeSessionConfig.json from session.ts"
node --disable-warning=MODULE_TYPELESS_PACKAGE_JSON scripts/dump-session-config.mjs

xcodegen generate
