# Rocky as a networked robot body

Giving Rocky a body: a Makeblock mBot2, with the laptop as the brain and a thin CyberOS agent on
the CyberPi handling motion and telemetry. Independent from [`apps/cyberpi`](../cyberpi/README.md)
(that track is native-firmware on-device audio; this one keeps mic/speaker on the laptop) — see
`PLAN.md` for how the two relate.

**North star:** Rocky navigates a room, finds a person, follows them, and talks to them, without
crashing.

- [`PLAN.md`](PLAN.md) — the architecture, the three open questions answered, and the build order
  toward the north star. Start here.
- [`STEPS.md`](STEPS.md) — the ordered test list. Software-only steps are done (25 tests passing,
  no hardware needed); hardware steps are queued for when a board is physically available.
- [`docs/mbuild-api-surface.md`](docs/mbuild-api-surface.md) — the mBot2 Shield's real API,
  checked against actual device examples (not just the generated PyPI package), and why the
  original plan's OTA claim didn't hold up.
- [`src/`](src) — the laptop-side SDK (`@rocky/robot`): `protocol.ts`, `transport.ts`, `robot.ts`.
- [`device/rocky_agent.py`](device/rocky_agent.py) — the CyberOS agent. **Untested on hardware** —
  no board is attached in the environment this was written in. Don't trust it past `STEPS.md`'s
  step 5.

## Development

```bash
pnpm --filter @rocky/robot test       # protocol/transport/robot unit tests, no hardware needed
pnpm --filter @rocky/robot typecheck
pnpm robot:check                      # syntax-checks the device agent
```

`apps/robot/device/rocky_agent.py` is a single self-contained MicroPython file, uploaded through
mBlock 5 the same way as `apps/cyberpi`'s Stage-1 step files — mBlock uploads one program at a
time, so this pastes in whole with no imports from siblings.
