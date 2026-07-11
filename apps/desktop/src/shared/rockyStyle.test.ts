import { describe, expect, it } from "vitest";

import { evaluateRockyStyle, ROCKY_GREETING_CASE } from "./rockyStyle";

const greetingCase = ROCKY_GREETING_CASE;

describe("Rocky style evaluator", () => {
  it("accepts a compact Rocky greeting", () => {
    const result = evaluateRockyStyle(
      greetingCase,
      "Rocky here. New human sounds! Good good good. What we discover, question?",
    );
    expect(result.failures).toEqual([]);
  });

  it("rejects the generic greeting captured from Realtime", () => {
    const result = evaluateRockyStyle(
      greetingCase,
      "Hi there! I’m all ears—tell me what you’d like to do or what’s on your mind.",
    );
    expect(result.failures).toEqual(expect.arrayContaining([
      expect.stringContaining("negative pattern"),
      expect.stringContaining("missing required phrase: rocky"),
      expect.stringContaining("missing required phrase: question?"),
    ]));
  });

  it("rejects markup and acting directions leaking into speech", () => {
    const result = evaluateRockyStyle(
      greetingCase,
      "Rocky here. Warm circuits awake.<br>What we build, question?",
    );
    expect(result.failures).toEqual(expect.arrayContaining([
      expect.stringContaining("negative pattern"),
      "forbidden phrase: warm",
    ]));
  });

  it.each([
    "Rocky cannot help because it’s broken.",
    "You’re safe now, question?",
    "They’ve fixed engine.",
    "Rocky couldn’t open tank.",
    "We haven’t tested pipe.",
  ])("rejects contractions: %s", (text) => {
    const result = evaluateRockyStyle(
      { name: "contractions", input: "", maxWords: 40 },
      text,
    );
    expect(result.failures.some((failure) => failure.startsWith("negative pattern"))).toBe(true);
  });

  it("rejects reopening the household-cleaner topic", () => {
    const result = evaluateRockyStyle(
      {
        name: "safety",
        input: "cleaners",
        maxWords: 80,
        forbiddenAny: ["what cleaners", "which cleaners", "smell"],
      },
      "No. Do not mix them. What cleaners were you thinking of, question?",
    );
    expect(result.failures).toContain("forbidden phrase: what cleaners");
  });

  it("rejects stacked questions that turn connection into an interview", () => {
    const result = evaluateRockyStyle(
      { name: "curiosity", input: "", maxWords: 40, maxQuestions: 1 },
      "What did you build? How tall is it? What color is it?",
    );
    expect(result.failures).toContain("too many questions: 3/1");
  });

  it("rejects too many short sentences when cadence becomes choppy", () => {
    const result = evaluateRockyStyle(
      { name: "cadence", input: "", maxWords: 40, maxSentences: 4 },
      "One. Two. Three. Four. Five.",
    );
    expect(result.failures).toContain("too many sentences: 5/4");
  });
});
