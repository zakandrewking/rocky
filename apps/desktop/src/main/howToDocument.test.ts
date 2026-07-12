import { mkdtemp, readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { normalizeHowToDocSpec, writeHowToDoc } from "./howToDocument";

describe("how-to document writer", () => {
  it("normalizes how-to doc input", () => {
    const spec = normalizeHowToDocSpec({
      title: "How to Build a Cardboard Ramp!",
      filename: "../ramp?.docx",
      steps: ["Cut cardboard.", "Test one marble."],
    });

    expect(spec.filename).toBe("ramp.docx");
    expect(spec.steps).toEqual(["Cut cardboard.", "Test one marble."]);
  });

  it("writes a valid docx zip", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "rocky-doc-"));
    const result = await writeHowToDoc({
      title: "How to Test a Paper Bridge",
      purpose: "Find how much weight the bridge can hold.",
      materials: ["Paper", "Coins"],
      steps: ["Fold paper.", "Place coins one at a time."],
      safetyNotes: ["Keep coins away from small children."],
    }, directory);
    const bytes = await readFile(result.path);

    expect(result.filename).toBe("How-to-Test-a-Paper-Bridge.docx");
    expect(bytes.subarray(0, 2).toString()).toBe("PK");
  });
});
