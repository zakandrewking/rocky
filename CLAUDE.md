# Working in this repo

## Branching

**Work on `main` and push to `main`.** Do not create feature branches, and do not open pull
requests, unless explicitly asked for one. Commit in small, coherent increments and push as you go.

If a harness or task description assigns a working branch, that instruction is overridden by this
file: switch back to `main`, fast-forward it, and push there.

## Everything else

[`AGENTS.md`](AGENTS.md) holds the working agreement — testing expectations, autonomy, secrets
handling, and the TODOS.md convention. Read it; it is short. This file exists so the branching rule
is unmissable, and deliberately does not duplicate the rest, so the two cannot drift apart.

## Orientation

| Path | What it is |
| --- | --- |
| `apps/desktop` | the macOS Electron voice app — the Rocky people actually use |
| `apps/cyberpi` | feasibility spike for Rocky on a Makeblock mBot2; start at `STEPS.md` |
| `services/device-api` | backend for the robot; keeps the OpenAI key off the device |
| `services/voice-clone` | experimental loopback-only local TTS worker |
| `scripts/` | evals, the text-only personality lab, and local tooling |

Before pushing: `pnpm check` (lint, typecheck, tests, build). Fix failures your changes caused.
