import { describe, expect, it } from "vitest";

import { activeSheetCommand, columnName } from "./onlyOfficeBridge";

describe("ONLYOFFICE bridge commands", () => {
  it("converts column indexes to spreadsheet names", () => {
    expect([0, 25, 26, 51].map(columnName)).toEqual(["A", "Z", "AA", "AZ"]);
  });

  it("builds an active-sheet matrix and bounded target range", () => {
    const command = activeSheetCommand({
      title: "Oceans",
      sheets: [{ name: "Animals", columns: ["Ocean", "Animal"], rows: [["Pacific", "Octopus"]] }],
    });
    expect(command).toMatchObject({
      type: "replace_active_sheet",
      sheetName: "Animals",
      values: [["Ocean", "Animal"], ["Pacific", "Octopus"]],
      targetRange: "A1:B2",
      clearRange: "A1:T201",
    });
  });
});
