#!/usr/bin/env node
import { createRequire } from "node:module";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import process from "node:process";

const require = createRequire(new URL("../apps/desktop/package.json", import.meta.url));
const ExcelJS = require("exceljs");

async function main() {
  const directory = await mkdtemp(path.join(os.tmpdir(), "rocky-artifact-check-"));
  try {
    const filePath = path.join(directory, "cli-check.xlsx");
    const workbook = new ExcelJS.Workbook();
    const sheet = workbook.addWorksheet("Tasks");
    sheet.addRow(["Task", "Status"]);
    sheet.addRow(["Build ramp", "todo"]);
    await workbook.xlsx.writeFile(filePath);

    const childProcess = await import("node:child_process");
    const { promisify } = await import("node:util");
    const execFile = promisify(childProcess.execFile);
    const script = path.resolve("scripts/rocky-xlsx.mjs");

    await execFile("node", [script, "set-cell", filePath, "Tasks!B2", "done"]);
    await execFile("node", [script, "append-row", filePath, "Tasks", "[\"Test ramp\",\"next\"]"]);
    const { stdout } = await execFile("node", [script, "inspect", filePath, "Tasks!A1:B3"]);
    const inspected = JSON.parse(stdout);
    const expected = [
      ["Task", "Status"],
      ["Build ramp", "done"],
      ["Test ramp", "next"],
    ];
    if (JSON.stringify(inspected.rows) !== JSON.stringify(expected)) {
      throw new Error(`Unexpected CLI workbook rows: ${JSON.stringify(inspected.rows)}`);
    }
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
