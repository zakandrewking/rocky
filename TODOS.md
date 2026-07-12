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

in approximate priority order

- [x] Choose a local macOS-first architecture for voice and native file control.
- [x] Build the first Electron voice shell around OpenAI's Realtime API.
- [x] Add a `create_spreadsheet` voice tool with `.xlsx` generation and automatic opening in
  the default macOS spreadsheet app.
- [x] Test the first full spoken conversation against the live API.
- [x] Verify direct workbook creation and foreground handoff to Numbers.
- [x] Keep ignored local transcript and spreadsheet history in `local-data/`.
- [x] Persist bounded recent conversation continuity across app restarts in ignored local data, so
  a fresh Realtime session can resume after a crash, disconnect, or manual restart.
- [x] Standardize spreadsheet viewing and editing on open-source ONLYOFFICE Desktop Editors.
- [x] make sure we have some personality instruction in the prompt. use what you learned from the 
  film. rocky likes to connect and interact with people, learn about them, connect. If you do not
  have the film screenplay, download it to this repo for reference.
- [x] to make this possible, implement a rudimentary memory system that saves to and reads from a 
  local file. and update the prompt appropriately
- [x] Make the Electron UI text-free: only the rock, with hover, click, and draggable-background behavior.
- [x] Make repeated spreadsheet updates open as distinct workbook revisions so ONLYOFFICE visibly foregrounds the new content instead of showing a cached copy of the original path.
- [x] Add repeatable text-mode style evals and preserve failed phrases as negative examples.
- [x] Make the initial greeting, acknowledgement, science, and safety style evals pass repeatedly
  in text mode.
- [x] Automatically capture failed Realtime greetings and their broken rules under `local-data/`.
- [x] Audit every Realtime reply against the default cadence profile during family testing.
- [x] Add personality evals for specific curiosity, direct emotional connection, cadence, and
  natural recall of one relevant memory.
- [x] Add an interactive text-only conversation lab using the production prompt and memory.
- [x] Add an offline reviewer for every captured voice and text-lab utterance.
- [x] Locate the author's gist, reference audio, trained RVC model, and stated personal-use terms.
- [x] Benchmark persistent local YourTTS on this Mac (0.41–0.49 seconds for 4–6 second clips).
- [x] Add a loopback-only persistent YourTTS worker without committing voice assets or weights.
- [x] A/B raw and 1.5× YourTTS output against the author's published final-product sample; initial
  family feedback says the generated examples are not good enough.
- [x] Port Lahiru Maramba's MIT-licensed Eridian alien-voice synthesizer to TypeScript/Web Audio:
  deterministic three-note word chords, special emotional vocabulary, stable hashed chords for
  unknown words, melodic name signatures, punctuation/excitement dynamics, and pre-warmed caching.
- [x] Add an offline WAV renderer for auditioning the live Eridian vocabulary and timing without
  launching a conversation or spending an API call.
- [x] Evaluate Hume custom voice cloning from the Rocky seed/reference audio. Verify the current
    creation workflow, account-private voice-ID behavior, API availability, latency, pricing, and
    personal-use terms; never commit the Hume API key or voice ID. A/B it against Piper candidates.
  - [x] Confirm Octave 2 supports private saved voices, incremental WebSocket text input, streaming
    output, and advertised model latency near 100 ms before network transit.
  - [x] Add a no-secret, ignored-output audition command that generates three original adult alien
    voice designs. Prefer this consent-safe design route unless suitable rights for cloning exist.
  - [x] Add a local Hume API key, generate three original Voice Design candidates, and family-rank
    them; candidate 3 was the clear initial winner.
  - [x] Save Voice Design candidate 3 as the private account voice `Rocky Original` and keep its ID
    in ignored local configuration.
- [ ] Implement Hume Octave 2 bidirectional streaming behind a provider boundary, with buffered incremental text, immediate barge-in cancellation, and the Eridian chord layer mixed locally.
  - [ ] Keep the Hume key and private voice ID in Electron's main process; give the renderer only
    narrowly scoped IPC audio events, never reusable credentials.
  - [ ] Switch OpenAI Realtime to text-only output when Hume is selected while preserving WebRTC
    microphone input, semantic VAD, conversation state, memory, and spreadsheet tool calls.
  - [ ] Stream sentence-aware text chunks to Hume and schedule returned PCM without gaps, while
    keeping orb listening/thinking/speaking states synchronized to real playback.
  - [x] Let concise alien chords begin immediately and rely on natural Hume generation latency for
    their head start; compress chord timing so the human translation finishes later. Keep an optional
    bounded extra English-start delay, defaulting to zero, for family tuning and future settings UI.
  - [x] Reduce Hume flush boundaries by buffering short sentence chunks into larger utterances and
    sending an explicit final flush at the end of Rocky's turn to reduce accent/prosody drift.
  - [ ] On barge-in, cancel the active OpenAI response, abort Hume generation, clear queued PCM and
    Eridian chords immediately, and prevent Rocky's output from feeding back into the microphone.
  - [ ] Fall back cleanly to the working OpenAI voice if Hume is unavailable, rate-limited, or
    misconfigured; record a useful ignored diagnostic without speaking implementation details.
  - [ ] Measure time-to-first-audio and full turn latency in ignored session diagnostics, then run
    end-to-end family tests for greeting, interruption, memory, and spreadsheet creation/update.
- [x] Implement a live ONLYOFFICE active-sheet bridge so Rocky can update the visible workbook in
  place instead of creating a new revision for every follow-up edit.
  - [x] Add an authenticated loopback bridge in Electron main, with local token storage under
    ignored `local-data/`.
  - [x] Add a hidden ONLYOFFICE Desktop Editors plugin that polls Rocky and replaces the active
    sheet with the complete updated table.
  - [x] Add install/status scripts and verify the plugin connects when a workbook is open in
    ONLYOFFICE Spreadsheet Editor.
- [x] Add a small Rocky `.xlsx` command-line tool for inspect, set-cell, and append-row workflows,
  so agent/debug work can edit Excel files without driving ONLYOFFICE UI.
- [ ] Make Rocky's generated `.xlsx` and `.docx` files durable and discoverable across sessions:
  save them under ignored `local-data/`, inject recent file context into new conversations, let
  Rocky reopen the latest/relevant file later, and eventually add voice tools for listing/opening
  prior Rocky files so useful work is never lost.
- [ ] Extend the Rocky `.xlsx` CLI toward the richer Claude spreadsheet skill pattern:
  /var/folders/6w/1gtm6b0n6s16j6p_fvlqbrfm0000gn/T/claude-hostloop-plugins/ccb68a6b8377b360/skills/xlsx/SKILL.md
- [ ] Rework live spreadsheet edits to operate more like Claude's spreadsheet skill: inspect/read
  the existing workbook, apply targeted cell/range/table operations with dedicated Excel tools,
  save the `.xlsx`, and use ONLYOFFICE only as the final visual refresh/control layer. Rocky
  should not tell users he can only replace a whole sheet.
  - [ ] Add voice tools for reading current workbook structure/ranges and applying targeted edits.
  - [ ] Preserve existing formulas, styles, sheet names, and user conventions when editing a
    workbook; never flatten formulas by accidentally saving a value-only read.
  - [ ] Add formula-aware verification: detect formulas, recalculate with LibreOffice when needed,
    report formula errors, and avoid shipping changed workbooks with new calculation failures.
  - [ ] Add clear assumptions/comments for hardcoded values in generated spreadsheets where useful.
  - [ ] Extend the ONLYOFFICE bridge beyond whole-sheet replacement to ranged cell updates, append
    rows, sheet selection, and refresh/reopen behavior.
  - [ ] Make prompts prefer targeted workbook edits for follow-up spreadsheet changes, falling
    back to whole-sheet replacement only when the requested edit genuinely changes the full table.
- [ ] Rework DOCX generation to match the Claude docx skill pattern for production-quality output:
  `docx` npm generation with explicit US Letter geometry, real headings/lists, no literal bullets
  or newline hacks, and a render-to-PDF/image verification loop where practical.
  - [ ] Add a DOCX render smoke/QA script using LibreOffice and Poppler for generated how-to docs.
  - [ ] If Rocky edits existing DOCX files later, unzip/edit XML/validate instead of using
    `docx` as if it could safely round-trip existing documents.
- [ ] Test a spoken spreadsheet tool call end to end.
- [ ] Test a spoken visible-spreadsheet update end to end.
- [ ] Verify that asking for all Minecraft biomes proactively opens a scoped biome workbook.
- [ ] Make Rocky naturally learn who is speaking: when the current speaker has not introduced
  themselves, ask once per session what first name or nickname to use, remember the volunteered
  answer, and associate later safe facts with that person without requesting private information.
- [ ] Improve local memory identity correction and merging so a speech-to-text misspelling such as
  `Zac` can be corrected to `Zak` without leaving duplicate people or orphaning earlier facts.
- [x] Add first-pass asynchronous research handoffs for questions without obvious or stable answers. Rocky's
  low-latency conversation should dispatch a slower web-search-enabled reasoning agent, continue
  talking without blocking, and let the research agent pop naturally back into the live conversation
  when ready, similar to GPT-Live offloading long-running work to GPT-5.5.
  - [x] Preserve the originating question and conversation context, expose pending/completed/failed
    state, save results locally, and inject same-session completions back into conversation.
  - [x] Return a concise spoken answer with source provenance saved in the local transcript; apply
    kid-safe browsing rules and never let untrusted web content directly control local tools.
  - [ ] Add explicit cancellation UI/voice behavior and stale-topic suppression beyond session matching.
- [ ] Tune Rocky's prompt, voice, interruption behavior, and musical personality with the family.
  - [x] Stabilize the voice state machine by disabling automatic Realtime VAD response creation
    and interruption, making Rocky explicitly create the first short greeting, and guarding
    speech-start events that are likely caused by Rocky's own output.
  - [x] Add rare, context-triggered family easter eggs for oversized encouragement, literal joke
    reveals, ball-sport innocence, whole-good wordplay, affection for Earth and friendship, sensory
    planet names, reciprocal creature nicknames, messy-room reactions, and alien disgust at eating;
    reserve exact `Rocky hate Mark.` for the explicitly invoked fictional in-joke only.
- [ ] Add a friendly settings screen for model, voice, and API-key status.
- [ ] Package and sign a macOS `.app`, then add it to the Dock and optionally the Desktop.
- [x] Add an unsigned macOS DMG build, GitHub Releases workflow, README release docs, and a
  one-time family-Mac bootstrap script that installs ONLYOFFICE, writes app-data config, installs
  the ONLYOFFICE plugin, and opens the latest Rocky DMG.
- [ ] Add code signing, notarization, and polished versioned release notes for public-quality
  macOS releases when Apple credentials are available.
- [ ] Verify the hardened greeting on the exact Realtime voice model and add its transcript to
  the negative set if it drifts.
- [ ] Select a voice engine only after it clearly beats the published YourTTS sample in family A/B.
- [ ] Replace the preset voice with the trained Rocky voice from [Pedram Amini's Rocky voice-clone project](https://pedsidian.pedramamini.com/Claude/Blog/2026-03-28-rocky-voice-clone#The%20Final%20Product). Locate the model/artifacts, confirm their license and permitted use, and determine the lowest-latency way to combine them with the conversational model. Do not constrain the architecture to OpenAI Realtime: evaluate Deepgram and other realtime STT, conversational-model, and TTS providers or local STT/TTS engines, choosing the stack with the best naturalness, interruption handling, latency, and tool use for Rocky. Local speech-to-text and text-to-speech are acceptable; keep the conversational/reasoning model hosted for now because local AI models are expected to be too slow.
- [ ] Add optional long-term family memory with clear parental controls.
- [ ] Swap to GPT-Live when OpenAI makes it available through the API and it improves the
  experience over GPT-Realtime.
- [ ] Try a Hume voice clone from the best available Rocky reference audio after confirming the necessary rights or speaker consent. A/B the clone directly against Voice Design candidate 3; keep all uploaded source audio, generated samples, and private voice IDs local and uncommitted.
- [ ] A/B the public Piper `en_US-lessac-low` and `en_US-joe-medium` ONNX voices with identical
  Rocky lines; tune speech rate and Piper variation controls, and verify each model card/license.
- [ ] Keep searching the internet for stronger public Piper ONNX candidates. Prefer candidates
  with an author-provided YouTube/audio demo, exact downloadable model and JSON files, clear
  provenance, and personal-use-compatible licensing so expectations can be set before setup.
- [ ] Layer the Eridian voice with translated English without harming intelligibility. Family-test
  quiet simultaneous chords versus a short emotional chord before speech, with independent volume
  and mute controls; keep the alien voice instant, local, and available even if English TTS fails.
- [ ] Add an experimental Realtime text-output mode and play local WAV replies only after a voice
  engine passes that quality gate.
- [ ] Preserve interruption handling by stopping local playback as soon as the family speaks.
- [ ] Compare YourTTS against the supplied RVC model only if artifacts and latency justify it.
