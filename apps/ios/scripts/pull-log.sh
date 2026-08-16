#!/usr/bin/env bash
# Pulls Rocky's logs off the paired iPhone and prints them.
# Usage: apps/ios/scripts/pull-log.sh [device-name-substring] [tail-lines] [--world]
#
# Two files, and both come down every time:
#
#   session.log   the human story of the session. The answer to "it didn't work" / "it was slow":
#                 every turn is timed, so it says which leg was slow (user stopped -> response
#                 started -> first word -> first audio -> finished) rather than leaving it to
#                 guesswork.
#   world.jsonl   the structured record of what Rocky knew about her body and when -- state
#                 transitions, events, action lifecycle, salience decisions, response ledgers,
#                 all with correlation ids (see apps/ios/docs/embodiment.md). This is what
#                 answers "what robot state did she have when she said that", which the prose log
#                 cannot. Pass --world to tail this one instead of session.log.

set -euo pipefail
cd "$(dirname "$0")/.."

WORLD_ONLY=false
ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--world" ]; then WORLD_ONLY=true; else ARGS+=("$arg"); fi
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

if [ "$WORLD_ONLY" = true ]; then
  echo "==> last $TAIL_LINES lines of $WORLD_DEST"
  tail -n "$TAIL_LINES" "$WORLD_DEST"
else
  echo "==> last $TAIL_LINES lines of $DEST"
  tail -n "$TAIL_LINES" "$DEST"
  echo
  echo "==> world model also pulled to $WORLD_DEST (re-run with --world to read it)"
fi
