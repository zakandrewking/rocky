#!/usr/bin/env bash
# Builds and installs Rocky on a paired iPhone over Wi-Fi -- no cable, no App Store/TestFlight.
# Usage: apps/ios/scripts/deploy.sh [device-name-substring]
#
# One-time setup this script can't do for you:
#   1. Sign in to Xcode with your Apple ID once (Settings > Accounts) -- personal free/paid team
#      is fine, this project is not for the App Store.
#   2. Plug the iPhone in over USB once, trust the computer, and in the phone's Settings >
#      Privacy & Security > Developer Mode, turn Developer Mode on (reboots the phone). Without
#      this, install fails with "the developer disk image could not be mounted" even though the
#      build itself is fine.
#   3. In Xcode's Window > Devices and Simulators, select the phone and enable "Connect via
#      network" so later installs don't need the cable.
# After that, this script is the whole loop: build, install, launch.

set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="family.rocky.ios"
NAME_FILTER="${1:-iPhone}"

if ! command -v xcodegen >/dev/null; then
  echo "xcodegen not found -- install with: brew install xcodegen" >&2
  exit 1
fi

echo "==> Regenerating Rocky.xcodeproj from project.yml"
xcodegen generate >/dev/null

# xcodebuild and devicectl each use their own device-id format for the same physical phone
# (confirmed the hard way: devicectl's id is rejected by `xcodebuild -destination id=`) -- so
# this looks the device up twice, once per tool, matched by name rather than id.

echo "==> Finding \"$NAME_FILTER\" via xcodebuild -showdestinations"
XCODE_DEST_LINE=$(xcodebuild -showdestinations -project Rocky.xcodeproj -scheme Rocky 2>/dev/null \
  | grep "platform:iOS," | grep -i "$NAME_FILTER" | grep -v "error:" | grep -v "placeholder" | head -n1)
if [ -z "$XCODE_DEST_LINE" ]; then
  echo "No available physical device matching \"$NAME_FILTER\" in xcodebuild's destination list." >&2
  echo "Run: xcodebuild -showdestinations -project Rocky.xcodeproj -scheme Rocky" >&2
  exit 1
fi
XCODE_DEVICE_ID=$(echo "$XCODE_DEST_LINE" | sed -E 's/.*id:([^,}]+).*/\1/' | sed -E 's/ *$//')
DEVICE_NAME=$(echo "$XCODE_DEST_LINE" | sed -E 's/.*name:([^,}]+).*/\1/' | sed -E 's/ *$//')
echo "    -> $DEVICE_NAME ($XCODE_DEVICE_ID)"

DERIVED_DATA="build/DerivedData"
echo "==> Building (Debug, automatic signing)"
xcodebuild \
  -project Rocky.xcodeproj \
  -scheme Rocky \
  -configuration Debug \
  -destination "id=$XCODE_DEVICE_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  build

APP_PATH=$(find "$DERIVED_DATA/Build/Products/Debug-iphoneos" -maxdepth 1 -name "*.app" | head -n1)
if [ -z "$APP_PATH" ]; then
  echo "Build succeeded but no .app was found under $DERIVED_DATA -- can't install." >&2
  exit 1
fi

echo "==> Finding \"$DEVICE_NAME\" via devicectl for install/launch"
DEVICECTL_LINE=$(xcrun devicectl list devices 2>/dev/null | grep -F "$DEVICE_NAME" | grep -i "paired" | head -n1)
if [ -z "$DEVICECTL_LINE" ]; then
  echo "Built fine, but devicectl doesn't see \"$DEVICE_NAME\" as paired -- can't install/launch." >&2
  echo "Check: xcrun devicectl list devices" >&2
  exit 1
fi
DEVICECTL_ID=$(echo "$DEVICECTL_LINE" | awk '{print $(NF-2)}')

echo "==> Installing $APP_PATH"
xcrun devicectl device install app --device "$DEVICECTL_ID" "$APP_PATH"

echo "==> Launching $BUNDLE_ID"
xcrun devicectl device process launch --device "$DEVICECTL_ID" "$BUNDLE_ID"

echo "==> Done."
