import { describe, expect, it } from "vitest";

import { pcm16LeToFloat32 } from "./humePcmAudio";

describe("Hume PCM audio", () => {
  it("decodes signed little-endian 16-bit mono samples", () => {
    const bytes = Buffer.from([0x00, 0x80, 0x00, 0x00, 0xff, 0x7f]);
    const samples = pcm16LeToFloat32(bytes.toString("base64"));

    expect(Array.from(samples)).toEqual([-1, 0, 32_767 / 32_768]);
  });
});
