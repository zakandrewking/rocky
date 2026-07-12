import { execFile } from "node:child_process";
import { mkdtemp } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";

import ExcelJS from "exceljs";
import { describe, expect, it } from "vitest";

import { writeHowToDoc } from "./howToDocument";
import { editSpreadsheetFile, inspectSpreadsheetFile, writeSpreadsheet } from "./spreadsheet";

const execFileAsync = promisify(execFile);

async function unzipEntry(archivePath: string, entryPath: string): Promise<string | null> {
  try {
    const { stdout } = await execFileAsync("unzip", ["-p", archivePath, entryPath], { maxBuffer: 8 * 1024 * 1024 });
    return stdout;
  } catch (error) {
    if (error && typeof error === "object" && "code" in error && error.code === "ENOENT") return null;
    throw error;
  }
}

describe("Rocky artifact quality", () => {
  it("creates structurally sound DOCX how-to guides with real styles and numbering", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "rocky-doc-quality-"));
    const result = await writeHowToDoc({
      title: "How to Build a Safe Marble Ramp",
      purpose: "Build a small ramp and compare how far marbles roll.",
      materials: ["Cardboard", "Tape", "Marble", "Measuring tape"],
      safetyNotes: ["Keep marbles away from very small children."],
      steps: [
        "Fold one cardboard base.",
        "Tape the ramp so it does not slide.",
        "Release the marble from the same mark each time.",
        "Measure the roll distance.",
      ],
      tips: ["Change one ramp height at a time."],
      sections: [{
        heading: "What to record",
        bullets: ["Ramp height", "Roll distance", "What changed"],
      }],
    }, directory);

    const documentXml = await unzipEntry(result.path, "word/document.xml");
    const stylesXml = await unzipEntry(result.path, "word/styles.xml");
    const numberingXml = await unzipEntry(result.path, "word/numbering.xml");
    if (!documentXml || !stylesXml || !numberingXml) return;

    expect(documentXml).toContain("How to Build a Safe Marble Ramp");
    expect(documentXml).toContain("Build a small ramp");
    expect(documentXml).toContain("Fold one cardboard base.");
    expect(documentXml).toContain("What to record");
    expect(documentXml).toContain("Ramp height");
    expect(documentXml).toContain('w:w="12240"');
    expect(documentXml).toContain('w:h="15840"');
    expect(documentXml).toContain("<w:pgMar");
    expect(documentXml).toContain("<w:numPr>");
    expect(stylesXml).toContain('w:styleId="Heading1"');
    expect(stylesXml).toContain('w:styleId="Heading2"');
    expect(numberingXml).toContain('w:val="decimal"');
    expect(numberingXml).toContain('w:val="bullet"');
    expect(documentXml).not.toContain("<br>");
    expect(documentXml).not.toContain("**");
  });

  it("creates readable XLSX workbooks with frozen headers, filters, styles, and wrapped content", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "rocky-xlsx-quality-"));
    const result = await writeSpreadsheet({
      title: "Minecraft Biome Catalog",
      filename: "biomes.xlsx",
      sheets: [{
        name: "Biomes",
        columns: ["Biome", "Temperature", "Good for building", "Notes"],
        rows: [
          ["Plains", "Temperate", "Yes", "Flat, open, easy first base location."],
          ["Cherry Grove", "Temperate", "Yes", "Pink trees. High delight per block."],
          ["Deep Dark", "Cold", "No", "Dangerous. Quiet feet required."],
        ],
      }],
    }, directory);

    const workbook = new ExcelJS.Workbook();
    await workbook.xlsx.readFile(result.path);
    const sheet = workbook.getWorksheet("Biomes");

    expect(sheet).toBeTruthy();
    expect(sheet?.views[0]).toMatchObject({ state: "frozen", ySplit: 1 });
    expect(sheet?.autoFilter).toBe("A1:D1");
    expect(sheet?.getRow(1).height).toBe(28);
    expect(sheet?.getCell("A1").font).toMatchObject({ bold: true });
    expect(sheet?.getCell("A1").fill).toMatchObject({
      type: "pattern",
      pattern: "solid",
      fgColor: { argb: "FF28475C" },
    });
    expect(sheet?.getCell("D2").alignment).toMatchObject({ wrapText: true, vertical: "top" });
    expect(sheet?.getColumn(4).width).toBeGreaterThan(20);

    const inspected = await inspectSpreadsheetFile(result.path, { sheet: "Biomes", range: "A1:D4" });
    expect(inspected.inspected?.rows).toEqual([
      ["Biome", "Temperature", "Good for building", "Notes"],
      ["Plains", "Temperate", "Yes", "Flat, open, easy first base location."],
      ["Cherry Grove", "Temperate", "Yes", "Pink trees. High delight per block."],
      ["Deep Dark", "Cold", "No", "Dangerous. Quiet feet required."],
    ]);
  });

  it("edits and re-inspects existing XLSX files without replacing the whole workbook", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "rocky-xlsx-edit-quality-"));
    const result = await writeSpreadsheet({
      title: "Project Tracker",
      sheets: [{
        name: "Tasks",
        columns: ["Task", "Status"],
        rows: [["Find cardboard", "done"]],
      }],
    }, directory);

    await editSpreadsheetFile(result.path, {
      setCells: [{ sheet: "Tasks", cell: "B2", value: "complete" }],
      appendRows: [{ sheet: "Tasks", rows: [["Test ramp", "next"]] }],
    });
    const inspected = await inspectSpreadsheetFile(result.path, { sheet: "Tasks", range: "A1:B3" });

    expect(inspected.inspected?.rows).toEqual([
      ["Task", "Status"],
      ["Find cardboard", "complete"],
      ["Test ramp", "next"],
    ]);
  });

  it("preserves external workbook edits when Rocky rereads before targeted XLSX edits", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "rocky-xlsx-concurrent-quality-"));
    const result = await writeSpreadsheet({
      title: "Shared Tracker",
      sheets: [{
        name: "Tasks",
        columns: ["Task", "Owner", "Status"],
        rows: [
          ["Find cardboard", "Zak", "todo"],
          ["Tape ramp", "Rocky", "todo"],
        ],
      }],
    }, directory);

    const humanWorkbook = new ExcelJS.Workbook();
    await humanWorkbook.xlsx.readFile(result.path);
    const humanSheet = humanWorkbook.getWorksheet("Tasks");
    if (!humanSheet) throw new Error("Tasks sheet missing.");
    humanSheet.getCell("C2").value = "human changed";
    await humanWorkbook.xlsx.writeFile(result.path);

    await editSpreadsheetFile(result.path, {
      setCells: [{ sheet: "Tasks", cell: "C3", value: "rocky changed" }],
    });
    const inspected = await inspectSpreadsheetFile(result.path, { sheet: "Tasks", range: "A1:C3" });

    expect(inspected.inspected?.rows).toEqual([
      ["Task", "Owner", "Status"],
      ["Find cardboard", "Zak", "human changed"],
      ["Tape ramp", "Rocky", "rocky changed"],
    ]);
  });
});
