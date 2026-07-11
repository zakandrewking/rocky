#!/usr/bin/env node
import process from "node:process";
import { createRequire } from "node:module";

const require = createRequire(new URL("../apps/desktop/package.json", import.meta.url));
const ExcelJS = require("exceljs");

function usage() {
  console.error(`Usage:
  pnpm xlsx:rocky inspect <file.xlsx> [Sheet!A1:D10]
  pnpm xlsx:rocky set-cell <file.xlsx> <Sheet!A1> <value>
  pnpm xlsx:rocky append-row <file.xlsx> <Sheet> <json-array>
`);
  process.exit(1);
}

function parseSheetRange(value, fallbackSheet) {
  const bang = value.indexOf("!");
  if (bang === -1) return { sheetName: fallbackSheet, address: value };
  return { sheetName: value.slice(0, bang), address: value.slice(bang + 1) };
}

function parseCellValue(value) {
  if (value === "null") return null;
  if (value === "true") return true;
  if (value === "false") return false;
  const number = Number(value);
  if (value.trim() !== "" && Number.isFinite(number)) return number;
  return value;
}

async function loadWorkbook(filePath) {
  const workbook = new ExcelJS.Workbook();
  await workbook.xlsx.readFile(filePath);
  return workbook;
}

function sheetOrThrow(workbook, sheetName) {
  const worksheet = workbook.getWorksheet(sheetName);
  if (!worksheet) throw new Error(`Sheet not found: ${sheetName}`);
  return worksheet;
}

function inspectRange(worksheet, address) {
  const range = address.includes(":") ? address : `${address}:${address}`;
  const [start, end] = range.split(":");
  const startCell = worksheet.getCell(start);
  const endCell = worksheet.getCell(end);
  const rows = [];
  for (let rowNumber = startCell.row; rowNumber <= endCell.row; rowNumber += 1) {
    const row = [];
    for (let columnNumber = startCell.col; columnNumber <= endCell.col; columnNumber += 1) {
      const cell = worksheet.getCell(rowNumber, columnNumber);
      row.push(cell.value ?? null);
    }
    rows.push(row);
  }
  return rows;
}

async function main() {
  const [command, filePath, target, value] = process.argv.slice(2);
  if (!command || !filePath) usage();
  const workbook = await loadWorkbook(filePath);

  if (command === "inspect") {
    const firstSheet = workbook.worksheets[0];
    if (!firstSheet) throw new Error("Workbook has no worksheets.");
    const { sheetName, address } = parseSheetRange(target ?? `${firstSheet.name}!A1:J20`, firstSheet.name);
    const rows = inspectRange(sheetOrThrow(workbook, sheetName), address);
    console.log(JSON.stringify({ file: filePath, sheet: sheetName, range: address, rows }, null, 2));
    return;
  }

  if (command === "set-cell") {
    if (!target || value === undefined) usage();
    const { sheetName, address } = parseSheetRange(target, "");
    if (!sheetName) throw new Error("Use Sheet!A1 for set-cell target.");
    sheetOrThrow(workbook, sheetName).getCell(address).value = parseCellValue(value);
    await workbook.xlsx.writeFile(filePath);
    console.log(`Updated ${sheetName}!${address}`);
    return;
  }

  if (command === "append-row") {
    if (!target || value === undefined) usage();
    const parsed = JSON.parse(value);
    if (!Array.isArray(parsed)) throw new Error("append-row value must be a JSON array.");
    sheetOrThrow(workbook, target).addRow(parsed.map((item) => parseCellValue(String(item))));
    await workbook.xlsx.writeFile(filePath);
    console.log(`Appended row to ${target}`);
    return;
  }

  usage();
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
