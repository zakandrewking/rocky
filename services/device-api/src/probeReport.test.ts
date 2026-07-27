import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { isProbeReport, saveProbeReport, summarizeProbeReport } from "./probeReport.ts";

describe("isProbeReport", () => {
  it("accepts a real report", () => {
    expect(isProbeReport({ probe: "rocky-cyberpi-stage1", checks: [] })).toBe(true);
  });

  it("rejects anything else", () => {
    expect(isProbeReport({ probe: "other", checks: [] })).toBe(false);
    expect(isProbeReport({ probe: "rocky-cyberpi-stage1" })).toBe(false);
    expect(isProbeReport(null)).toBe(false);
    expect(isProbeReport("string")).toBe(false);
  });
});

describe("summarizeProbeReport", () => {
  const report = {
    probe: "rocky-cyberpi-stage1",
    passed: 3,
    failed: 2,
    checks: [
      { section: "audio", name: "raw_path", ok: false, detail: "no raw-audio member found" },
      { section: "http", name: "health", ok: true, detail: "200 in 40 ms" },
      { section: "raw_output", name: "machine_i2s", ok: false, detail: "missing" },
    ],
    verdict: { answer: "no", note: "Go to Stage 2.", raw_capture: false, raw_playback: false, sockets: true },
  };

  it("leads with the counts and the gate answer", () => {
    const summary = summarizeProbeReport(report);
    expect(summary).toContain("3 checks, 3 passed, 2 failed");
    expect(summary).toContain("Decision gate: NO — Go to Stage 2.");
    expect(summary).toContain("sockets: yes");
  });

  it("lists only the failures, since those are the findings", () => {
    const summary = summarizeProbeReport(report);
    expect(summary).toContain("audio/raw_path: no raw-audio member found");
    expect(summary).toContain("raw_output/machine_i2s: missing");
    expect(summary).not.toContain("http/health");
  });

  it("handles a report with nothing failing", () => {
    const summary = summarizeProbeReport({ probe: "rocky-cyberpi-stage1", checks: [], passed: 0, failed: 0 });
    expect(summary).toContain("0 checks");
    expect(summary).not.toContain("Failed checks");
  });
});

describe("saveProbeReport", () => {
  it("writes a timestamped JSON file and returns its path", async () => {
    const directory = await mkdtemp(path.join(tmpdir(), "rocky-probe-"));
    const report = { probe: "rocky-cyberpi-stage1", checks: [] };

    const filePath = await saveProbeReport(directory, report, new Date("2026-07-27T12:34:56Z"));

    expect(path.basename(filePath)).toBe("probe-2026-07-27T12-34-56-000Z.json");
    expect(JSON.parse(await readFile(filePath, "utf8"))).toEqual(report);
  });
});
