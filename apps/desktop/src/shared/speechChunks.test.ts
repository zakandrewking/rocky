import { describe, expect, it } from "vitest";

import { splitSpeechChunks } from "./speechChunks";

describe("speech chunking", () => {
  it("holds incomplete text and emits complete sentences", () => {
    const first = splitSpeechChunks("", "Rocky here. Air feels");
    expect(first).toEqual({ complete: ["Rocky here."], remainder: "Air feels" });
    expect(splitSpeechChunks(first.remainder, " thin. Question?")).toEqual({
      complete: ["Air feels thin."],
      remainder: "Question?",
    });
  });

  it("flushes the final fragment", () => {
    expect(splitSpeechChunks("Can hear", ".", true)).toEqual({
      complete: ["Can hear."],
      remainder: "",
    });
  });
});
