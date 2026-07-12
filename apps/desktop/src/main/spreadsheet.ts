import ExcelJS from "exceljs";
import { existsSync } from "node:fs";
import { mkdir } from "node:fs/promises";
import path from "node:path";

import type {
  CellValue,
  SpreadsheetAppendRowsEdit,
  SpreadsheetCellEdit,
  SpreadsheetEditResult,
  SpreadsheetEditSpec,
  SpreadsheetInspectResult,
  SpreadsheetInspectSpec,
  SpreadsheetResult,
  SpreadsheetSheet,
  SpreadsheetSpec,
} from "../shared/types";

const MAX_SHEETS = 6;
const MAX_COLUMNS = 20;
const MAX_ROWS = 200;
const CELL_ADDRESS = /^[A-Z]{1,3}[1-9][0-9]{0,6}$/i;
const CELL_RANGE = /^([A-Z]{1,3}[1-9][0-9]{0,6})(?::([A-Z]{1,3}[1-9][0-9]{0,6}))?$/i;

export function nextSpreadsheetPath(outputDirectory: string, filename: string): string {
  const initialPath = path.join(outputDirectory, filename);
  if (!existsSync(initialPath)) return initialPath;

  const parsed = path.parse(filename);
  for (let revision = 2; revision < 10_000; revision += 1) {
    const candidate = path.join(outputDirectory, `${parsed.name}-${revision}${parsed.ext}`);
    if (!existsSync(candidate)) return candidate;
  }
  throw new Error(`Too many revisions of ${filename}`);
}

function cleanText(value: unknown, fallback: string, maxLength: number): string {
  if (typeof value !== "string") return fallback;
  const clean = value.trim().slice(0, maxLength);
  return clean || fallback;
}

function cleanFilename(value: unknown, fallback: string): string {
  const source = cleanText(value, fallback, 80).replace(/\.xlsx$/i, "");
  const clean = source.replace(/[^a-zA-Z0-9 _-]/g, "").trim().replace(/\s+/g, "-");
  return `${clean || fallback}.xlsx`;
}

function cleanCell(value: unknown): CellValue {
  if (value === null || typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
    return typeof value === "string" ? value.slice(0, 500) : value;
  }
  return String(value).slice(0, 500);
}

function normalizeCellAddress(value: unknown): string {
  const address = cleanText(value, "", 20).toUpperCase();
  if (!CELL_ADDRESS.test(address)) throw new Error(`Invalid cell address: ${address || String(value)}`);
  return address;
}

function normalizeRange(value: unknown, fallback = "A1:J20"): string {
  const range = cleanText(value, fallback, 40).toUpperCase();
  if (!CELL_RANGE.test(range)) throw new Error(`Invalid cell range: ${range}`);
  return range.includes(":") ? range : `${range}:${range}`;
}

function normalizeCellEdits(value: unknown): SpreadsheetCellEdit[] {
  if (!Array.isArray(value)) return [];
  return value.slice(0, 80).map((item) => {
    const source = typeof item === "object" && item !== null ? item as Record<string, unknown> : {};
    const edit: SpreadsheetCellEdit = {
      cell: normalizeCellAddress(source.cell),
      value: cleanCell(source.value),
    };
    if (typeof source.sheet === "string") edit.sheet = cleanText(source.sheet, "", 31).replace(/[\\/*?:[\]]/g, "-");
    return edit;
  });
}

function normalizeAppendRows(value: unknown): SpreadsheetAppendRowsEdit[] {
  if (!Array.isArray(value)) return [];
  return value.slice(0, 20).map((item) => {
    const source = typeof item === "object" && item !== null ? item as Record<string, unknown> : {};
    const rows = Array.isArray(source.rows) ? source.rows : [];
    const edit: SpreadsheetAppendRowsEdit = {
      rows: rows.slice(0, 80).map((row) => {
        const values = Array.isArray(row) ? row : [row];
        return values.slice(0, MAX_COLUMNS).map(cleanCell);
      }),
    };
    if (typeof source.sheet === "string") edit.sheet = cleanText(source.sheet, "", 31).replace(/[\\/*?:[\]]/g, "-");
    return edit;
  }).filter((edit) => edit.rows.length);
}

export function normalizeSpreadsheetEditSpec(value: unknown): SpreadsheetEditSpec {
  const source = typeof value === "object" && value !== null ? value as Record<string, unknown> : {};
  return {
    setCells: normalizeCellEdits(source.setCells),
    appendRows: normalizeAppendRows(source.appendRows),
  };
}

export function normalizeSpreadsheetInspectSpec(value: unknown): SpreadsheetInspectSpec {
  const source = typeof value === "object" && value !== null ? value as Record<string, unknown> : {};
  const result: SpreadsheetInspectSpec = {};
  if (typeof source.sheet === "string") result.sheet = cleanText(source.sheet, "", 31).replace(/[\\/*?:[\]]/g, "-");
  if (typeof source.range === "string") result.range = normalizeRange(source.range);
  return result;
}

function normalizeSheet(value: unknown, index: number): SpreadsheetSheet {
  const source = typeof value === "object" && value !== null ? (value as Record<string, unknown>) : {};
  const rawColumns = Array.isArray(source.columns) ? source.columns : [];
  const columns = rawColumns
    .slice(0, MAX_COLUMNS)
    .map((column, columnIndex) => cleanText(column, `Column ${columnIndex + 1}`, 60));
  const safeColumns = columns.length > 0 ? columns : ["Notes"];
  const rawRows = Array.isArray(source.rows) ? source.rows : [];
  const rows = rawRows.slice(0, MAX_ROWS).map((row) => {
    const values = Array.isArray(row) ? row : [row];
    return safeColumns.map((_, columnIndex) => cleanCell(values[columnIndex] ?? null));
  });

  return {
    name: cleanText(source.name, `Sheet ${index + 1}`, 31).replace(/[\\/*?:[\]]/g, "-"),
    columns: safeColumns,
    rows,
  };
}

export function normalizeSpreadsheetSpec(value: unknown): SpreadsheetSpec {
  const source = typeof value === "object" && value !== null ? (value as Record<string, unknown>) : {};
  const title = cleanText(source.title, "Rocky Spreadsheet", 100);
  const rawSheets = Array.isArray(source.sheets) ? source.sheets : [];
  const sheets = (rawSheets.length ? rawSheets : [{}])
    .slice(0, MAX_SHEETS)
    .map((sheet, index) => normalizeSheet(sheet, index));

  return {
    title,
    filename: cleanFilename(source.filename, title),
    sheets,
  };
}

function applySheetStyle(worksheet: ExcelJS.Worksheet, sheet: SpreadsheetSheet): void {
  worksheet.views = [{ state: "frozen", ySplit: 1 }];
  worksheet.autoFilter = {
    from: { row: 1, column: 1 },
    to: { row: 1, column: sheet.columns.length },
  };
  worksheet.getRow(1).height = 28;
  worksheet.getRow(1).eachCell((cell) => {
    cell.font = { bold: true, color: { argb: "FFF7FBFF" }, size: 12 };
    cell.fill = { type: "pattern", pattern: "solid", fgColor: { argb: "FF28475C" } };
    cell.alignment = { vertical: "middle" };
  });

  worksheet.eachRow((row, rowNumber) => {
    if (rowNumber > 1 && rowNumber % 2 === 1) {
      row.eachCell((cell) => {
        cell.fill = { type: "pattern", pattern: "solid", fgColor: { argb: "FFEAF7F3" } };
      });
    }
    row.eachCell((cell) => {
      cell.alignment = { vertical: "top", wrapText: true };
      cell.border = {
        bottom: { style: "hair", color: { argb: "FFB9D7D0" } },
      };
    });
  });

  sheet.columns.forEach((heading, index) => {
    const values = sheet.rows.map((row) => String(row[index] ?? ""));
    const longest = Math.max(heading.length, ...values.map((value) => Math.min(value.length, 45)));
    worksheet.getColumn(index + 1).width = Math.max(12, Math.min(longest + 3, 48));
  });
}

export async function writeSpreadsheet(
  value: unknown,
  outputDirectory: string,
): Promise<SpreadsheetResult> {
  const spec = normalizeSpreadsheetSpec(value);
  await mkdir(outputDirectory, { recursive: true });

  const workbook = new ExcelJS.Workbook();
  workbook.creator = "Rocky";
  workbook.title = spec.title;
  workbook.created = new Date();

  for (const sheet of spec.sheets) {
    const worksheet = workbook.addWorksheet(sheet.name);
    worksheet.addRow(sheet.columns);
    for (const row of sheet.rows) worksheet.addRow(row);
    applySheetStyle(worksheet, sheet);
  }

  const requestedFilename = spec.filename ?? cleanFilename(undefined, spec.title);
  // ONLYOFFICE keeps an open workbook cached and does not reliably refresh when another process
  // replaces the same path. A distinct revision guarantees that the updated workbook opens visibly.
  const filePath = nextSpreadsheetPath(outputDirectory, requestedFilename);
  const filename = path.basename(filePath);
  await workbook.xlsx.writeFile(filePath);

  return {
    path: filePath,
    filename,
    title: spec.title,
    sheets: spec.sheets,
  };
}

export async function editSpreadsheetFile(
  filePath: string,
  value: unknown,
): Promise<SpreadsheetEditResult> {
  const spec = normalizeSpreadsheetEditSpec(value);
  if (!spec.setCells?.length && !spec.appendRows?.length) {
    throw new Error("No spreadsheet edits were requested.");
  }

  const workbook = new ExcelJS.Workbook();
  await workbook.xlsx.readFile(filePath);
  const firstSheet = workbook.worksheets[0];
  if (!firstSheet) throw new Error("Workbook has no worksheets.");

  const setCells: SpreadsheetCellEdit[] = [];
  const appendedRows: SpreadsheetEditResult["appendedRows"] = [];

  for (const edit of spec.setCells ?? []) {
    const worksheet = edit.sheet ? workbook.getWorksheet(edit.sheet) : firstSheet;
    if (!worksheet) throw new Error(`Sheet not found: ${edit.sheet}`);
    worksheet.getCell(edit.cell).value = edit.value;
    setCells.push({ ...edit, sheet: worksheet.name });
  }

  for (const edit of spec.appendRows ?? []) {
    const worksheet = edit.sheet ? workbook.getWorksheet(edit.sheet) : firstSheet;
    if (!worksheet) throw new Error(`Sheet not found: ${edit.sheet}`);
    const startRow = worksheet.rowCount + 1;
    for (const row of edit.rows) worksheet.addRow(row);
    appendedRows.push({ sheet: worksheet.name, startRow, rows: edit.rows });
  }

  await workbook.xlsx.writeFile(filePath);
  return {
    path: filePath,
    filename: path.basename(filePath),
    setCells,
    appendedRows,
  };
}

export async function inspectSpreadsheetFile(
  filePath: string,
  value: unknown = {},
): Promise<SpreadsheetInspectResult> {
  const spec = normalizeSpreadsheetInspectSpec(value);
  const workbook = new ExcelJS.Workbook();
  await workbook.xlsx.readFile(filePath);
  const sheets = workbook.worksheets.map((worksheet) => ({
    name: worksheet.name,
    rowCount: worksheet.rowCount,
    columnCount: worksheet.columnCount,
  }));
  const firstSheet = workbook.worksheets[0];
  if (!firstSheet) throw new Error("Workbook has no worksheets.");

  const requestedSheet = spec.sheet ? workbook.getWorksheet(spec.sheet) : firstSheet;
  if (!requestedSheet) throw new Error(`Sheet not found: ${spec.sheet}`);
  const range = normalizeRange(spec.range);
  const [start = "A1", end = start] = range.split(":");
  const startCell = requestedSheet.getCell(start);
  const endCell = requestedSheet.getCell(end);
  const rows: CellValue[][] = [];
  for (let rowNumber = startCell.row; rowNumber <= endCell.row; rowNumber += 1) {
    const row: CellValue[] = [];
    for (let columnNumber = startCell.col; columnNumber <= endCell.col; columnNumber += 1) {
      row.push(cleanCell(requestedSheet.getCell(rowNumber, columnNumber).value));
    }
    rows.push(row);
  }

  return {
    path: filePath,
    filename: path.basename(filePath),
    sheets,
    inspected: {
      sheet: requestedSheet.name,
      range,
      rows,
    },
  };
}
