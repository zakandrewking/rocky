import { describe, expect, it } from "vitest";

import { splitSpeechChunks } from "./speechChunks";

describe("speech chunking", () => {
  it("holds short complete sentences for voice continuity", () => {
    const first = splitSpeechChunks("", "Rocky here. Air feels");
    expect(first).toEqual({ complete: [], remainder: "Rocky here. Air feels" });
    expect(splitSpeechChunks(first.remainder, " thin. Question?")).toEqual({
      complete: [],
      remainder: "Rocky here. Air feels thin. Question?",
    });
  });

  it("emits a larger complete chunk once enough text has accumulated", () => {
    const text = [
      "Rocky hears.",
      "You ask for planets with snacks and gravity.",
      "This is useful shape for table.",
      "Amaze.",
      "Rocky makes compact list now.",
      "Rows stay together so voice does not change shape between tiny pieces.",
      "More steady sound.",
      "Can hear.",
    ].join(" ");
    const result = splitSpeechChunks("", text);
    expect(result.complete).toEqual([
      [
        "Rocky hears.",
        "You ask for planets with snacks and gravity.",
        "This is useful shape for table.",
        "Amaze.",
        "Rocky makes compact list now.",
        "Rows stay together so voice does not change shape between tiny pieces.",
      ].join(" "),
    ]);
    expect(result.remainder).toBe("More steady sound. Can hear.");
  });

  it("flushes the final fragment", () => {
    expect(splitSpeechChunks("Can hear", ".", true)).toEqual({
      complete: ["Can hear."],
      remainder: "",
    });
  });
});
