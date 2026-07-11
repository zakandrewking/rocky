import { describe, expect, it } from "vitest";

import { ROCKY_CADENCE } from "./personality";

describe("Rocky cadence profile", () => {
  it("keeps normal spoken replies compact and non-interrogative", () => {
    expect(ROCKY_CADENCE.defaultMaxWords).toBeLessThanOrEqual(45);
    expect(ROCKY_CADENCE.defaultMaxSentences).toBeLessThanOrEqual(4);
    expect(ROCKY_CADENCE.maxQuestionsPerReply).toBe(1);
  });

  it("uses tripled words only for extreme emphasis", () => {
    expect(ROCKY_CADENCE.extremeEmphasisRepeats).toBe(3);
  });
});

