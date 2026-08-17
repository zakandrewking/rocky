# Rocky's robot body

A Makeblock mBot2 running one CyberOS payload: an autonomous behaviour loop that listens to the
room and moves itself, streaming what it does to whoever is watching. Independent from
[`apps/cyberpi`](../cyberpi/README.md) (that track is native-firmware on-device audio) — see
`PLAN.md` for how the two relate.

**One agent.** `device/rocky_agent.py` is the payload. It is step16 of the loudness-driving
experiment — eleven versions and a live calibration run — plus an observation and intention layer:
it reports its own transitions on port 8768, and takes moods, gestures, mixed-move routines and a
stop back the other way. Those are *intentions*, honoured at the loop's own natural seams, not
commands; stop is the one real imperative. A routine queues 2–8 spins, wiggles, forward or
backward rolls, quick dashes, left/right turns, and turn-arounds as one interruptible, correlated
action, with the caller id and step on every physical transition. This lets voice tell a story
continuously while the movements run instead of starting a new voice turn for each move.
`scripts/check-behavior-parity.mjs` fails the build if any tuned constant drifts from
`steps/step16_loudness_drive_sticky.py`, which stays as the tuning record and the rollback.

The live payload boots in `still`, a hard motor interlock that bypasses every movement-producing
sensor and gesture path. Rocky must choose an awake disposition (`exploring`, `calm`, or
`excitable`) before the body can move; choosing `still` again stops current motion immediately.

**The commanded-motion agent is deprecated.** There used to be a second payload — a body that sat
still until told to drive or turn, over its own protocol on port 8765. It is frozen at
[`deprecated/motion_agent.py`](deprecated/motion_agent.py) and nothing pushes it. Only one payload
can run on the board at a time, so having two things called an agent (only one of which was being
developed) was a standing source of confusion in the app, the docs and the discovery sweep. It is
kept as the one worked example of that protocol on this hardware, and because `STEPS.md`'s
hardware gate was proved against it.

**Brain on iOS.** The original design put the laptop's mic/speaker/personality in the control loop.
As of the [`apps/ios`](../ios/README.md) pivot, an iPhone — mounted on or near the robot — is
Rocky's mic, speaker, camera and face, for the much better on-device audio hardware and AEC that
entails. The laptop's role now is dev tooling: pushing code to the CyberPi (`scripts/push.mjs`)
and to the iPhone (`apps/ios/scripts/deploy.sh`). How Rocky comes to *know* what the body is doing
is its own design: [`apps/ios/docs/embodiment.md`](../ios/docs/embodiment.md).

**North star:** Rocky navigates a room, finds a person, follows them, and talks to them, without
crashing.

- [`device/bootstrap.py`](device/bootstrap.py) — the OTA loader, uploaded once via mBlock. Owns
  Wi-Fi and the push listener; everything else is a payload pushed over the network from then on.
- [`device/rocky_agent.py`](device/rocky_agent.py) — the payload. Push it with
  `pnpm robot:push <board-ip> apps/robot/device/rocky_agent.py`.
- [`steps/`](steps) — the experiment history, including step16, the tuning record the live agent is
  held to.
- [`PLAN.md`](PLAN.md) — the architecture and the build order toward the north star. Written when
  the motion agent was the plan; see the note at its top.
- [`STEPS.md`](STEPS.md) — the ordered test list and what has passed on real hardware.
- [`docs/mbuild-api-surface.md`](docs/mbuild-api-surface.md) — the mBot2 Shield's real API, checked
  against actual device examples rather than the generated PyPI package.
- [`src/`](src) — **deprecated with the motion agent**: the laptop-side SDK for its wire protocol.
  Kept as the protocol's reference implementation and its test record; nothing live speaks it.

## Development

```bash
pnpm robot:check                                                    # syntax + unit/import checks + tuning parity
pnpm robot:push <board-ip> apps/robot/device/rocky_agent.py         # push to a live board
```

Press the board's Home button before any re-push: a running unbounded loop can stall the transfer
indefinitely (see `STEPS.md`).

`apps/robot/device/*.py` are single self-contained MicroPython files — `bootstrap.py` because
mBlock uploads one program at a time, and payloads like `rocky_agent.py` because `bootstrap.py`
`exec()`s whatever it's pushed with no import machinery of its own.
