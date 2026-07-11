import { describe, expect, it } from "vitest";

import { isGreetingTurn, parseConversationTurns } from "./transcriptReview";

describe("parseConversationTurns", () => {
  it("reads voice and text-lab transcript headings while ignoring system entries", () => {
    const turns = parseConversationTurns(`# Rocky conversation

**System · 11:02:10 AM**  
Connected.

**Rocky · 11:02:14 AM**  
Rocky here. You have science question?

**You**  
Why sky blue?

**Rocky**  
Tiny light waves scatter more. Blue wins, wins, wins!
`);

    expect(turns).toEqual([
      { role: "rocky", text: "Rocky here. You have science question?" },
      { role: "you", text: "Why sky blue?" },
      { role: "rocky", text: "Tiny light waves scatter more. Blue wins, wins, wins!" },
    ]);
  });

  it("detects implicit voice greetings and explicit text-lab greetings", () => {
    const voice = parseConversationTurns("**Rocky · now**  \nRocky here. You have question?");
    expect(isGreetingTurn(voice, 0, true)).toBe(true);

    const text = parseConversationTurns(
      "**You**  \nA new family conversation just started. Give the first greeting.\n\n**Rocky**  \nRocky here. You have question?",
    );
    expect(isGreetingTurn(text, 1)).toBe(true);
  });

  it("treats the first Rocky utterance as a reply when the human spoke first", () => {
    const turns = parseConversationTurns(
      "**You · now**  \nLet us talk Minecraft.\n\n**Rocky · now**  \nUnderstand. Blocks are useful.",
    );
    expect(isGreetingTurn(turns, 1, true)).toBe(false);
  });
});
