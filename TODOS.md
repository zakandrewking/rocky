# Rocky TODOs

## Product and platform direction

- Build for local, family use with kid-friendly behavior by default.
- Prefer the simplest reliable local-first architecture.
- Prioritize voice latency and conversational feel over model cost initially.
- Optimize for macOS on this computer first; portability can come later.
- Allow Rocky to create and open local `.xlsx` files, launch approved macOS apps, and provide
  a Dock or Desktop launcher.
- Create an original character voice with Rocky's curious, musical, enthusiastic spirit; do
  not reproduce copyrighted dialogue verbatim.

## Future work

- [x] Choose a local macOS-first architecture for voice and native file control.
- [x] Build the first Electron voice shell around OpenAI's Realtime API.
- [x] Add a `create_spreadsheet` voice tool with `.xlsx` generation and automatic opening in
  the default macOS spreadsheet app.
- [x] Test the first full spoken conversation against the live API.
- [x] Verify direct workbook creation and foreground handoff to Numbers.
- [x] Keep ignored local transcript and spreadsheet history in `local-data/`.
- [x] Standardize spreadsheet viewing and editing on open-source ONLYOFFICE Desktop Editors.
- [x] make sure we have some personality instruction in the prompt. use what you learned from the 
  film. rocky likes to connect and interact with people, learn about them, connect. If you do not
  have the film screenplay, download it to this repo for reference.
- [x] to make this possible, implement a rudimentary memory system that saves to and reads from a 
  local file. and update the prompt appropriately
- [ ] the electron UI should be minimal - no text! just the rock that reponds to hovers and clicks
- [ ] Test a spoken spreadsheet tool call end to end.
- [ ] Tune Rocky's prompt, voice, interruption behavior, and musical personality with the family.
  - [x] Add repeatable text-mode style evals and preserve failed phrases as negative examples.
  - [x] Make the initial greeting, acknowledgement, science, and safety style evals pass repeatedly
    in text mode.
  - [x] Automatically capture failed Realtime greetings and their broken rules under `local-data/`.
  - [x] Audit every Realtime reply against the default cadence profile during family testing.
  - [x] Add personality evals for specific curiosity, direct emotional connection, cadence, and
    natural recall of one relevant memory.
  - [x] Add an interactive text-only conversation lab using the production prompt and memory.
  - [ ] Verify the hardened greeting on the exact Realtime voice model and add its transcript to
    the negative set if it drifts.
- [ ] Replace the preset voice with the trained Rocky voice from
  [Pedram Amini's Rocky voice-clone project](https://pedsidian.pedramamini.com/Claude/Blog/2026-03-28-rocky-voice-clone#The%20Final%20Product).
  Locate the model/artifacts, confirm their license and permitted use, and determine the lowest-latency
  way to combine them with the conversational model. Do not constrain the architecture to OpenAI
  Realtime: evaluate Deepgram and other realtime STT, conversational-model, and TTS providers or
  local STT/TTS engines, choosing the stack with the best naturalness, interruption handling,
  latency, and tool use for Rocky. Local speech-to-text and text-to-speech are acceptable; keep the
  conversational/reasoning model hosted for now because local AI models are expected to be too slow.
- [ ] Add a friendly settings screen for model, voice, and API-key status.
- [ ] Package and sign a macOS `.app`, then add it to the Dock and optionally the Desktop.
- [ ] Add optional long-term family memory with clear parental controls.
- [ ] Swap to GPT-Live when OpenAI makes it available through the API and it improves the
  experience over GPT-Realtime.
