import { describe, expect, it } from "vitest";

import { encodeWav, generateTone } from "./wav.ts";

describe("encodeWav", () => {
  it("writes a valid 16-bit mono PCM header", () => {
    const wav = encodeWav(new Int16Array([0, 1000, -1000, 32767]), 16000);

    expect(wav.subarray(0, 4).toString("ascii")).toBe("RIFF");
    expect(wav.subarray(8, 12).toString("ascii")).toBe("WAVE");
    expect(wav.subarray(36, 40).toString("ascii")).toBe("data");
    expect(wav.readUInt16LE(20)).toBe(1); // PCM
    expect(wav.readUInt16LE(22)).toBe(1); // mono
    expect(wav.readUInt32LE(24)).toBe(16000);
    expect(wav.readUInt32LE(28)).toBe(32000); // byte rate
    expect(wav.readUInt16LE(34)).toBe(16); // bit depth
    expect(wav.readUInt32LE(40)).toBe(8); // 4 samples * 2 bytes
    expect(wav.length).toBe(52);
  });

  it("round-trips sample values", () => {
    const wav = encodeWav(new Int16Array([-32768, 0, 32767]), 8000);
    expect(wav.readInt16LE(44)).toBe(-32768);
    expect(wav.readInt16LE(46)).toBe(0);
    expect(wav.readInt16LE(48)).toBe(32767);
  });
});

describe("generateTone", () => {
  const options = { sampleRate: 16000, frequencyHz: 440, milliseconds: 600, amplitude: 0.4 };

  it("produces the requested duration", () => {
    const wav = generateTone(options);
    expect(wav.readUInt32LE(40)).toBe(16000 * 0.6 * 2);
  });

  it("stays within the requested amplitude", () => {
    const wav = generateTone(options);
    let peak = 0;
    for (let offset = 44; offset < wav.length; offset += 2) {
      peak = Math.max(peak, Math.abs(wav.readInt16LE(offset)));
    }
    expect(peak).toBeLessThanOrEqual(Math.round(32767 * 0.4));
    expect(peak).toBeGreaterThan(1000);
  });

  it("fades in so the speaker does not click", () => {
    const wav = generateTone(options);
    expect(Math.abs(wav.readInt16LE(44))).toBeLessThan(50);
  });

  it("handles a zero-length request", () => {
    const wav = generateTone({ ...options, milliseconds: 0 });
    expect(wav.length).toBe(44);
    expect(wav.readUInt32LE(40)).toBe(0);
  });
});
