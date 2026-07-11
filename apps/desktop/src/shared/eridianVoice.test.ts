import { describe, expect, it } from "vitest";

import { eridianChordsForToken, splitStreamingTokens, stableUnknownChord } from "./eridianVoice";

describe("Eridian voice score", () => {
  it("gives known emotional words their authored chords", () => {
    expect(eridianChordsForToken("Amaze!")[0]).toMatchObject({
      frequencies: [659.25, 830.61, 987.77],
      emphasis: true,
    });
  });

  it("creates stable distinct chords for unknown words", () => {
    expect(stableUnknownChord("spreadsheet")).toEqual(stableUnknownChord("spreadsheet"));
    expect(stableUnknownChord("spreadsheet")).not.toEqual(stableUnknownChord("volcano"));
  });

  it("adds the question indicator chord", () => {
    const chords = eridianChordsForToken("question?");
    expect(chords.at(-1)?.frequencies).toEqual([440, 466.16]);
  });

  it("preserves partial words across streaming transcript deltas", () => {
    const first = splitStreamingTokens("", "Amaze. Ama", false);
    expect(first).toEqual({ complete: ["Amaze."], remainder: "Ama" });
    const second = splitStreamingTokens(first.remainder, "ze. question?", true);
    expect(second).toEqual({ complete: ["Amaze.", "question?"], remainder: "" });
  });
});
