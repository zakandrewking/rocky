#!/usr/bin/env node
// Fails if apps/robot/device/rocky_agent.py's tuned constants have drifted from
// apps/robot/steps/step16_loudness_drive_sticky.py, which is the tuning record.
//
// Those numbers took eleven versions and a live calibration run to arrive at, and several of them
// are load-bearing in ways that are not obvious from reading them (the CURVE floor anchor is
// about sensor jitter, not voice; SELF_NOISE's 60 RPM ceiling is what stops the v3 feedback loop
// coming back). Nothing about adding collaboration should change any of them, so this makes an
// accidental edit a build failure rather than something noticed weeks later by feel.

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const REFERENCE = new URL("../steps/step16_loudness_drive_sticky.py", import.meta.url);
const LIVE = new URL("../device/rocky_agent.py", import.meta.url);

/** Every constant that came out of calibration or live tuning. */
const TUNED = [
  "CURVE",
  "SELF_NOISE",
  "SETTLE_MS",
  "SUSTAIN_MIN_MS",
  "SUSTAIN_MAX_MS",
  "DRIVE_TIMEOUT_MS",
  "TURN_RPM",
  "TURN_MS",
  "OBSTACLE_TURN_MS",
  "STARTLE_CUTOFF",
  "STARTLE_JUMP_THRESHOLD",
  "BASELINE_ALPHA",
  "JUMP_RPM",
  "JUMP_MS",
  "FLEE_RPM",
  "SENSOR_MAX",
  "FLEE_MS_MIN",
  "FLEE_MS_MAX",
  "WOBBLE_RPM",
  "DIZZY_RPM",
  "DIZZY_MS",
  "MAX_RPM",
  "MIN_RPM",
  "MIN_LEVEL",
  "OBSTACLE_STOP_CM",
  "BUMP_THRESHOLD",
  "REFLECT_BASELINE_ALPHA",
  "APPROACH_CM",
  "FLOOR_SEED_SAMPLES",
  "FLOOR_SEED_INTERVAL_MS",
];

/** The assignment's right-hand side, up to the end of that logical line. */
function readConstant(source, name) {
  const match = source.match(new RegExp(`^${name}\\s*=\\s*(.+)$`, "m"));
  return match ? match[1].split("#")[0].trim() : null;
}

const [reference, live] = await Promise.all([
  readFile(fileURLToPath(REFERENCE), "utf8"),
  readFile(fileURLToPath(LIVE), "utf8"),
]);

const drifted = [];
for (const name of TUNED) {
  const expected = readConstant(reference, name);
  const actual = readConstant(live, name);
  if (expected === null) drifted.push(`${name}: missing from step16 (the reference)`);
  else if (actual === null) drifted.push(`${name}: missing from rocky_agent.py`);
  else if (expected !== actual) drifted.push(`${name}: step16 has ${expected}, live has ${actual}`);
}

// RECOVER_SCHEDULE is multi-line, so compare it as a block rather than a single assignment.
const scheduleOf = (source) => source.match(/RECOVER_SCHEDULE = \(([\s\S]*?)\n\)/)?.[1] ?? null;
if (scheduleOf(reference) !== scheduleOf(live)) drifted.push("RECOVER_SCHEDULE: differs");

// The vocabulary the character is offered has to be the vocabulary the board actually answers to.
// If these drift, Rocky asks confidently for a gesture the robot has never heard of and simply
// gets silence -- a failure with no error anywhere, on either side.
const SESSION = new URL("../../../services/device-api/src/session.ts", import.meta.url);
const session = await readFile(fileURLToPath(SESSION), "utf8");

/** A python tuple of string literals, e.g. GESTURES = ("spin", "wiggle") */
function pythonNames(source, name) {
  const body = source.match(new RegExp(`^${name}\\s*=\\s*\\(([^)]*)\\)`, "m"))?.[1];
  return body ? [...body.matchAll(/"([^"]+)"/g)].map((m) => m[1]).sort() : null;
}
/** The keys of a python dict literal, e.g. MOODS = { "calm": {...}, ... } */
function pythonKeys(source, name) {
  const start = source.indexOf(`${name} = {`);
  if (start < 0) return null;
  const body = source.slice(start, source.indexOf("\n}", start));
  return [...body.matchAll(/^\s{4}"([^"]+)":/gm)].map((m) => m[1]).sort();
}
/** A TypeScript const tuple of string literals. */
function typescriptNames(source, name) {
  const body = source.match(new RegExp(`const ${name} = \\[([\\s\\S]*?)\\] as const;`))?.[1];
  return body ? [...body.matchAll(/"([^"]+)"/g)].map((m) => m[1]).sort() : null;
}
/** The enum on a tool parameter, e.g. enum: ["spin", "wiggle"] */
function toolEnum(source, property) {
  const body = source.match(new RegExp(`${property}: \\{ type: "string", enum: \\[([^\\]]*)\\]`))?.[1];
  return body ? [...body.matchAll(/"([^"]+)"/g)].map((m) => m[1]).sort() : null;
}
/** The enum on an array property's items, e.g. moves: { type: "array", items: { ... } } */
function toolArrayItemEnum(source, property) {
  const start = source.indexOf(`${property}: {`);
  if (start < 0) return null;
  const body = source.slice(start, source.indexOf("required:", start));
  const items = body.match(/items: \{ type: "string", enum: \[([^\]]*)\]/)?.[1];
  return items ? [...items.matchAll(/"([^"]+)"/g)].map((m) => m[1]).sort() : null;
}

for (const [label, onBoard, offered] of [
  ["gestures", pythonNames(live, "GESTURES"), toolEnum(session, "gesture")],
  ["routine moves", pythonNames(live, "GESTURES"), toolArrayItemEnum(session, "moves")],
  ["moods", pythonKeys(live, "MOODS"), toolEnum(session, "mood")],
  ["light colors", pythonKeys(live, "LIGHT_COLORS"), typescriptNames(session, "LIGHT_COLORS")],
]) {
  if (!onBoard || !offered) drifted.push(`${label}: could not be read from both sides`);
  else if (onBoard.join(",") !== offered.join(",")) {
    drifted.push(`${label}: board answers to [${onBoard}], the character is offered [${offered}]`);
  }
}

if (drifted.length) {
  console.error("Behaviour tuning has drifted from step16:\n  " + drifted.join("\n  "));
  console.error(
    "\nIf the change is deliberate, update step16 too -- it is the tuning record, and a value\n" +
      "that only exists in one of them is a value nobody can trace the reasoning for.",
  );
  process.exit(1);
}

console.log(`behaviour parity ok (${TUNED.length} tuned constants + RECOVER_SCHEDULE match step16)`);
