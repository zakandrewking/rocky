#!/usr/bin/env bash
# Pulls Rocky's session log off the paired iPhone and prints it.
# Usage: apps/ios/scripts/pull-log.sh [device-name-substring] [tail-lines]
#
# This is the answer to "it didn't work" / "it was slow": every turn is timed, so the log says
# which leg was slow (user stopped -> response started -> first word -> first audio -> finished)
# rather than leaving it to guesswork.

set -euo pipefail
cd "$(dirname "$0")/.."

NAME_FILTER="${1:-iPhone}"
TAIL_LINES="${2:-200}"
BUNDLE_ID="family.rocky.ios"
DEST="${TMPDIR:-/tmp}/rocky-session.log"

DEVICE_LINE=$(xcrun devicectl list devices 2>/dev/null | grep -F "$NAME_FILTER" | grep -vi "unavailable\|unpaired" | head -n1)
if [ -z "$DEVICE_LINE" ]; then
  echo "No paired device matching \"$NAME_FILTER\". Check: xcrun devicectl list devices" >&2
  exit 1
fi
DEVICE_ID=$(echo "$DEVICE_LINE" | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' | head -n1)

rm -f "$DEST"
xcrun devicectl device copy from \
  --device "$DEVICE_ID" \
  --domain-type appDataContainer \
  --domain-identifier "$BUNDLE_ID" \
  --source Documents/session.log \
  --destination "$DEST" >/dev/null

echo "==> last $TAIL_LINES lines of $DEST"
tail -n "$TAIL_LINES" "$DEST"
