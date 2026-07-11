import ExcelJS from "exceljs";
import { mkdir } from "node:fs/promises";
import path from "node:path";

import type {
  CellValue,
  SpreadsheetResult,
  SpreadsheetSheet,
  SpreadsheetSpec,
} from "../shared/types";

const MAX_SHEETS = 6;
const MAX_COLUMNS = 20;
const MAX_ROWS = 200;

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

  const filename = spec.filename ?? cleanFilename(undefined, spec.title);
  const filePath = path.join(outputDirectory, filename);
  await workbook.xlsx.writeFile(filePath);

  return {
    path: filePath,
    filename,
    title: spec.title,
    sheets: spec.sheets,
  };
}

