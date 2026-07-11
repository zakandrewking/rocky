import { describe, expect, it } from "vitest";

import { normalizeResearchInput } from "./backgroundResearch";

describe("background research", () => {
  it("normalizes a research request", () => {
    expect(normalizeResearchInput({ question: "  Which Minecraft version is current?  ", context: "biomes" }))
      .toEqual({ question: "Which Minecraft version is current?", context: "biomes" });
  });

  it("requires a question", () => {
    expect(() => normalizeResearchInput({ question: " " })).toThrow("Research question is required.");
  });
});
