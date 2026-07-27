# Rocky device API

The backend Rocky's robot body talks to. It exists for one reason above all others: **the OpenAI
API key must never live on the robot.** An mBot2 is a thing a child carries around and lends to a
friend; it is not a place to keep a credential that can spend money.

So the robot holds only a device token, and trades it for a short-lived OpenAI client secret.

```
CyberPi  --device token-->  device-api  --API key-->  OpenAI
         <--client secret--             <--secret--
```

## Running it

```bash
pnpm device-api          # from the repo root
```

Reads the repository `.env`. Relevant settings:

| Variable | Meaning |
| --- | --- |
| `OPENAI_API_KEY` | required for `/v1/device/session`; without it that route returns 503 |
| `ROCKY_DEVICE_TOKENS` | `deviceId:token` pairs, comma-separated. Tokens under 16 chars are ignored |
| `ROCKY_DEVICE_API_PORT` | default 8787 |
| `ROCKY_DEVICE_API_HOST` | default 0.0.0.0, so the robot on the LAN can reach it |

Generate a device token with `openssl rand -hex 24`.

## Endpoints

| Route | Auth | Purpose |
| --- | --- | --- |
| `GET /v1/health` | open | reachability and latency floor (step 8) |
| `POST /v1/probe/echo` | probe | uplink throughput measurement (step 9) |
| `GET /v1/probe/audio.wav` | probe | a generated tone the robot tries to play (step 10) |
| `POST /v1/probe/capture` | probe | receives a raw microphone capture and writes a playable WAV (step 5j) |
| `POST /v1/probe/report` | probe | saves step results under `local-data/cyberpi/` |
| `GET /v1/probe/ws` | open | answers a WebSocket upgrade with 101 (step 12) |
| `POST /v1/device/session` | **required** | mints an ephemeral OpenAI Realtime client secret |

"probe" auth means: open while `ROCKY_DEVICE_TOKENS` is unset, so the first hardware run needs no
setup, and locked the moment any token exists. `/v1/device/session` is never open, because it
spends money.

## Decoding CyberPi audio

`src/makeblockAudio.ts` converts what the robot's microphone produces into something a player
accepts. The hardware returns a 48-byte RIFF-flavoured header that is **not** valid WAV — its RIFF
size is 0 and it has no `data` chunk — followed by 16 kHz 8-bit mono PCM.

The decoder rebuilds a real 16-bit WAV, and infers the sign convention rather than assuming it: the
firmware never says whether 8-bit means unsigned (silence at 128) or signed (silence at 0), and
guessing wrong turns speech into buzzing. Averaging cannot tell them apart, because two's-complement
negatives wrap to high byte values and land the mean near 128 either way. Smoothness can — the wrong
reading puts a full-scale discontinuity at every zero crossing.

Captures land in `local-data/cyberpi/` as both `.wav` and the original `.raw`, so a conversion that
turns out wrong can be redone without another trip to the robot.

## Persona

`src/session.ts` imports `ROCKY_INSTRUCTIONS` from the desktop app rather than copying it, so
there is exactly one definition of who Rocky is. A device addendum is appended telling the persona
what the body cannot do — no spreadsheets, no files, everything heard rather than read.

The plan's `packages/rocky-core` extraction is the right long-term home for this. It is not worth
doing until Stage 1 clears its decision gate, so for now a relative import does the job and
`verbatimModuleSyntax` is off in `tsconfig.json` to permit it.

## Tests

```bash
pnpm --filter @rocky/device-api test
pnpm --filter @rocky/device-api typecheck
```

Both run as part of `pnpm check`.
