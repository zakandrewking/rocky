import { mkdtemp, readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { nextSpreadsheetPath, normalizeSpreadsheetSpec, writeSpreadsheet } from "./spreadsheet";

describe("spreadsheet writer", () => {
  it("normalizes filenames and uneven rows", () => {
    const spec = normalizeSpreadsheetSpec({
      title: "Moon Snacks!",
      filename: "../Moon snacks?.xlsx",
      sheets: [{ name: "Ideas/Plan", columns: ["Snack", "Score"], rows: [["Ramen"], ["Peas", 9, "extra"]] }],
    });

    expect(spec.filename).toBe("Moon-snacks.xlsx");
    expect(spec.sheets[0]?.name).toBe("Ideas-Plan");
    expect(spec.sheets[0]?.rows).toEqual([["Ramen", null], ["Peas", 9]]);
  });

  it("writes a valid xlsx zip", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "rocky-sheet-"));
    const result = await writeSpreadsheet(
      { title: "Experiment", sheets: [{ name: "Results", columns: ["Trial", "Result"], rows: [[1, "Success"]] }] },
      directory,
    );
    const bytes = await readFile(result.path);

    expect(result.filename).toBe("Experiment.xlsx");
    expect(bytes.subarray(0, 2).toString()).toBe("PK");
  });

  it("creates a visible revision instead of replacing a workbook already open in ONLYOFFICE", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "rocky-sheet-revision-"));
    const spec = {
      title: "Minecraft Biomes",
      filename: "minecraft_biomes.xlsx",
      sheets: [{ name: "Biomes", columns: ["Biome"], rows: [["Plains"]] }],
    };

    const first = await writeSpreadsheet(spec, directory);
    expect(nextSpreadsheetPath(directory, first.filename)).toBe(path.join(directory, "minecraft_biomes-2.xlsx"));
    const second = await writeSpreadsheet(spec, directory);

    expect(first.filename).toBe("minecraft_biomes.xlsx");
    expect(second.filename).toBe("minecraft_biomes-2.xlsx");
    expect(second.path).not.toBe(first.path);
  });
});
