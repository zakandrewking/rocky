# Rocky

Rocky is a local macOS voice companion for family conversations, science questions, and sudden
spreadsheets. Tap the rock, talk naturally, and Rocky answers with low-latency speech. When rows
and columns would help, Rocky creates an `.xlsx` workbook and pulls it onscreen in the open-source
ONLYOFFICE Spreadsheet Editor.

## First voice conversation

Requirements: macOS, Node.js, pnpm, a microphone, ONLYOFFICE Desktop Editors, and an OpenAI API
key with Realtime API access.

```bash
cp .env.example .env
# Put the OpenAI API key in .env, then:
pnpm install
brew install --cask onlyoffice
pnpm dev
```

Tap Rocky once and allow microphone access when macOS asks. Try saying:

> Rocky, help us invent a backyard science experiment.

Or test the spreadsheet handoff:

> Make a spreadsheet to score five imaginary planets by snacks, gravity, and fun.

During development, transcripts and workbooks are saved under the repository's ignored
`local-data/` directory:

- `local-data/transcripts/` contains one readable Markdown log per conversation.
- `local-data/spreadsheets/` contains Rocky's `.xlsx` workbooks.
- `local-data/memory.json` contains safe, volunteered names or nicknames, interests, favorites,
  recurring activities, and ongoing projects that Rocky can recall in later sessions.
- `local-data/continuity.json` contains a bounded rolling window of recent non-system turns so a
  restarted voice session can resume context instead of feeling like a blank new chat.
- `local-data/debug/rocky-state.jsonl` contains renderer state-machine diagnostics for stuck
  voice sessions: phase, peer state, data-channel state, response flags, and recent events.

Workbooks automatically open in [ONLYOFFICE Desktop Editors](https://github.com/ONLYOFFICE/DesktopEditors)
and its window is brought to the foreground. `local-data/` is intentionally excluded from Git.
Run `pnpm onlyoffice:install-plugin` once, then restart ONLYOFFICE, to let Rocky update the visible
active sheet in place. The hidden plugin polls an authenticated loopback-only bridge; its private token
stays under ignored local data and the current macOS user's ONLYOFFICE plugin directory.

Rocky updates memory through a narrowly scoped local tool. The app refuses memory facts containing
common sensitive-data categories, and the persona prompt tells Rocky not to request or retain
addresses, schools, contact details, credentials, health details, surnames, secrets, or guesses.
This is intentionally rudimentary; parental review and delete controls remain future work.

## Current model choice

GPT-Live is not available through the API yet, so Rocky currently uses `gpt-realtime-2.1` over
WebRTC. It supports direct speech-to-speech conversation, interruptions, transcription, and tool
calling. The model and preset voice are configurable without code changes:

```dotenv
ROCKY_REALTIME_MODEL=gpt-realtime-2.1
ROCKY_VOICE=cedar
```

Background research uses OpenAI Responses with web search, saves status/results under
`local-data/research/`, and defaults to a fast 20 second budget so Rocky does not leave the family
waiting on a multi-minute side quest. Tune it with:

```dotenv
ROCKY_RESEARCH_MODEL=gpt-5.5
ROCKY_RESEARCH_TIMEOUT_MS=60000
ROCKY_RESEARCH_REASONING_EFFORT=low
ROCKY_RESEARCH_MAX_OUTPUT_TOKENS=900
```

The standard API key stays in Electron's main process. The renderer receives only a short-lived
Realtime client secret. In development, Rocky reads the repository `.env`. In an installed app,
Rocky reads `~/Library/Application Support/Rocky/config.env`; do not put API keys in the app bundle,
Git commits, or GitHub Releases.

## Family Mac install

For another Mac, use the bootstrap script after a DMG has been published on GitHub Releases:

```bash
curl -fsSL https://raw.githubusercontent.com/zakandrewking/rocky/main/scripts/install-rocky-macos.sh | bash
```

The script:

- creates `~/Library/Application Support/Rocky/config.env` and prompts once for `OPENAI_API_KEY`;
- installs or checks ONLYOFFICE Desktop Editors via Homebrew when Homebrew is available;
- installs Rocky's hidden ONLYOFFICE plugin for live visible-sheet updates;
- downloads and opens the latest Rocky DMG from GitHub Releases.

Optional Hume settings can be supplied before running the script:

```bash
curl -fsSL https://raw.githubusercontent.com/zakandrewking/rocky/main/scripts/install-rocky-macos.sh \
  | HUME_API_KEY=... HUME_VOICE_ID=... bash
```

Rocky does not bundle ONLYOFFICE. Keeping ONLYOFFICE separate avoids a large app bundle and lets the
editor update independently. If Homebrew is not installed on the family Mac, install Homebrew from
<https://brew.sh> or install ONLYOFFICE Desktop Editors manually, then rerun the Rocky installer.

## Development

```bash
pnpm dev       # terminal launch with hot reload
pnpm check     # lint, strict typecheck, tests, and production build
pnpm eval:rocky # run text-mode Rocky persona evals before voice testing
pnpm review:rocky # review all saved Rocky utterances against the current style contract
pnpm text:rocky # interactive text-only personality/cadence lab
pnpm xlsx:rocky inspect local-data/spreadsheets/example.xlsx # inspect/edit .xlsx files from CLI
pnpm alien:demo # render an ignored WAV using the same Eridian chords as the live app
pnpm voice:hume:audition # generate three original Hume voice-design candidates (requires local key)
pnpm voice:hume:save -- 3 # save the selected candidate as a private Hume account voice
pnpm onlyoffice:install-plugin # install the live active-sheet bridge for the current macOS user
pnpm voice:check # verify optional ignored local voice-clone assets
pnpm voice:server # run the experimental loopback-only YourTTS worker
pnpm dist:mac  # create unsigned macOS DMG, zip, and unpacked app artifacts
```

The desktop app lives in `apps/desktop`. Spreadsheet generation is covered by tests and produces
real Excel workbooks with formatted headers, filters, frozen rows, and useful column widths.
DOCX generation is covered by structural tests for valid Word packages, real headings, numbering,
page geometry, and escaped/plain content. Visual DOCX render QA is still best-effort locally until
LibreOffice/Poppler are installed on the machine running tests.
`pnpm xlsx:rocky` provides command-line workbook operations for agent/debug workflows:

```bash
pnpm xlsx:rocky inspect local-data/spreadsheets/minecraft_biomes.xlsx 'Biomes!A1:D20'
pnpm xlsx:rocky set-cell local-data/spreadsheets/minecraft_biomes.xlsx 'Biomes!B2' Updated
pnpm xlsx:rocky append-row local-data/spreadsheets/minecraft_biomes.xlsx Biomes '["New biome","Notes"]'
```

The current command-line edit path rereads the workbook from disk before making targeted edits, so
it preserves other saved workbook changes. The remaining live-collaboration gap is forcing
ONLYOFFICE to save/sync the active open document before Rocky rereads it; that is tracked in
`TODOS.md`.

Rocky also has a `start_background_research` voice tool for current or obscure facts. Results are
saved under `local-data/research/`, appended to the conversation transcript, and injected back into
the live session when the slower web-backed answer is ready.

### macOS releases

Local unsigned release build:

```bash
pnpm dist:mac
```

Artifacts are written under `apps/desktop/release/`, including `Rocky-<version>-<arch>.dmg`.
Unsigned builds may require right-click Open or Gatekeeper approval on another Mac.

GitHub Releases are built by `.github/workflows/release-macos.yml` when a `v*` tag is pushed:

```bash
git tag v0.1.0
git push origin v0.1.0
```

The workflow runs `pnpm check`, builds the DMG/zip on macOS, and attaches them to a prerelease.
Code signing and notarization are still future work.

`pnpm alien:demo` writes `local-data/voice-clone/eridian-demo.wav`. Add words after `--` to audition
a custom line, for example `pnpm alien:demo -- "Rocky friend. Amaze!"`. This uses the same chord
mapping and timing as the live browser audio layer and does not make an API call.

For a higher-quality custom voice, add `HUME_API_KEY` only to the ignored `.env`, then run
`pnpm voice:hume:audition`. It creates three original-character voice designs under the ignored
`local-data/voice-clone/hume/` directory. The command deliberately describes a new adult alien
engineer voice instead of requesting an actor impersonation. Override `HUME_VOICE_DESCRIPTION`
locally to iterate; no key, private voice ID, candidate audio, or generation manifest is committed.
After ranking the candidates, `pnpm voice:hume:save -- 3` saves the selected generation to the Hume
account and records its private metadata only in ignored `local-data/voice-clone/hume/saved-voice.json`.
To replace an existing saved Hume voice after a new audition, run
`pnpm voice:hume:save -- 2 --replace`, then restart Rocky so the app reads the new private voice ID.

### Persona prompt iteration

Run the full text-mode style suite before spending time listening to voice sessions:

```bash
pnpm eval:rocky
ROCKY_EVAL_RUNS=5 pnpm eval:rocky -- "first greeting"
```

Committed cases live in `evals/rocky-style-cases.json`. Known bad outputs are preserved in the
prompt and unit tests so regressions remain visible. Generated eval reports stay local under
`local-data/evals/`.

The app scores the first actual Realtime greeting and every subsequent spoken reply. A failure is
recorded in the conversation transcript and appended to ignored
`local-data/evals/realtime-failures.md` for the next prompt iteration. The general reply check is
deliberately strict; a requested detailed or safety-critical answer may be worth keeping even if it
raises a length warning.

For hands-on personality iteration without voice variables, run `pnpm text:rocky`. It uses the
same production prompt and local family memory, maintains conversation context until `/quit`, and
saves the session under ignored `local-data/text-chats/`. A one-shot prompt also works:

```bash
pnpm text:rocky -- "I built a cardboard spaceship today."
```

Run `pnpm review:rocky` to rescore every saved voice transcript and text-lab conversation without
making an API call. The command prints a short summary and writes the detailed ignored report to
`local-data/evals/latest-transcript-review.md`, which makes prompt changes easy to compare against
real family interactions.

The primary cadence knobs live together in
`apps/desktop/src/shared/personality.ts`: normal reply length, sentence cap, greeting length,
question cap, and emphasis repetition. Tune those values first when listening feedback is about
pace or verbosity; use the longer persona prompt for behavioral changes.

### Experimental cloned voice

An optional personal-use YourTTS worker lives under `services/voice-clone`. Voice reference audio,
model weights, Python environments, and generated samples remain ignored under
`local-data/voice-clone/` and are never bundled or committed. See
[`services/voice-clone/README.md`](services/voice-clone/README.md) for licensing constraints,
setup, benchmark results, and local commands.

## Acknowledgments

Rocky's compact speech mechanics and exactness/safety rule are adapted from the MIT-licensed
[Lagunaswift/RockyVoice](https://github.com/Lagunaswift/RockyVoice) project. This app retains its
own direct OpenAI Realtime voice architecture rather than importing RockyVoice's Hume TTS server.
See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for full attribution and licenses.
