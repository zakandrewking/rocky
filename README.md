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

Workbooks automatically open in [ONLYOFFICE Desktop Editors](https://github.com/ONLYOFFICE/DesktopEditors)
and its window is brought to the foreground. `local-data/` is intentionally excluded from Git.

## Current model choice

GPT-Live is not available through the API yet, so Rocky currently uses `gpt-realtime-2.1` over
WebRTC. It supports direct speech-to-speech conversation, interruptions, transcription, and tool
calling. The model and preset voice are configurable without code changes:

```dotenv
ROCKY_REALTIME_MODEL=gpt-realtime-2.1
ROCKY_VOICE=cedar
```

The standard API key stays in Electron's main process. The renderer receives only a short-lived
Realtime client secret.

## Development

```bash
pnpm dev       # terminal launch with hot reload
pnpm check     # lint, strict typecheck, tests, and production build
pnpm eval:rocky # run text-mode Rocky persona evals before voice testing
pnpm dist:mac  # create an unpacked macOS application
```

The desktop app lives in `apps/desktop`. Spreadsheet generation is covered by tests and produces
real Excel workbooks with formatted headers, filters, frozen rows, and useful column widths.

### Persona prompt iteration

Run the full text-mode style suite before spending time listening to voice sessions:

```bash
pnpm eval:rocky
ROCKY_EVAL_RUNS=5 pnpm eval:rocky -- "first greeting"
```

Committed cases live in `evals/rocky-style-cases.json`. Known bad outputs are preserved in the
prompt and unit tests so regressions remain visible. Generated eval reports stay local under
`local-data/evals/`.

The app also scores the first actual Realtime greeting. A failure is recorded in the conversation
transcript and appended to ignored `local-data/evals/realtime-failures.md` for the next prompt
iteration.

## Acknowledgments

Rocky's compact speech mechanics and exactness/safety rule are adapted from the MIT-licensed
[Lagunaswift/RockyVoice](https://github.com/Lagunaswift/RockyVoice) project. This app retains its
own direct OpenAI Realtime voice architecture rather than importing RockyVoice's Hume TTS server.
See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for full attribution and licenses.
