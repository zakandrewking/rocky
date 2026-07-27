import { encodeWav } from "./wav.ts";

/**
 * Decoding what cyberpi.mic_o.get_recording_data() hands back.
 *
 * Measured on hardware (apps/cyberpi/STEPS.md, steps 5e-5g):
 *
 *   get_recording_data(x) -> [48-byte header, PCM bytes]
 *   2 s recording -> 32,000 bytes => 16,000 B/s
 *   header: sample rate 16000 at offset 24, bits-per-sample 8 at offset 34,
 *           payload length at offset 36
 *
 * The header is RIFF-flavoured but not a valid WAV: the RIFF size is 0 and
 * there is no `data` chunk, so nothing will play it. This module turns it into
 * a real 16-bit WAV that any player accepts.
 */

export const MAKEBLOCK_HEADER_BYTES = 48;

export interface MakeblockHeader {
  readonly sampleRate: number;
  readonly bitsPerSample: number;
  /** Payload length the header claims, which may disagree with what arrived. */
  readonly declaredLength: number;
  readonly looksLikeRiff: boolean;
}

function u16(data: Uint8Array, offset: number): number {
  return (data[offset] ?? 0) | ((data[offset + 1] ?? 0) << 8);
}

function u32(data: Uint8Array, offset: number): number {
  return (
    ((data[offset] ?? 0) |
      ((data[offset + 1] ?? 0) << 8) |
      ((data[offset + 2] ?? 0) << 16) |
      ((data[offset + 3] ?? 0) << 24)) >>>
    0
  );
}

export function parseMakeblockHeader(header: Uint8Array): MakeblockHeader {
  const tag = String.fromCharCode(...header.subarray(0, 4));
  return {
    sampleRate: u32(header, 24),
    bitsPerSample: u16(header, 34),
    declaredLength: u32(header, 36),
    looksLikeRiff: tag === "RIFF",
  };
}

/**
 * Is this 8-bit PCM unsigned (silence at 128) or signed (silence at 0)?
 *
 * The firmware does not say, and getting it wrong turns speech into buzzing.
 *
 * Averaging cannot tell them apart — two's-complement negatives wrap to high
 * byte values, so signed audio also has a mean near 128. Smoothness can:
 * decode both ways and see which produces a continuous waveform. The wrong
 * interpretation puts a full-scale discontinuity at every zero crossing.
 */
export function detectUnsigned(pcm: Uint8Array): boolean {
  if (pcm.length < 2) return true;

  const sampleCount = Math.min(pcm.length, 8192);
  let unsignedRoughness = 0;
  let signedRoughness = 0;

  const asUnsigned = (byte: number) => byte - 128;
  const asSigned = (byte: number) => (byte > 127 ? byte - 256 : byte);

  for (let i = 1; i < sampleCount; i += 1) {
    const previous = pcm[i - 1] ?? 0;
    const current = pcm[i] ?? 0;
    unsignedRoughness += Math.abs(asUnsigned(current) - asUnsigned(previous));
    signedRoughness += Math.abs(asSigned(current) - asSigned(previous));
  }

  // Ties (silence decodes smoothly either way) fall to unsigned, the standard
  // for 8-bit WAV.
  return unsignedRoughness <= signedRoughness;
}

export interface DecodedCapture {
  readonly wav: Buffer;
  readonly header: MakeblockHeader;
  readonly sampleCount: number;
  readonly durationSeconds: number;
  readonly unsigned: boolean;
  /** Peak deviation from silence, 0..1. Near zero means nothing was recorded. */
  readonly peak: number;
}

/**
 * Converts a raw capture into a playable 16-bit WAV.
 *
 * Accepts either the whole [header + payload] concatenated, or just the
 * payload — the robot may send either, so sniff for the header rather than
 * demanding one.
 */
export function decodeCapture(raw: Uint8Array, fallbackSampleRate = 16000): DecodedCapture {
  const hasHeader =
    raw.length >= MAKEBLOCK_HEADER_BYTES &&
    String.fromCharCode(...raw.subarray(0, 4)) === "RIFF";

  const header = hasHeader
    ? parseMakeblockHeader(raw.subarray(0, MAKEBLOCK_HEADER_BYTES))
    : { sampleRate: 0, bitsPerSample: 0, declaredLength: 0, looksLikeRiff: false };

  const pcm = hasHeader ? raw.subarray(MAKEBLOCK_HEADER_BYTES) : raw;
  const sampleRate = header.sampleRate > 0 ? header.sampleRate : fallbackSampleRate;
  const unsigned = detectUnsigned(pcm);

  // 8-bit -> 16-bit. Scaling by 257 maps 0..255 onto the full signed range
  // without clipping, which keeps quiet speech audible.
  const samples = new Int16Array(pcm.length);
  let peakDeviation = 0;
  for (let i = 0; i < pcm.length; i += 1) {
    const byte = pcm[i] ?? 0;
    const centred = unsigned ? byte - 128 : byte > 127 ? byte - 256 : byte;
    peakDeviation = Math.max(peakDeviation, Math.abs(centred));
    samples[i] = Math.max(-32768, Math.min(32767, centred * 257));
  }

  return {
    wav: encodeWav(samples, sampleRate),
    header,
    sampleCount: pcm.length,
    durationSeconds: sampleRate > 0 ? pcm.length / sampleRate : 0,
    unsigned,
    peak: peakDeviation / 128,
  };
}

/** One-line summary for the operator's terminal when a capture lands. */
export function describeCapture(decoded: DecodedCapture): string {
  const lines = [
    `CyberPi capture: ${decoded.sampleCount} samples, ` +
      `${decoded.durationSeconds.toFixed(2)}s @ ${decoded.header.sampleRate || "?"}Hz, ` +
      `${decoded.unsigned ? "unsigned" : "signed"} 8-bit`,
    `  peak level: ${(decoded.peak * 100).toFixed(1)}%`,
  ];
  if (decoded.peak < 0.02) {
    lines.push("  WARNING: essentially silent — the mic may not have captured anything");
  }
  if (decoded.header.declaredLength && decoded.header.declaredLength !== decoded.sampleCount) {
    lines.push(
      `  note: header declares ${decoded.header.declaredLength} bytes but ${decoded.sampleCount} arrived`,
    );
  }
  return lines.join("\n");
}
