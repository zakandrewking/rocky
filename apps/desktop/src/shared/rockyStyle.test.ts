import { describe, expect, it } from "vitest";

import { evaluateRockyStyle, type RockyStyleCase } from "./rockyStyle";

const greetingCase: RockyStyleCase = {
  name: "first greeting",
  input: "start",
  maxWords: 24,
  requiredAll: ["rocky", "question?"],
  forbiddenAny: ["warm"],
};

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
});

