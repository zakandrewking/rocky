# Rocky on iOS

Rocky's brain, moved off the laptop: an iPhone mounted on or near the mBot2, using its own
mic/speaker/camera instead of a laptop's or the CyberPi's. See
[`apps/robot/PLAN.md`](../robot/PLAN.md) for the full architecture and why this replaced the
original "laptop is the brain" design, and [`apps/cyberpi`](../cyberpi/README.md) for the
(independent, unaffected) native-firmware audio track this makes unnecessary for the robot body.

Rocky talks over real OpenAI Realtime voice (`gpt-realtime-2.1` — GPT-Live checked and confirmed
not API-accessible yet, see `TODOS.md`), connected directly to OpenAI over WebRTC
(`stasel/WebRTC`, no relay server), the same architecture `apps/desktop` uses. `drive_cm`,
`rotate_degrees`, `stop_robot`, `read_distance`, and `set_face` are real tool calls the model
picks arguments for — there's no fixed vocabulary anymore. `AVAudioSession` runs in `.voiceChat`
mode (hardware echo cancellation) so barge-in works the way it does on desktop.

## Structure

```text
apps/ios/
├── project.yml                  — XcodeGen spec (incl. the WebRTC SPM dependency); regenerate
│                                   the .xcodeproj from this, don't edit it
├── Rocky/
│   ├── Sources/
│   │   ├── RockyApp.swift        — @main entry point
│   │   ├── ContentView.swift     — the one screen: connect to the robot, connect to device-api, talk
│   │   ├── RealtimeWebRTCClient.swift — peer connection, data channel, SDP exchange with OpenAI
│   │   ├── RealtimeEvents.swift  — typed slice of the data-channel event schema (tool calls)
│   │   ├── RealtimeVoiceSession.swift — @MainActor session state + tool-call dispatch
│   │   ├── DeviceAPIClient.swift — mints an ephemeral OpenAI secret from services/device-api
│   │   ├── AudioSessionManager.swift     — AVAudioSession, voiceChat/AEC mode
│   │   ├── RobotProtocol.swift   — Swift port of apps/robot/src/protocol.ts (same wire spec)
│   │   ├── RobotTransport.swift  — TCP client (Network.framework) to rocky_agent.py
│   │   ├── Robot.swift           — the only thing app code should call (bounded commands)
│   │   ├── RobotController.swift — general drive/turn/stop/readDistance/setFace passthrough
│   │   └── CyberPiPusher.swift   — Swift port of apps/robot/scripts/push.mjs (OTA to bootstrap.py)
│   └── Tests/
│       └── RobotProtocolTests.swift — mirrors protocol.ts's test coverage, no device needed
└── scripts/
    └── deploy.sh                 — build + install + launch on a paired iPhone, no cable
```

### Talking to the robot: no manual setup, normally

The app needs `services/device-api` (`pnpm device-api`, on the laptop) to mint a short-lived
OpenAI secret — the real API key never touches the phone. Both things this needs are automatic:

- **device API host**: `DeviceAPIDiscovery.swift` scans the phone's own `/24` for something
  answering `GET /v1/health` on port 8787, the same active-scan pattern `RobotDiscovery` uses for
  the robot itself (see `NetworkUtilities.swift` for the shared subnet-detection code both use).
- **device token**: baked into the app at build time. `scripts/generate.sh` (used by
  `ios:check`/`ios:test`/`deploy.sh` — never call `xcodegen generate` directly) reads the
  `rocky-ios:` entry out of the repo root `.env`'s `ROCKY_DEVICE_TOKENS` (see `.env.example`;
  generate one with `openssl rand -hex 24`) and passes it to XcodeGen's environment-variable
  expansion (`project.yml`'s `RockyDeviceToken` Info.plist key), so it's never typed on the phone
  and never committed.

Both fields stay manually editable in-app (`UserDefaults`, not Keychain — deliberate for this
deliberately minimal, non-App-Store app; see `ContentView.swift`'s comment for the threat-model
reasoning) as a fallback if discovery or baking doesn't find anything, e.g. a fresh checkout with
no `.env` yet, or a laptop on a different subnet.

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
after this milestone: an actual live voice conversation with the robot (the WebRTC/tool-calling
path is built and the ephemeral-secret mint is confirmed working end to end, but no one has
talked to it yet), camera-based person-finding, and the occupancy-grid navigation layer -- all
living on the iPhone, per that plan's architecture.
