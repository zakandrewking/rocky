/**
 * A non-realtime "record, think, speak" round trip for the CyberPi's first
 * voice demo. The full Realtime WebRTC/WebSocket duplex pipeline that
 * PLAN.md's later steps target is a much larger undertaking (streaming,
 * barge-in) than the embedded client can take on yet; this endpoint proves
 * the "robot records, backend understands and replies, robot speaks" loop
 * with a single HTTP request, using OpenAI's regular (non-Realtime) audio
 * and chat endpoints.
 */
// Reused directly from the desktop app, matching session.ts's pattern.
import { ROCKY_INSTRUCTIONS } from "../../../apps/desktop/src/main/prompt.ts";

import { DEVICE_ADDENDUM, type FetchLike } from "./session.ts";
import { encodeWav } from "./wav.ts";

export interface VoiceTurnOptions {
  readonly apiKey: string;
  /** Raw 16-bit mono PCM captured from the robot's microphone. */
  readonly pcm: Buffer;
  readonly sampleRate: number;
  readonly model?: string;
  readonly ttsVoice?: string;
  readonly fetchImpl?: FetchLike;
}

export interface VoiceTurnResult {
  readonly transcript: string;
  readonly reply: string;
  /** Raw 16-bit mono PCM at 24 kHz - OpenAI TTS's fixed "pcm" output rate. */
  readonly audioPcm: Buffer;
  readonly audioSampleRate: number;
}

const TTS_SAMPLE_RATE = 24000;

export async function handleVoiceTurn(options: VoiceTurnOptions): Promise<VoiceTurnResult> {
  const {
    apiKey,
    pcm,
    sampleRate,
    model = "gpt-5.4-mini",
    ttsVoice = "cedar",
    fetchImpl = fetch as FetchLike,
  } = options;

  const wav = encodeWav(bufferToInt16Array(pcm), sampleRate);
  const transcript = await transcribe(wav, apiKey, fetchImpl);
  const reply = transcript
    ? await chat(transcript, model, apiKey, fetchImpl)
    : "Rocky didn't catch that - try again a little closer to the microphone.";
  const audioPcm = await speak(reply, ttsVoice, apiKey, fetchImpl);

  return { transcript, reply, audioPcm, audioSampleRate: TTS_SAMPLE_RATE };
}

function bufferToInt16Array(buffer: Buffer): Int16Array {
  // Buffer's underlying ArrayBuffer may be a larger pooled allocation, so the
  // view has to respect byteOffset/length rather than wrapping the raw
  // buffer - otherwise it can read neighboring, unrelated memory.
  return new Int16Array(buffer.buffer, buffer.byteOffset, Math.floor(buffer.length / 2));
}

async function transcribe(wav: Buffer, apiKey: string, fetchImpl: FetchLike): Promise<string> {
  const form = new FormData();
  form.append("file", new Blob([wav], { type: "audio/wav" }), "audio.wav");
  form.append("model", "whisper-1");

  const response = await fetchImpl("https://api.openai.com/v1/audio/transcriptions", {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}` },
    body: form,
  });
  if (!response.ok) {
    throw new Error(`transcription failed (${response.status}): ${(await response.text()).slice(0, 400)}`);
  }
  const data = (await response.json()) as { text?: string };
  return (data.text ?? "").trim();
}

function outputText(response: { output?: Array<{ content?: Array<{ type?: string; text?: string }> }> }): string {
  return (response.output ?? [])
    .flatMap((item) => item.content ?? [])
    .filter((item) => item.type === "output_text")
    .map((item) => item.text ?? "")
    .join("\n")
    .trim();
}

async function chat(transcript: string, model: string, apiKey: string, fetchImpl: FetchLike): Promise<string> {
  const response = await fetchImpl("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model,
      instructions: `${ROCKY_INSTRUCTIONS}\n\n${DEVICE_ADDENDUM}`,
      input: transcript,
      max_output_tokens: 400,
    }),
  });
  if (!response.ok) {
    throw new Error(`chat failed (${response.status}): ${(await response.text()).slice(0, 400)}`);
  }
  const text = outputText(
    (await response.json()) as { output?: Array<{ content?: Array<{ type?: string; text?: string }> }> },
  );
  return text || "Rocky is thinking quietly right now.";
}

async function speak(text: string, voice: string, apiKey: string, fetchImpl: FetchLike): Promise<Buffer> {
  const response = await fetchImpl("https://api.openai.com/v1/audio/speech", {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: "gpt-4o-mini-tts",
      voice,
      input: text,
      response_format: "pcm", // raw 16-bit mono PCM at 24 kHz, no header - the
      // robot writes it straight to its DAC without parsing anything.
    }),
  });
  if (!response.ok) {
    throw new Error(`speech failed (${response.status}): ${(await response.text()).slice(0, 400)}`);
  }
  return Buffer.from(await response.arrayBuffer());
}
