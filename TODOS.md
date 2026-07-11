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
- [x] Make the Electron UI text-free: only the rock, with hover, click, and draggable-background behavior.
- [ ] make sure our spreadsheet system works with tools and command line capabilities like this:
  /var/folders/6w/1gtm6b0n6s16j6p_fvlqbrfm0000gn/T/claude-hostloop-plugins/ccb68a6b8377b360/skills/xlsx/SKILL.md
- [ ] Test a spoken spreadsheet tool call end to end.
  - [ ] Verify that asking for all Minecraft biomes proactively opens a scoped biome workbook.
- [ ] Tune Rocky's prompt, voice, interruption behavior, and musical personality with the family.
  - [x] Add repeatable text-mode style evals and preserve failed phrases as negative examples.
  - [x] Make the initial greeting, acknowledgement, science, and safety style evals pass repeatedly
    in text mode.
  - [x] Automatically capture failed Realtime greetings and their broken rules under `local-data/`.
  - [x] Audit every Realtime reply against the default cadence profile during family testing.
  - [x] Add personality evals for specific curiosity, direct emotional connection, cadence, and
    natural recall of one relevant memory.
  - [x] Add an interactive text-only conversation lab using the production prompt and memory.
  - [x] Add an offline reviewer for every captured voice and text-lab utterance.
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
  - [x] Locate the author's gist, reference audio, trained RVC model, and stated personal-use terms.
  - [x] Benchmark persistent local YourTTS on this Mac (0.41–0.49 seconds for 4–6 second clips).
  - [x] Add a loopback-only persistent YourTTS worker without committing voice assets or weights.
  - [x] A/B raw and 1.5× YourTTS output against the author's published final-product sample; initial
    family feedback says the generated examples are not good enough.
  - [ ] Select a voice engine only after it clearly beats the published YourTTS sample in family A/B.
  - [ ] A/B the public Piper `en_US-lessac-low` and `en_US-joe-medium` ONNX voices with identical
    Rocky lines; tune speech rate and Piper variation controls, and verify each model card/license.
  - [ ] Keep searching the internet for stronger public Piper ONNX candidates. Prefer candidates
    with an author-provided YouTube/audio demo, exact downloadable model and JSON files, clear
    provenance, and personal-use-compatible licensing so expectations can be set before setup.
  - [ ] Try to obtain Lahiru Maramba's missing `rocky_model_2999.onnx` and matching JSON, or use his
    MIT-licensed Qwen3-TTS-to-Piper Colab pipeline to train our own only if public models fall short.
  - [ ] Port Lahiru Maramba's MIT-licensed Eridian alien-voice synthesizer to TypeScript/Web Audio:
    deterministic three-note word chords, special emotional vocabulary, stable hashed chords for
    unknown words, melodic name signatures, punctuation/excitement dynamics, and pre-warmed caching.
  - [ ] Layer the Eridian voice with translated English without harming intelligibility. Family-test
    quiet simultaneous chords versus a short emotional chord before speech, with independent volume
    and mute controls; keep the alien voice instant, local, and available even if English TTS fails.
  - [ ] Add an experimental Realtime text-output mode and play local WAV replies only after a voice
    engine passes that quality gate.
  - [ ] Preserve interruption handling by stopping local playback as soon as the family speaks.
  - [ ] Compare YourTTS against the supplied RVC model only if artifacts and latency justify it.
- [ ] Add a friendly settings screen for model, voice, and API-key status.
- [ ] Package and sign a macOS `.app`, then add it to the Dock and optionally the Desktop.
- [ ] Add optional long-term family memory with clear parental controls.
- [ ] Swap to GPT-Live when OpenAI makes it available through the API and it improves the
  experience over GPT-Realtime.
