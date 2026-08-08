#!/usr/bin/env node
// Turns a calibration telemetry log (from scripts/telemetry.mjs receiving
// steps/step12_loudness_calibration.py) into the constants the drive payload needs.
//
// Usage: node apps/robot/scripts/analyze-calibration.mjs <logfile.jsonl>
//
// This is the answer to docs/loudness-drive-problem-statement.md's core finding: seven payload
// versions guessed their sensitivity constants and none converged. The mapping here is
// piecewise-linear interpolation between measured anchors (ambient/talk/loud/scream), which
// works whether get_loudness() turns out to be linear or logarithmic -- no functional-form bet.
//
// Output: per-phase stats, a self-noise-vs-RPM table, a motor ring-down settle time, and a
// ready-to-paste constants block for steps/step13_loudness_drive_calibrated.py.

import { readFileSync } from "node:fs";

// Product choice, not measurement: where each measured vocal effort should land on the 0..1
// speed scale. Talking putters along, being loud is clearly moving, a typical scream saturates.
const LEVEL_TARGETS = { talk: 0.35, loud: 0.7, scream: 1.0 };

// Real calibration runs (2026-08-08) showed loud/scream phases are NOT steady tones -- a person
// screaming or talking loudly does it in bursts (words, breaths), so even the "scream" phase's
// raw samples spend a lot of time near the ambient floor between bursts. The median of a bursty
// phase lands in the quiet gaps, not the vocal effort itself -- using it as an anchor recreated
// v7's binary feel (a real run produced a non-monotonic curve this way). Anchors below instead
// start at a percentile high enough to represent "the level reached while actually making the
// sound" and escalate further only if needed to stay strictly above the previous anchor.
const ANCHOR_PERCENTILES = [75, 80, 85, 90, 95];

const logFile = process.argv[2];
if (!logFile) {
  console.error("usage: node apps/robot/scripts/analyze-calibration.mjs <logfile.jsonl>");
  process.exit(1);
}

const byPhase = new Map();
for (const line of readFileSync(logFile, "utf8").split("\n")) {
  if (!line.trim()) continue;
  let record;
  try {
    record = JSON.parse(line);
  } catch {
    continue;
  }
  if (record.phase === undefined || record.loud === undefined) continue;
  if (!byPhase.has(record.phase)) byPhase.set(record.phase, []);
  byPhase.get(record.phase).push(record);
}

if (byPhase.size === 0) {
  console.error(`no samples found in ${logFile}`);
  process.exit(1);
}

function percentile(sorted, p) {
  const index = Math.min(sorted.length - 1, Math.max(0, Math.round((p / 100) * (sorted.length - 1))));
  return sorted[index];
}

function stats(records) {
  const values = records.map((record) => record.loud).sort((a, b) => a - b);
  return {
    n: values.length,
    min: values[0],
    p10: percentile(values, 10),
    p25: percentile(values, 25),
    median: percentile(values, 50),
    p90: percentile(values, 90),
    max: values[values.length - 1],
    sorted: values,
  };
}

const round1 = (value) => Math.round(value * 10) / 10;

console.log(`\n=== per-phase stats (${logFile}) ===\n`);
console.log("phase       n     min   p10   p25   med   p90   max");
const phaseStats = new Map();
for (const [phase, records] of byPhase) {
  const s = stats(records);
  phaseStats.set(phase, s);
  console.log(
    `${phase.padEnd(10)} ${String(s.n).padStart(4)}  ${[s.min, s.p10, s.p25, s.median, s.p90, s.max]
      .map((v) => String(round1(v)).padStart(5))
      .join(" ")}`,
  );
}

const ambient = phaseStats.get("ambient");
if (!ambient) {
  console.error("\nno 'ambient' phase in this log -- can't derive anything without the floor");
  process.exit(1);
}

// --- Voice mapping anchors -----------------------------------------------------------------
// Everything is expressed as loudness ABOVE the ambient floor ("delta"), because the drive
// payload tracks a live floor (v7's safe leaky-min) rather than trusting this session's
// absolute numbers forever.
console.log("\n=== voice mapping ===\n");
console.log(`ambient floor: median ${round1(ambient.median)}, jitter p10..p90 ${round1(ambient.p10)}..${round1(ambient.p90)}`);

const anchors = [];
// Ambient's own jitter must map to level 0 or the robot creeps on background noise alone.
let prevDelta = round1(ambient.p90 - ambient.median);
anchors.push([prevDelta, 0.0]);
console.log(`ambient jitter ceiling (level 0 anchor): delta ${prevDelta}`);

for (const [phase, level] of Object.entries(LEVEL_TARGETS)) {
  const s = phaseStats.get(phase);
  if (!s) {
    console.warn(`missing '${phase}' phase -- skipping its anchor`);
    continue;
  }

  let chosenPercentile = null;
  let delta = null;
  for (const p of ANCHOR_PERCENTILES) {
    const candidate = round1(percentile(s.sorted, p) - ambient.median);
    if (candidate > prevDelta) {
      chosenPercentile = p;
      delta = candidate;
      break;
    }
  }
  if (delta === null) {
    // Even the top percentile didn't clear the previous anchor -- this phase didn't separate
    // from the one before it. Keep going (nudge past prevDelta) but flag it loudly: the fix is
    // re-running calibration with more contrast (louder/closer), not trusting this curve blindly.
    chosenPercentile = ANCHOR_PERCENTILES[ANCHOR_PERCENTILES.length - 1];
    delta = round1(prevDelta + 1);
    console.warn(
      `\nWARNING: '${phase}' phase never exceeded the previous anchor (even at p${chosenPercentile})` +
        ` -- it didn't register as distinctly louder. Anchor forced to ${delta}; re-run` +
        ` calibration with more contrast (louder, or closer to the mic) before trusting this.`,
    );
  }

  anchors.push([delta, level]);
  prevDelta = delta;
  console.log(
    `${phase.padEnd(7)} anchor: p${chosenPercentile} delta above floor = ${delta} ` +
      `(median delta was ${round1(s.median - ambient.median)})`,
  );
}

// Linear-vs-log diagnostic (informational; the piecewise curve works either way).
const talk = phaseStats.get("talk");
const scream = phaseStats.get("scream");
if (talk && scream) {
  const ratio = (scream.median - ambient.median) / Math.max(1e-9, talk.median - ambient.median);
  console.log(
    `\nscream/talk delta ratio: ${round1(ratio)} ` +
      `(large => sensor is linear-ish with pressure; near 1-3 => compressed/log-like)`,
  );
}

// --- Self-noise vs RPM ---------------------------------------------------------------------
console.log("\n=== motor self-noise (person silent) ===\n");
const motorPhases = [...phaseStats.keys()]
  .filter((phase) => /^motor\d+$/.test(phase))
  .sort((a, b) => Number(a.slice(5)) - Number(b.slice(5)));
for (const phase of motorPhases) {
  const rpm = Number(phase.slice(5));
  const s = phaseStats.get(phase);
  const delta = s.median - ambient.median;
  console.log(
    `rpm ${String(rpm).padStart(3)}: median ${round1(s.median)}, ` +
      `delta above floor ${round1(delta)}, delta/rpm ${round1(delta / rpm)}`,
  );
}
if (motorPhases.length === 0) console.log("(no motor phases in this log)");
console.log(
  "\nIf delta/rpm is roughly constant, v5's 'self-noise ~ K*rpm' model was right and continuous" +
    "\ndriving with subtraction is back on the table; if not, listen/drive alternation stands.",
);

// --- Ring-down settle time -----------------------------------------------------------------
console.log("\n=== motor-stop ring-down ===\n");
// Quiet threshold: ambient p90 plus a hair of margin. The settle time is when readings stay
// under it for the rest of the probe, not just first dip under (ringing oscillates).
const quietThreshold = ambient.p90 + Math.max(1, (ambient.p90 - ambient.p10) * 0.5);
let worstSettle = 0;
const settlePhases = [...byPhase.keys()]
  .filter((phase) => /^settle\d+$/.test(phase))
  .sort((a, b) => Number(a.slice(6)) - Number(b.slice(6)));
for (const phase of settlePhases) {
  const records = byPhase
    .get(phase)
    .filter((record) => record.since_stop !== undefined)
    .sort((a, b) => a.since_stop - b.since_stop);
  let settledAt = null;
  for (let index = records.length - 1; index >= 0; index -= 1) {
    if (records[index].loud > quietThreshold) break;
    settledAt = records[index].since_stop;
  }
  const label = settledAt === null ? "never settled within probe!" : `settled by ${settledAt}ms`;
  console.log(`${phase}: ${label} (threshold ${round1(quietThreshold)})`);
  worstSettle = Math.max(worstSettle, settledAt === null ? 1200 : settledAt);
}
if (settlePhases.length === 0) console.log("(no settle phases in this log)");

const settleMs = Math.ceil((worstSettle + 20) / 10) * 10; // +20ms margin, rounded up

// --- Paste block ----------------------------------------------------------------------------
console.log("\n=== constants for steps/step13_loudness_drive_calibrated.py ===\n");
console.log(`SETTLE_MS = ${settleMs}`);
console.log(
  `CURVE = (${anchors.map(([delta, level]) => `(${delta}, ${level})`).join(", ")})` +
    `  # (loudness above floor, speed level) from ${logFile.split("/").pop()}`,
);
console.log(`FLOOR_REF = ${round1(ambient.median)}  # this session's ambient median, for sanity-checking live floors`);
console.log();
