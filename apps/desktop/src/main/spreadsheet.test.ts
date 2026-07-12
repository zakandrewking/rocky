import { mkdtemp, readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { describe, expect, it } from "vitest";

import {
  editSpreadsheetFile,
  inspectSpreadsheetFile,
  nextSpreadsheetPath,
  normalizeSpreadsheetInspectSpec,
  normalizeSpreadsheetEditSpec,
  normalizeSpreadsheetSpec,
  writeSpreadsheet,
} from "./spreadsheet";

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

  it("normalizes targeted spreadsheet edits", () => {
    const spec = normalizeSpreadsheetEditSpec({
      setCells: [{ cell: "b2", value: "Mushroom island" }],
      appendRows: [{ rows: [["Desert", "Dry"]] }],
    });

    expect(spec.setCells).toEqual([{ cell: "B2", value: "Mushroom island" }]);
    expect(spec.appendRows).toEqual([{ rows: [["Desert", "Dry"]] }]);
  });

  it("edits cells and appends rows in an existing workbook", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "rocky-sheet-edit-"));
    const created = await writeSpreadsheet(
      { title: "Biomes", sheets: [{ name: "Biomes", columns: ["Biome", "Note"], rows: [["Plains", "Flat"]] }] },
      directory,
    );

    const result = await editSpreadsheetFile(created.path, {
      setCells: [{ cell: "B2", value: "Grassy" }],
      appendRows: [{ rows: [["Desert", "Dry"]] }],
    });

    expect(result.filename).toBe("Biomes.xlsx");
    expect(result.setCells).toEqual([{ cell: "B2", value: "Grassy", sheet: "Biomes" }]);
    expect(result.appendedRows).toEqual([{ sheet: "Biomes", startRow: 3, rows: [["Desert", "Dry"]] }]);
  });

  it("inspects workbook structure and ranges", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "rocky-sheet-inspect-"));
    const created = await writeSpreadsheet(
      { title: "Biomes", sheets: [{ name: "Biomes", columns: ["Biome", "Note"], rows: [["Plains", "Flat"]] }] },
      directory,
    );

    expect(normalizeSpreadsheetInspectSpec({ range: "a1:b2" })).toEqual({ range: "A1:B2" });
    const result = await inspectSpreadsheetFile(created.path, { sheet: "Biomes", range: "A1:B2" });

    expect(result.sheets).toEqual([{ name: "Biomes", rowCount: 2, columnCount: 2 }]);
    expect(result.inspected).toEqual({
      sheet: "Biomes",
      range: "A1:B2",
      rows: [["Biome", "Note"], ["Plains", "Flat"]],
    });
  });
});
