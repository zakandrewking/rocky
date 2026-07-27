import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";

export interface ProbeCheck {
  readonly section?: string;
  readonly name?: string;
  readonly ok?: boolean;
  readonly detail?: string;
}

export interface ProbeVerdict {
  readonly answer?: string;
  readonly note?: string;
  readonly raw_capture?: boolean;
  readonly raw_playback?: boolean;
  readonly sockets?: boolean;
}

export interface ProbeReport {
  readonly probe?: string;
  readonly checks?: readonly ProbeCheck[];
  readonly passed?: number;
  readonly failed?: number;
  readonly verdict?: ProbeVerdict;
}

export function isProbeReport(value: unknown): value is ProbeReport {
  if (typeof value !== "object" || value === null) return false;
  const candidate = value as ProbeReport;
  return candidate.probe === "rocky-cyberpi-stage1" && Array.isArray(candidate.checks);
}

/** Human-readable summary printed to the operator's terminal when a report lands. */
export function summarizeProbeReport(report: ProbeReport): string {
  const checks = report.checks ?? [];
  const lines: string[] = [];

  lines.push(`Rocky CyberPi probe: ${checks.length} checks, ${report.passed ?? 0} passed, ${report.failed ?? 0} failed`);

  const verdict = report.verdict;
  if (verdict) {
    lines.push(`Decision gate: ${(verdict.answer ?? "unknown").toUpperCase()} — ${verdict.note ?? ""}`.trimEnd());
    lines.push(
      `  raw capture: ${verdict.raw_capture ? "yes" : "no"}` +
        `  raw playback: ${verdict.raw_playback ? "yes" : "no"}` +
        `  sockets: ${verdict.sockets ? "yes" : "no"}`,
    );
  }

  // Failures are the interesting part of this report, so lead with them.
  const failures = checks.filter((check) => check.ok === false);
  if (failures.length) {
    lines.push("Failed checks:");
    for (const failure of failures) {
      lines.push(`  - ${failure.section ?? "?"}/${failure.name ?? "?"}: ${failure.detail ?? ""}`.trimEnd());
    }
  }
  return lines.join("\n");
}

/** Writes the report under ignored local data and returns its path. */
export async function saveProbeReport(directory: string, report: ProbeReport, now = new Date()): Promise<string> {
  await mkdir(directory, { recursive: true });
  const stamp = now.toISOString().replace(/[:.]/g, "-");
  const filePath = path.join(directory, `probe-${stamp}.json`);
  await writeFile(filePath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
  return filePath;
}
