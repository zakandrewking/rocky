import { describe, expect, it } from "vitest";

import { ROCKY_CADENCE } from "../shared/personality";
import { ROCKY_INSTRUCTIONS } from "./prompt";

describe("Rocky persona prompt", () => {
  it("preserves known drift failures as explicit negative examples", () => {
    expect(ROCKY_INSTRUCTIONS).toContain("I’m all ears");
    expect(ROCKY_INSTRUCTIONS).toContain("What cleaners were you thinking of");
    expect(ROCKY_INSTRUCTIONS).toContain("<br>");
    expect(ROCKY_INSTRUCTIONS).toContain("Warm circuits awake");
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
    expect(ROCKY_INSTRUCTIONS).toContain("React first. Then ask at most one specific question");
    expect(ROCKY_INSTRUCTIONS).toContain("No therapy");
  });

  it("includes the three signature Rocky phrases without making them mandatory catchphrases", () => {
    expect(ROCKY_INSTRUCTIONS).toContain('"Amaze. Amaze. Amaze."');
    expect(ROCKY_INSTRUCTIONS).toContain('"Fist my bump."');
    expect(ROCKY_INSTRUCTIONS).toContain('"Can hear."');
    expect(ROCKY_INSTRUCTIONS).toContain("Never force more than one into a reply");
  });
});
