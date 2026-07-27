/**
 * Minimal WAV writer.
 *
 * The probe needs to prove the "server generates audio, robot plays it" leg of
 * the Stage-1 milestone without spending an OpenAI call, so the service can
 * hand it a synthesized tone in the format a CyberPi would plausibly accept.
 */

export interface WavOptions {
  readonly sampleRate: number;
  readonly frequencyHz: number;
  readonly milliseconds: number;
  /** 0..1 */
  readonly amplitude: number;
}

export function encodeWav(samples: Int16Array, sampleRate: number): Buffer {
  const bytesPerSample = 2;
  const dataBytes = samples.length * bytesPerSample;
  const buffer = Buffer.alloc(44 + dataBytes);

  buffer.write("RIFF", 0, "ascii");
  buffer.writeUInt32LE(36 + dataBytes, 4);
  buffer.write("WAVE", 8, "ascii");
  buffer.write("fmt ", 12, "ascii");
  buffer.writeUInt32LE(16, 16); // PCM chunk size
  buffer.writeUInt16LE(1, 20); // PCM format
  buffer.writeUInt16LE(1, 22); // mono
  buffer.writeUInt32LE(sampleRate, 24);
  buffer.writeUInt32LE(sampleRate * bytesPerSample, 28); // byte rate
  buffer.writeUInt16LE(bytesPerSample, 32); // block align
  buffer.writeUInt16LE(16, 34); // bits per sample
  buffer.write("data", 36, "ascii");
  buffer.writeUInt32LE(dataBytes, 40);

  for (let i = 0; i < samples.length; i += 1) {
    buffer.writeInt16LE(samples[i] ?? 0, 44 + i * bytesPerSample);
  }
  return buffer;
}

export function generateTone(options: WavOptions): Buffer {
  const { sampleRate, frequencyHz, milliseconds, amplitude } = options;
  const count = Math.max(0, Math.round((sampleRate * milliseconds) / 1000));
  const samples = new Int16Array(count);
  const peak = Math.max(0, Math.min(1, amplitude)) * 32767;

  for (let i = 0; i < count; i += 1) {
    // A short fade at each end keeps the speaker from clicking.
    const fade = Math.min(1, i / (sampleRate * 0.01), (count - i) / (sampleRate * 0.01));
    samples[i] = Math.round(Math.sin((2 * Math.PI * frequencyHz * i) / sampleRate) * peak * fade);
  }
  return encodeWav(samples, sampleRate);
}
