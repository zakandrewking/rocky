#!/usr/bin/env node
// Summarizes the JSONL produced by qualify-navigation-sensors.mjs. It reports distributions and
// raw trial counts; it does not turn a few good runs into a pass. Acceptance requires repeated
// trials across surfaces, battery states, target materials, and the mounted phone load.

import { readFileSync } from "node:fs";

const logFile = process.argv[2];
if (!logFile) {
  console.error("usage: node apps/robot/scripts/analyze-navigation-qualification.mjs <logfile.jsonl>");
  process.exit(1);
}

const records = readFileSync(logFile, "utf8")
  .split("\n")
  .filter(Boolean)
  .map((line, index) => {
    try {
      return JSON.parse(line);
    } catch {
      throw new Error(`invalid JSON on line ${index + 1}`);
    }
  });

function percentile(values, fraction) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(fraction * sorted.length))];
}

function stats(values) {
  if (!values.length) return null;
  const mean = values.reduce((sum, value) => sum + value, 0) / values.length;
  const variance = values.reduce((sum, value) => sum + (value - mean) ** 2, 0) / values.length;
  const standardDeviation = Math.sqrt(variance);
  return {
    n: values.length,
    mean,
    standardDeviation,
    coefficientOfVariation: mean === 0 ? null : Math.abs(standardDeviation / mean),
    min: Math.min(...values),
    max: Math.max(...values),
    p50: percentile(values, 0.5),
    p95: percentile(values, 0.95),
  };
}

function format(summary, unit = "") {
  if (!summary) return "no trials";
  const number = (value) => `${value.toFixed(2)}${unit}`;
  const cv = summary.coefficientOfVariation === null
    ? ""
    : ` cv=${(summary.coefficientOfVariation * 100).toFixed(1)}%`;
  return `n=${summary.n} mean=${number(summary.mean)} p50=${number(summary.p50)} p95=${number(summary.p95)} range=${number(summary.min)}..${number(summary.max)}${cv}`;
}

function wrapDelta(start, end) {
  let delta = end - start;
  while (delta > 180) delta -= 360;
  while (delta < -180) delta += 360;
  return delta;
}

const starts = new Map(
  records
    .filter((record) => record.source === "host" && record.event === "trial_start")
    .map((record) => [record.id, record]),
);
const ends = records.filter((record) => record.source === "host" && record.event === "trial_end");

const stationaryDrift = [];
const stationaryDriftRate = [];
const ultrasonicErrors = [];
const driveCm = [];
const spinYawErrors = [];
const driveGroups = new Map();
const spinGroups = new Map();
let closeUltrasonicReadings = 0;
let missedCloseUltrasonicReadings = 0;

function addGroup(groups, key, value) {
  const values = groups.get(key) ?? [];
  values.push(value);
  groups.set(key, values);
}

function unwrappedDelta(samples) {
  let total = 0;
  for (let index = 1; index < samples.length; index += 1) {
    total += wrapDelta(samples[index - 1].yaw, samples[index].yaw);
  }
  return total;
}

for (const end of ends) {
  const start = starts.get(end.trial);
  if (!start) continue;
  const trialRecords = records.filter(
    (record) => record.source === "board" && record.trial === end.trial,
  );
  const yawSamples = trialRecords.filter((record) => Number.isFinite(record.yaw));
  if (start.kind === "stationary_yaw" && yawSamples.length >= 2) {
    const drift = Math.abs(unwrappedDelta(yawSamples));
    const elapsedMinutes = Math.max(
      1 / 60,
      (yawSamples.at(-1).t - yawSamples[0].t) / 60_000,
    );
    stationaryDrift.push(drift);
    stationaryDriftRate.push(drift / elapsedMinutes);
  } else if (start.kind === "ultrasonic" && Number.isFinite(end.actual_cm)) {
    const readings = trialRecords
      .map((record) => record.distance_cm)
      .filter(Number.isFinite);
    if (readings.length) {
      const meanReading = readings.reduce((sum, value) => sum + value, 0) / readings.length;
      ultrasonicErrors.push(meanReading - end.actual_cm);
      if (end.actual_cm < 35) {
        closeUltrasonicReadings += readings.length;
        missedCloseUltrasonicReadings += readings.filter((value) => value >= 35).length;
      }
    }
  } else if (start.kind === "drive" && Number.isFinite(end.actual_cm)) {
    driveCm.push(Math.abs(end.actual_cm));
    addGroup(
      driveGroups,
      `${start.rpm}rpm/${start.duration_ms}ms/direction=${start.direction}`,
      Math.abs(end.actual_cm),
    );
  } else if (start.kind === "spin" && Number.isFinite(end.actual_degrees)) {
    const motionEnd = records.find(
      (record) => record.source === "board" && record.trial === end.trial && record.event === "motion_end",
    );
    if (motionEnd && Number.isFinite(motionEnd.start_yaw) && Number.isFinite(motionEnd.yaw)) {
      const error = wrapDelta(motionEnd.start_yaw, motionEnd.yaw) - end.actual_degrees;
      spinYawErrors.push(error);
      addGroup(
        spinGroups,
        `${start.rpm}rpm/${start.duration_ms}ms/direction=${start.direction}`,
        Math.abs(error),
      );
    }
  }
}

console.log(`qualification log: ${logFile}`);
console.log(`completed trials: ${ends.length}`);
console.log(`stationary |yaw drift|: ${format(stats(stationaryDrift), "°")}`);
console.log(`stationary yaw drift rate: ${format(stats(stationaryDriftRate), "°/min")}`);
console.log(`ultrasonic per-trial mean signed error: ${format(stats(ultrasonicErrors), "cm")}`);
console.log(`ultrasonic per-trial mean absolute error: ${format(stats(ultrasonicErrors.map(Math.abs)), "cm")}`);
console.log(
  `ultrasonic misses while target <35cm: ${missedCloseUltrasonicReadings}/${closeUltrasonicReadings} readings`,
);
console.log(`drive displacement per configured pulse: ${format(stats(driveCm), "cm")}`);
console.log(`yaw delta minus physical turn: ${format(stats(spinYawErrors), "°")}`);
console.log(`yaw-vs-physical absolute error: ${format(stats(spinYawErrors.map(Math.abs)), "°")}`);

for (const [configuration, values] of driveGroups) {
  console.log(`  drive ${configuration}: ${format(stats(values), "cm")}`);
}
for (const [configuration, values] of spinGroups) {
  console.log(`  spin ${configuration} absolute error: ${format(stats(values), "°")}`);
}

console.log("\nEvidence gates (judge per configuration and surface, not only in aggregate):");
console.log("- yaw: at least 20 physical turns plus stationary runs; report p95, drift rate, and outliers");
console.log("- drive: at least 20 repeats per RPM/duration/surface/load; report spread, not commanded distance");
console.log("- ultrasonic: broad, narrow, soft, angled, and no-target cases; missed obstacles fail safety use");
console.log("- no sensor earns global-localization authority from this harness; visual re-anchoring remains required");
