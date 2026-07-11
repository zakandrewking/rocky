# Experimental local Rocky voice

This loopback-only comparison worker keeps Coqui YourTTS loaded and turns short text replies into
WAV audio. It is optional, is not the desktop app's default output path, and has not passed the
family voice-quality bar. Keep it isolated until a blind A/B says otherwise.

The reference voice and model weights are intentionally absent from Git. The source project labels
the voice clone for personal, non-commercial use and notes that the film voice design remains the
production company's intellectual property. Do not redistribute the downloaded audio, weights, or
a packaged app containing them.

## Local setup

Requirements: Apple Silicon macOS, Homebrew Python 3.11, `uv`, and `ffmpeg`.

```bash
brew install python@3.11 ffmpeg
mkdir -p local-data/voice-clone
uv venv --python /opt/homebrew/bin/python3.11 local-data/voice-clone/venv
UV_CACHE_DIR=/tmp/rocky-uv-cache uv pip install \
  --python local-data/voice-clone/venv/bin/python \
  -r services/voice-clone/requirements.txt
```

Place the personal-use `rocky_training_audio_scrubbed.wav` from Pedram Amini's linked project at
`local-data/voice-clone/rocky_training_audio_scrubbed.wav`. On first launch, Coqui downloads model
weights under `local-data/voice-clone/tts-home/`; this directory is ignored.

```bash
pnpm voice:check
pnpm voice:server
curl --fail --silent --show-error \
  -H 'Content-Type: application/json' \
  -d '{"text":"Can hear. Rocky listens."}' \
  http://127.0.0.1:59720/synthesize \
  -o local-data/voice-clone/test.wav
```

The current Mac benchmark synthesized 4–6 second raw clips in 0.41–0.49 seconds after the
persistent Python process loaded. Python/import cold start was roughly 13 seconds. Latency is good,
but raw 1.0× and author-default 1.5× playback both require a separate subjective quality decision;
fast synthesis alone is not sufficient reason to integrate this engine.

Sources: [voice-clone article](https://pedsidian.pedramamini.com/Claude/Blog/2026-03-28-rocky-voice-clone),
[rocky_say gist](https://gist.github.com/pedramamini/fa5f6ef99dae79add220188419230642).
