# Rocky as a networked robot body

Giving Rocky a body: a Makeblock mBot2, with a thin CyberOS agent on the CyberPi handling motion
and telemetry, controlled over Wi-Fi. Independent from [`apps/cyberpi`](../cyberpi/README.md)
(that track is native-firmware on-device audio) — see `PLAN.md` for how the two relate.

**Brain moved to iOS.** The original design put the laptop's mic/speaker/personality in the
control loop. As of the [`apps/ios`](../ios/README.md) pivot, an iPhone — mounted on or near the
robot — is Rocky's mic, speaker, camera, and face, for the much better on-device audio hardware
and AEC that entails. The laptop's role now is dev tooling: pushing code to both the CyberPi
(`scripts/push.mjs`, already working) and the iPhone (`apps/ios`'s deploy script). The CyberPi-side
design below (protocol, `rocky_agent.py`, obstacle reflex) doesn't change — it never cared which
kind of client was on the other end of the socket.

**North star:** Rocky navigates a room, finds a person, follows them, and talks to them, without
crashing.

- [`PLAN.md`](PLAN.md) — the architecture, the three open questions answered, and the build order
  toward the north star. Start here.
- [`STEPS.md`](STEPS.md) — the ordered test list. Software-only steps are done (25 tests passing,
  no hardware needed); the socket gate and OTA bootstrap have passed on real hardware; remaining
  hardware steps are queued.
- [`docs/mbuild-api-surface.md`](docs/mbuild-api-surface.md) — the mBot2 Shield's real API,
  checked against actual device examples (not just the generated PyPI package), and why the
  original plan's OTA claim didn't hold up (and how scripted OTA turned out to be real anyway).
- [`src/`](src) — the laptop-side SDK (`@rocky/robot`): `protocol.ts`, `transport.ts`, `robot.ts`.
  Also doubles as the reference implementation any client (laptop CLI, iOS) ports against.
- [`device/bootstrap.py`](device/bootstrap.py) — the OTA loader, uploaded once via mBlock. Owns
  Wi-Fi and the push listener; everything else is a payload pushed over the network from then on.
- [`device/rocky_agent.py`](device/rocky_agent.py) — the motion-control payload, matching
  `src/protocol.ts`. Pushed with `node scripts/push.mjs <board-ip> device/rocky_agent.py`. Verified
  through `STEPS.md` step 4b's socket/OTA gate; the command-handling logic itself is still queued
  for a live run past step 5.

## Development

```bash
pnpm --filter @rocky/robot test       # protocol/transport/robot unit tests, no hardware needed
pnpm --filter @rocky/robot typecheck
pnpm robot:check                      # syntax-checks the device agent
node apps/robot/scripts/push.mjs <board-ip> apps/robot/device/rocky_agent.py  # push to a live board
```

`apps/robot/device/*.py` are single self-contained MicroPython files — `bootstrap.py` because
mBlock uploads one program at a time, and payloads like `rocky_agent.py` because `bootstrap.py`
`exec()`s whatever it's pushed with no import machinery of its own.
