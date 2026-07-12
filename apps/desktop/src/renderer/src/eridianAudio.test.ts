import { describe, expect, it } from "vitest";

import { MAX_ERIDIAN_UTTERANCE_SECONDS } from "./eridianAudio";

describe("Eridian audio scheduling", () => {
  it("caps alien utterance duration so it cannot become a stuck audio spinner", () => {
    expect(MAX_ERIDIAN_UTTERANCE_SECONDS).toBeLessThanOrEqual(8);
  });
});
