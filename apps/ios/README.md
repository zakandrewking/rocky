# Rocky on iOS

Rocky's brain, moved off the laptop: an iPhone mounted on or near the mBot2, using its own
mic/speaker/camera instead of a laptop's or the CyberPi's. See
[`apps/robot/PLAN.md`](../robot/PLAN.md) for the full architecture and why this replaced the
original "laptop is the brain" design, and [`apps/cyberpi`](../cyberpi/README.md) for the
(independent, unaffected) native-firmware audio track this makes unnecessary for the robot body.

**This milestone is deliberately minimal**: prove mic → command → Wi-Fi → robot works, safely,
before spending any effort on personality or UI. On-device Speech-framework command words
(forward/back/left/right/stop), no OpenAI dependency yet. `AVAudioSession` is already configured
for `.voiceChat` mode (hardware echo cancellation) even though this milestone doesn't need
full-duplex audio — so the foundation is already right when Realtime/barge-in voice lands later,
without revisiting the audio session setup.

## Structure

```text
apps/ios/
├── project.yml                  — XcodeGen spec; regenerate the .xcodeproj from this, don't edit it
├── Rocky/
│   ├── Sources/
│   │   ├── RockyApp.swift        — @main entry point
│   │   ├── ContentView.swift     — the one screen: connect, listen, push a CyberPi payload
│   │   ├── VoiceCommandRecognizer.swift  — Speech framework, fixed vocabulary
│   │   ├── AudioSessionManager.swift     — AVAudioSession, voiceChat/AEC mode
│   │   ├── RobotProtocol.swift   — Swift port of apps/robot/src/protocol.ts (same wire spec)
│   │   ├── RobotTransport.swift  — TCP client (Network.framework) to rocky_agent.py
│   │   ├── Robot.swift           — the only thing app code should call (bounded commands)
│   │   ├── RobotController.swift — maps voice commands onto Robot calls
│   │   └── CyberPiPusher.swift   — Swift port of apps/robot/scripts/push.mjs (OTA to bootstrap.py)
│   └── Tests/
│       └── RobotProtocolTests.swift — mirrors protocol.ts's test coverage, no device needed
└── scripts/
    └── deploy.sh                 — build + install + launch on a paired iPhone, no cable
```

`Rocky.xcodeproj` and `Generated/` are gitignored — generated output, not source. Regenerate any
time `project.yml` or the file layout changes:

```bash
brew install xcodegen   # once
cd apps/ios && xcodegen generate
```

## Development

```bash
cd apps/ios
xcodegen generate
xcodebuild -project Rocky.xcodeproj -scheme Rocky -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Tests need no device or network. The app itself needs a real iPhone for the Speech framework and
a real Wi-Fi network reaching the CyberPi — the Simulator doesn't have a microphone or the local
network access this needs.

## Installing on a real iPhone

One-time setup (can't be scripted):

1. Sign in to Xcode with your own Apple ID (**Xcode → Settings → Accounts**). A free personal
   team is enough — this is sideloading, not the App Store, and `apps/ios/project.yml` already
   pins `DEVELOPMENT_TEAM` to a specific personal team so this never ends up on a work/org
   account's App Store Connect by accident. Change it there if you're setting this up under a
   different Apple ID.
2. Plug the iPhone in over USB once and trust the computer.
3. On the iPhone: **Settings → Privacy & Security → Developer Mode → on** (this reboots the
   phone). Skipping this is the single most common failure — the build succeeds but install fails
   with "the developer disk image could not be mounted," which looks like a build problem and
   isn't one.
4. In Xcode's **Window → Devices and Simulators**, select the phone and enable **Connect via
   network** so later installs don't need the cable.

After that:

```bash
apps/ios/scripts/deploy.sh            # matches any paired device with "iPhone" in its name
apps/ios/scripts/deploy.sh "14 Pro"   # or narrow the match if more than one is paired
```

This builds, installs, and launches Rocky over Wi-Fi — no App Store, no TestFlight, no cable
after the one-time setup above. Free-account signing expires after about 7 days; redeploying
(which you'll be doing anyway during active development) resets that clock.

## OTA, both directions

- **Laptop → iPhone**: `scripts/deploy.sh` above. A real rebuild + reinstall each time, not a live
  patch — slower per-iteration than the CyberPi side below, but there's no simpler way to change
  actual Swift/UI code on a real device outside the App Store.
- **iPhone → CyberPi**: `CyberPiPusher.swift`, wired into the app's "Push Payload to CyberPi…"
  button. Same wire protocol as `apps/robot/scripts/push.mjs` — connects to `bootstrap.py`'s OTA
  port (8766), writes the picked file's bytes, half-closes, reads back the one-line reply. No
  laptop involved once `bootstrap.py` is on the board.
- **Laptop → CyberPi**: unchanged, already solved — `apps/robot/scripts/push.mjs`.

Deliberately not built: an in-app interpreter (e.g. JavaScriptCore) for live-patching *app* logic
without a rebuild. Considered and set aside for now — see the design note in the project history
if this becomes worth revisiting; the honest answer was "if we get serious about this we'll
probably switch approaches anyway."

## What's next

See `apps/robot/PLAN.md`'s build order and the north star it's working toward. In rough order
after this milestone: full OpenAI Realtime voice (reusing `services/device-api`'s ephemeral-secret
pattern and desktop Rocky's persona), camera-based person-finding, and the occupancy-grid
navigation layer -- all living on the iPhone, per that plan's architecture.
