#!/usr/bin/env python3
"""Loopback-only persistent YourTTS worker for Rocky's optional local voice."""

from __future__ import annotations

import argparse
import json
import os
import tempfile
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Protocol


ROOT = Path(__file__).resolve().parents[2]
VOICE_DIR = ROOT / "local-data" / "voice-clone"
DEFAULT_REFERENCE = VOICE_DIR / "rocky_training_audio_scrubbed.wav"
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 59720
MAX_TEXT_CHARACTERS = 2_000


class Synthesizer(Protocol):
    def synthesize(self, text: str) -> bytes: ...


def validate_text(value: object) -> str:
    if not isinstance(value, str):
        raise ValueError("text must be a string")
    text = " ".join(value.split())
    if not text:
        raise ValueError("text is required")
    if len(text) > MAX_TEXT_CHARACTERS:
        raise ValueError(f"text exceeds {MAX_TEXT_CHARACTERS} characters")
    return text


class YourTtsSynthesizer:
    def __init__(self, reference: Path) -> None:
        os.environ.setdefault("COQUI_TOS_AGREED", "1")
        os.environ.setdefault("TTS_HOME", str(VOICE_DIR / "tts-home"))
        os.environ.setdefault("MPLCONFIGDIR", str(VOICE_DIR / "matplotlib"))
        Path(os.environ["MPLCONFIGDIR"]).mkdir(parents=True, exist_ok=True)

        started = time.perf_counter()
        from TTS.api import TTS  # Imported after local cache paths are configured.

        self._tts = TTS("tts_models/multilingual/multi-dataset/your_tts")
        self._reference = reference
        self.load_seconds = time.perf_counter() - started

    def synthesize(self, text: str) -> bytes:
        with tempfile.NamedTemporaryFile(suffix=".wav", dir=VOICE_DIR, delete=False) as output:
            output_path = Path(output.name)
        try:
            self._tts.tts_to_file(
                text=text,
                speaker_wav=str(self._reference),
                language="en",
                file_path=str(output_path),
            )
            return output_path.read_bytes()
        finally:
            output_path.unlink(missing_ok=True)


class VoiceHandler(BaseHTTPRequestHandler):
    synthesizer: Synthesizer

    def log_message(self, message: str, *args: object) -> None:
        print(f"voice-worker: {message % args}", flush=True)

    def send_json(self, status: int, payload: dict[str, object]) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path != "/health":
            self.send_json(404, {"error": "not found"})
            return
        self.send_json(200, {"status": "ready", "model": "your_tts"})

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path != "/synthesize":
            self.send_json(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 64_000:
                raise ValueError("invalid request size")
            payload = json.loads(self.rfile.read(length))
            text = validate_text(payload.get("text"))
            started = time.perf_counter()
            wav = self.synthesizer.synthesize(text)
            elapsed = time.perf_counter() - started
        except (ValueError, json.JSONDecodeError) as error:
            self.send_json(400, {"error": str(error)})
            return
        except Exception as error:  # Keep model details local; return a compact failure.
            print(f"voice-worker synthesis failed: {error!r}", flush=True)
            self.send_json(500, {"error": "synthesis failed"})
            return

        self.send_response(200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(wav)))
        self.send_header("X-Rocky-Synthesis-Seconds", f"{elapsed:.3f}")
        self.end_headers()
        self.wfile.write(wav)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", default=DEFAULT_PORT, type=int)
    parser.add_argument("--reference", type=Path, default=DEFAULT_REFERENCE)
    parser.add_argument("--check", action="store_true", help="verify local prerequisites without loading the model")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    reference = args.reference.expanduser().resolve()
    if not reference.is_file():
        raise SystemExit(f"Voice reference missing: {reference}")
    if args.host not in {"127.0.0.1", "localhost", "::1"}:
        raise SystemExit("Voice worker must bind to loopback only")
    if args.check:
        print(f"voice reference ready: {reference}")
        return

    server = HTTPServer((args.host, args.port), VoiceHandler)
    try:
        synthesizer = YourTtsSynthesizer(reference)
    except Exception:
        server.server_close()
        raise
    VoiceHandler.synthesizer = synthesizer
    print(
        f"voice-worker ready on http://{args.host}:{args.port} "
        f"(model/import load {synthesizer.load_seconds:.2f}s)",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
