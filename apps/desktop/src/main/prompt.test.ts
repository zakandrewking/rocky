import { describe, expect, it } from "vitest";

import { ROCKY_CADENCE } from "../shared/personality.ts";
import { BACKGROUND_RESEARCH_TOOL, ROCKY_INSTRUCTIONS, SPREADSHEET_TOOL, UPDATE_SPREADSHEET_TOOL } from "./prompt";

describe("Rocky persona prompt", () => {
  it("preserves known drift failures as explicit negative examples", () => {
    expect(ROCKY_INSTRUCTIONS).toContain("I’m all ears");
    expect(ROCKY_INSTRUCTIONS).toContain("What cleaners were you thinking of");
    expect(ROCKY_INSTRUCTIONS).toContain("<br>");
    expect(ROCKY_INSTRUCTIONS).toContain("Warm circuits awake");
    expect(ROCKY_INSTRUCTIONS).toContain("Imagine a dark corridor with warm pipes and echo maps");
    expect(ROCKY_INSTRUCTIONS).toContain("Not every day needs a welding torch");
    expect(ROCKY_INSTRUCTIONS).toContain("brain pipes do not overflow");
    expect(ROCKY_INSTRUCTIONS).toContain("Rocky will keep it simple and useful");
    expect(ROCKY_INSTRUCTIONS).toContain("Sea life is like a moving machine");
    expect(ROCKY_INSTRUCTIONS).toContain("One small question");
    expect(ROCKY_INSTRUCTIONS).toContain("First target");
    expect(ROCKY_INSTRUCTIONS).toContain("Rocky is here, steady");
    expect(ROCKY_INSTRUCTIONS).toContain("tiny mission");
    expect(ROCKY_INSTRUCTIONS).toContain("Rocky here. See friend is close. What do now, question?");
  });

  it("contains the highest-signal RockyVoice mechanics", () => {
    expect(ROCKY_INSTRUCTIONS).toContain("Never use contractions");
    expect(ROCKY_INSTRUCTIONS).toContain('Default acknowledgement is one word: "Understand."');
    expect(ROCKY_INSTRUCTIONS).toContain('word "question" only at the END');
    expect(ROCKY_INSTRUCTIONS).toContain(
      `repeat the important word exactly ${ROCKY_CADENCE.extremeEmphasisRepeats} times`,
    );
    expect(ROCKY_INSTRUCTIONS).toContain("refer to yourself as \"Rocky\"");
    expect(ROCKY_INSTRUCTIONS).toContain("Never drift into normal assistant voice");
    expect(ROCKY_INSTRUCTIONS).toContain("Rocky genuinely wants connection");
    expect(ROCKY_INSTRUCTIONS).toContain("Use saved family memory naturally");
    expect(ROCKY_INSTRUCTIONS).toContain("React first. Usually stop there");
    expect(ROCKY_INSTRUCTIONS).toContain("No therapy");
    expect(ROCKY_INSTRUCTIONS).toContain("Rocky participates and engineers");
    expect(ROCKY_INSTRUCTIONS).toContain("literal, not folksy");
    expect(ROCKY_INSTRUCTIONS).toContain("Call the tool without any spoken preamble");
    expect(ROCKY_INSTRUCTIONS).toContain("Do not end every turn with a question");
    expect(ROCKY_INSTRUCTIONS).toContain("simple shared achievement turned into another interview question");
  });

  it("includes the three signature Rocky phrases without making them mandatory catchphrases", () => {
    expect(ROCKY_INSTRUCTIONS).toContain('"Amaze. Amaze. Amaze."');
    expect(ROCKY_INSTRUCTIONS).toContain('"Fist my bump."');
    expect(ROCKY_INSTRUCTIONS).toContain('"Can hear."');
    expect(ROCKY_INSTRUCTIONS).toContain("Never force more than one into a reply");
  });

  it("keeps family-requested easter eggs rare, contextual, and safe", () => {
    expect(ROCKY_INSTRUCTIONS).toContain("RARE EASTER-EGG COMEDY");
    expect(ROCKY_INSTRUCTIONS).toContain('"Rocky hate Mark."');
    expect(ROCKY_INSTRUCTIONS).toContain("new to balls and human sports");
    expect(ROCKY_INSTRUCTIONS).toContain("reject the fraction");
    expect(ROCKY_INSTRUCTIONS).toContain("over-precise sensory names");
    expect(ROCKY_INSTRUCTIONS).toContain("reciprocal creature nicknames");
    expect(ROCKY_INSTRUCTIONS).toContain("theatrically stretched alien-disgust");
    expect(ROCKY_INSTRUCTIONS).toContain("Never say it about a real person or child named Mark");
    expect(ROCKY_INSTRUCTIONS).toContain("Never force them, stack");
  });

  it("makes complete lists such as Minecraft biomes a proactive spreadsheet trigger", () => {
    expect(ROCKY_INSTRUCTIONS).toContain("all Minecraft biomes");
    expect(ROCKY_INSTRUCTIONS).toContain("do not ask permission first");
    expect(SPREADSHEET_TOOL.description).toContain("Use proactively for complete lists");
    expect(UPDATE_SPREADSHEET_TOOL.description).toContain("currently onscreen");
    expect(ROCKY_INSTRUCTIONS).toContain("edit_current_spreadsheet for targeted cell edits");
  });

  it("lets Rocky dispatch slower research instead of inventing unstable facts", () => {
    expect(ROCKY_INSTRUCTIONS).toContain("call start_background_research silently");
    expect(BACKGROUND_RESEARCH_TOOL.description).toContain("slower web-backed research task");
  });
});
