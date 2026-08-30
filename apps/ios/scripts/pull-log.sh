#!/usr/bin/env bash
# Pulls Rocky's logs off the paired iPhone and prints them.
# Usage: apps/ios/scripts/pull-log.sh [device-name-substring] [tail-lines]
#        [--voice|--controls|--vision|--raw|--world]
#
# Two files, and both come down every time:
#
#   session.log   the complete human story of the session. The default view filters its busy
#                 control/vision telemetry down to voice, audio, lifecycle, and errors. Use the
#                 targeted flags below when the reported behavior is physical or visual; `--raw`
#                 always preserves the old unfiltered tail.
#   world.jsonl   the structured record of what Rocky knew about her body and when -- state
#                 transitions, events, action lifecycle, salience decisions, response ledgers,
#                 all with correlation ids (see apps/ios/docs/embodiment.md). This is what
#                 answers "what robot state did she have when she said that", which the prose log
#                 cannot. Pass --world to tail this one instead of session.log.

set -euo pipefail
cd "$(dirname "$0")/.."

VIEW=voice
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --voice) VIEW=voice ;;
    --controls) VIEW=controls ;;
    --vision) VIEW=vision ;;
    --raw) VIEW=raw ;;
    --world) VIEW=world ;;
    *) ARGS+=("$arg") ;;
  esac
done

NAME_FILTER="${ARGS[0]:-iPhone}"
TAIL_LINES="${ARGS[1]:-200}"
BUNDLE_ID="family.rocky.ios"
DEST="${TMPDIR:-/tmp}/rocky-session.log"
WORLD_DEST="${TMPDIR:-/tmp}/rocky-world.jsonl"

DEVICE_LINE=$(xcrun devicectl list devices 2>/dev/null | grep -F "$NAME_FILTER" | grep -vi "unavailable\|unpaired" | head -n1)
if [ -z "$DEVICE_LINE" ]; then
  echo "No paired device matching \"$NAME_FILTER\". Check: xcrun devicectl list devices" >&2
  exit 1
fi
DEVICE_ID=$(echo "$DEVICE_LINE" | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' | head -n1)

pull() {
  rm -f "$2"
  # Not fatal: world.jsonl only exists once a session has actually run, and a missing one should
  # not stop the session log being printed.
  xcrun devicectl device copy from \
    --device "$DEVICE_ID" \
    --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" \
    --source "Documents/$1" \
    --destination "$2" >/dev/null 2>&1 || echo "(no $1 on the device yet)" >&2
}

pull session.log "$DEST"
pull world.jsonl "$WORLD_DEST"

SESSION_START_LINE=$(grep -nF '] voice: orb tapped, starting up' "$DEST" | tail -n1 | cut -d: -f1 || true)
latest_session() {
  if [ -n "$SESSION_START_LINE" ]; then
    tail -n "+$SESSION_START_LINE" "$DEST"
  else
    tail -n 5000 "$DEST"
  fi
}

case "$VIEW" in
  world)
    echo "==> last $TAIL_LINES lines of $WORLD_DEST"
    tail -n "$TAIL_LINES" "$WORLD_DEST"
    ;;
  raw)
    echo "==> last $TAIL_LINES raw lines of $DEST"
    tail -n "$TAIL_LINES" "$DEST"
    ;;
  controls)
    echo "==> last $TAIL_LINES robot/control lines of $DEST"
    { grep -E '\] (control|manual drive|behavior|robot|app):' "$DEST" || true; } \
      | tail -n "$TAIL_LINES"
    ;;
  vision)
    echo "==> last $TAIL_LINES vision/camera lines of $DEST"
    awk '
      /^\[/ { selected = ($0 ~ /\] (vision|camera|voice: vision)/) }
      selected { print }
    ' "$DEST" | tail -n "$TAIL_LINES"
    ;;
  voice)
    echo "==> recent errors and recovery events"
    { latest_session | grep -Ei 'error|failed|timed? ?out|quota|unacknowledged|no valid|connection lost|marked for refresh|replacing the suspended' || true; } \
      | tail -n 40
    echo
    echo "==> last $TAIL_LINES voice/audio/app lifecycle lines"
    { latest_session | grep -E '\] (voice|audio|app):' | grep -v '\] voice: vision:' || true; } \
      | tail -n "$TAIL_LINES"
    ;;
esac

echo
echo "==> complete session: $DEST · world: $WORLD_DEST"
echo "    views: --voice (default), --controls, --vision, --raw, --world"
