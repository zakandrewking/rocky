import { describe, expect, it } from "vitest";

import {
  decodeCapture,
  describeCapture,
  detectUnsigned,
  MAKEBLOCK_HEADER_BYTES,
  parseMakeblockHeader,
} from "./makeblockAudio.ts";

/** Rebuilds the exact 48-byte header the hardware returned in step 5f. */
function makeblockHeader(sampleRate = 16000, bits = 8, payloadLength = 32000): Uint8Array {
  const header = new Uint8Array(MAKEBLOCK_HEADER_BYTES);
  const view = new DataView(header.buffer);
  header.set(new TextEncoder().encode("RIFF"), 0);
  view.setUint32(4, 0, true); // RIFF size really is 0 on this firmware
  header.set(new TextEncoder().encode("WAVE"), 8);
  header.set(new TextEncoder().encode("fmt "), 12);
  view.setUint32(16, 16, true);
  view.setUint32(20, 3, true);
  view.setUint32(24, sampleRate, true);
  view.setUint16(34, bits, true);
  view.setUint32(36, payloadLength, true);
  return header;
}

/** 8-bit unsigned tone, the way the CyberPi mic would deliver it. */
function unsignedTone(samples: number, amplitude = 60): Uint8Array {
  const pcm = new Uint8Array(samples);
  for (let i = 0; i < samples; i += 1) {
    pcm[i] = 128 + Math.round(amplitude * Math.sin((2 * Math.PI * 440 * i) / 16000));
  }
  return pcm;
}

function concat(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

describe("parseMakeblockHeader", () => {
  it("reads the fields measured on hardware", () => {
    const header = parseMakeblockHeader(makeblockHeader());
    expect(header.sampleRate).toBe(16000);
    expect(header.bitsPerSample).toBe(8);
    expect(header.declaredLength).toBe(32000);
    expect(header.looksLikeRiff).toBe(true);
  });
});

describe("detectUnsigned", () => {
  it("recognises unsigned audio centred on 128", () => {
    expect(detectUnsigned(unsignedTone(1000))).toBe(true);
  });

  it("recognises signed audio centred on 0", () => {
    const pcm = new Uint8Array(1000);
    for (let i = 0; i < pcm.length; i += 1) {
      const value = Math.round(50 * Math.sin(i / 10));
      pcm[i] = value < 0 ? value + 256 : value;
    }
    expect(detectUnsigned(pcm)).toBe(false);
  });

  it("treats an empty buffer as unsigned rather than throwing", () => {
    expect(detectUnsigned(new Uint8Array(0))).toBe(true);
  });
});

describe("decodeCapture", () => {
  it("produces a playable 16-bit WAV from a header + payload capture", () => {
    const pcm = unsignedTone(32000);
    const decoded = decodeCapture(concat(makeblockHeader(), pcm));

    expect(decoded.sampleCount).toBe(32000);
    expect(decoded.durationSeconds).toBeCloseTo(2, 5);
    expect(decoded.unsigned).toBe(true);

    // Real WAV this time: RIFF size correct, data chunk present.
    expect(decoded.wav.subarray(0, 4).toString("ascii")).toBe("RIFF");
    expect(decoded.wav.subarray(36, 40).toString("ascii")).toBe("data");
    expect(decoded.wav.readUInt32LE(4)).toBe(36 + 32000 * 2);
    expect(decoded.wav.readUInt32LE(24)).toBe(16000);
    expect(decoded.wav.readUInt16LE(34)).toBe(16);
  });

  it("accepts a bare payload with no header", () => {
    const decoded = decodeCapture(unsignedTone(16000));
    expect(decoded.header.looksLikeRiff).toBe(false);
    expect(decoded.sampleCount).toBe(16000);
    expect(decoded.durationSeconds).toBeCloseTo(1, 5);
    expect(decoded.wav.readUInt32LE(24)).toBe(16000);
  });

  it("scales 8-bit up to 16-bit across the full range without clipping", () => {
    // A full-amplitude unsigned tone: long enough that sign detection is
    // unambiguous, and it visits both extremes and silence.
    const pcm = unsignedTone(4000, 127);
    const decoded = decodeCapture(concat(makeblockHeader(), pcm));
    expect(decoded.unsigned).toBe(true);

    let min = 0;
    let max = 0;
    for (let offset = 44; offset < decoded.wav.length; offset += 2) {
      const value = decoded.wav.readInt16LE(offset);
      min = Math.min(min, value);
      max = Math.max(max, value);
    }
    // 127 * 257 = 32639, just inside the 16-bit ceiling: scaled up, not clipped.
    expect(max).toBe(32639);
    expect(min).toBeGreaterThanOrEqual(-32768);
    expect(min).toBeLessThan(-32000);
  });

  it("maps unsigned silence to zero", () => {
    const pcm = new Uint8Array(4000).fill(128);
    const decoded = decodeCapture(concat(makeblockHeader(), pcm));
    expect(decoded.wav.readInt16LE(44)).toBe(0);
    expect(decoded.wav.readInt16LE(200)).toBe(0);
  });

  it("reports a near-zero peak for a silent capture", () => {
    const silence = new Uint8Array(16000).fill(128);
    const decoded = decodeCapture(concat(makeblockHeader(), silence));
    expect(decoded.peak).toBeLessThan(0.02);
  });

  it("reports a healthy peak for real audio", () => {
    const decoded = decodeCapture(concat(makeblockHeader(), unsignedTone(16000, 100)));
    expect(decoded.peak).toBeGreaterThan(0.5);
  });

  it("honours the header's sample rate over the fallback", () => {
    const decoded = decodeCapture(concat(makeblockHeader(8000), unsignedTone(8000)), 16000);
    expect(decoded.wav.readUInt32LE(24)).toBe(8000);
    expect(decoded.durationSeconds).toBeCloseTo(1, 5);
  });

  it("handles an empty payload without dividing by zero", () => {
    const decoded = decodeCapture(makeblockHeader());
    expect(decoded.sampleCount).toBe(0);
    expect(decoded.durationSeconds).toBe(0);
    expect(decoded.wav.length).toBe(44);
  });
});

describe("describeCapture", () => {
  it("warns when the capture is silent", () => {
    const silence = new Uint8Array(16000).fill(128);
    const summary = describeCapture(decodeCapture(concat(makeblockHeader(), silence)));
    expect(summary).toContain("WARNING");
    expect(summary).toContain("essentially silent");
  });

  it("does not warn for real audio", () => {
    const summary = describeCapture(decodeCapture(concat(makeblockHeader(16000, 8, 16000), unsignedTone(16000, 100))));
    expect(summary).not.toContain("WARNING");
    expect(summary).toContain("1.00s @ 16000Hz");
    expect(summary).toContain("unsigned 8-bit");
  });

  it("flags a length mismatch between header and payload", () => {
    const summary = describeCapture(decodeCapture(concat(makeblockHeader(16000, 8, 32000), unsignedTone(1000))));
    expect(summary).toContain("header declares 32000 bytes but 1000 arrived");
  });
});
