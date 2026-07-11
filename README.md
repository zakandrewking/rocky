# Rocky

Rocky is a local macOS voice companion for family conversations, science questions, and sudden
spreadsheets. Tap the rock, talk naturally, and Rocky answers with low-latency speech. When rows
and columns would help, Rocky creates an `.xlsx` workbook and pulls it onscreen in the Mac's normal
spreadsheet application.

## First voice conversation

Requirements: macOS, Node.js, pnpm, a microphone, and an OpenAI API key with Realtime API access.

```bash
cp .env.example .env
# Put the OpenAI API key in .env, then:
pnpm install
pnpm dev
```

Tap Rocky once and allow microphone access when macOS asks. Try saying:

> Rocky, help us invent a backyard science experiment.

Or test the spreadsheet handoff:

> Make a spreadsheet to score five imaginary planets by snacks, gravity, and fun.

Workbooks are saved in `~/Documents/Rocky Spreadsheets` and opened with the default macOS app,
such as Numbers or Microsoft Excel.

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
pnpm dist:mac  # create an unpacked macOS application
```

The desktop app lives in `apps/desktop`. Spreadsheet generation is covered by tests and produces
real Excel workbooks with formatted headers, filters, frozen rows, and useful column widths.

