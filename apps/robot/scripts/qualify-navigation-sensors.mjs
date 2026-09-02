#!/usr/bin/env node
// Interactive recorder for step19_navigation_sensor_qualification.py. Board telemetry and the
// person's tape/protractor measurements land in one JSONL file, correlated by trial id.

import { appendFileSync, mkdirSync } from "node:fs";
import net from "node:net";
import path from "node:path";
import readline from "node:readline/promises";
import { stdin as input, stdout as output } from "node:process";

const host = process.argv[2];
const port = process.argv[3] ? Number(process.argv[3]) : 8770;
const logFile =
  process.argv[4] ??
  path.join(
    "local-data",
    "robot-navigation-qualification",
    `${new Date().toISOString().replace(/[:.]/g, "-")}.jsonl`,
  );

if (!host || !Number.isInteger(port) || port < 1 || port > 65535) {
  console.error("usage: node apps/robot/scripts/qualify-navigation-sensors.mjs <board-ip> [port] [logfile]");
  process.exit(1);
}

mkdirSync(path.dirname(logFile), { recursive: true });
const rl = readline.createInterface({ input, output });
const socket = net.createConnection({ host, port });
socket.setEncoding("utf8");

let buffer = "";
let activeTrial = null;
let trialNumber = 0;
let connected = false;
const waiters = [];

function record(value) {
  appendFileSync(logFile, JSON.stringify({ host_at: new Date().toISOString(), ...value }) + "\n");
}

function send(value) {
  socket.write(JSON.stringify(value) + "\n");
}

function waitFor(predicate, timeoutMs = 3000) {
  return new Promise((resolve, reject) => {
    const waiter = { predicate, resolve, reject };
    waiters.push(waiter);
    const timer = setTimeout(() => {
      const index = waiters.indexOf(waiter);
      if (index >= 0) waiters.splice(index, 1);
      reject(new Error("timed out waiting for the board"));
    }, timeoutMs);
    waiter.timer = timer;
  });
}

function receive(message) {
  record({ source: "board", trial: activeTrial?.id ?? null, ...message });
  for (let index = waiters.length - 1; index >= 0; index -= 1) {
    const waiter = waiters[index];
    if (!waiter.predicate(message)) continue;
    waiters.splice(index, 1);
    clearTimeout(waiter.timer);
    waiter.resolve(message);
  }
}

socket.on("data", (chunk) => {
  buffer += chunk;
  const lines = buffer.split("\n");
  buffer = lines.pop();
  for (const line of lines) {
    if (!line.trim()) continue;
    try {
      receive(JSON.parse(line));
    } catch {
      record({ source: "board", unparseable: line });
    }
  }
});

socket.on("error", (error) => {
  console.error(`board connection failed: ${error.message}`);
  process.exitCode = 1;
  rl.close();
});

socket.on("close", () => {
  if (connected) console.log("board disconnected");
  rl.close();
});

await new Promise((resolve, reject) => {
  socket.once("connect", resolve);
  socket.once("error", reject);
});
connected = true;
const helloReply = waitFor((message) => message.event === "hello");
send({ type: "hello" });
const hello = await helloReply;
console.log(`connected to ${hello.service}; ultrasonic=${hello.has_ultrasonic}`);
console.log(`logging raw readings and ground truth to ${logFile}`);

async function answerNumber(prompt, { min = -Infinity, max = Infinity } = {}) {
  while (true) {
    const answer = Number(await rl.question(prompt));
    if (Number.isFinite(answer) && answer >= min && answer <= max) return answer;
    console.log(`enter a number from ${min} to ${max}`);
  }
}

function beginTrial(kind, details = {}) {
  trialNumber += 1;
  activeTrial = { id: `trial-${trialNumber}`, kind, ...details };
  record({ source: "host", event: "trial_start", ...activeTrial });
  return activeTrial;
}

function finishTrial(groundTruth = {}) {
  record({
    source: "host",
    event: "trial_end",
    trial: activeTrial.id,
    kind: activeTrial.kind,
    ...groundTruth,
  });
  activeTrial = null;
}

async function stationaryTrial() {
  const seconds = await answerNumber("Seconds to leave Rocky completely still [10-600]: ", {
    min: 10,
    max: 600,
  });
  const trial = beginTrial("stationary_yaw", { seconds });
  console.log(`Do not touch Rocky for ${seconds}s...`);
  const startMark = waitFor(
    (message) => message.event === "mark" && message.id === trial.id && message.label === "stationary_start",
  );
  send({ type: "mark", id: trial.id, label: "stationary_start" });
  await startMark;
  await new Promise((resolve) => setTimeout(resolve, seconds * 1000));
  const endMark = waitFor(
    (message) => message.event === "mark" && message.id === trial.id && message.label === "stationary_end",
  );
  send({ type: "mark", id: trial.id, label: "stationary_end" });
  await endMark;
  finishTrial();
}

async function ultrasonicTrial() {
  const actualCm = await answerNumber("Tape-measured target distance in cm [5-300]: ", {
    min: 5,
    max: 300,
  });
  const target = (await rl.question("Target description (wall, chair leg, fabric, angled box...): ")).trim();
  const trial = beginTrial("ultrasonic", { actual_cm: actualCm, target });
  const startMark = waitFor(
    (message) => message.event === "mark" && message.id === trial.id && message.label === "ultrasonic_start",
  );
  send({ type: "mark", id: trial.id, label: "ultrasonic_start" });
  await startMark;
  console.log("Holding still for 3s of readings...");
  await new Promise((resolve) => setTimeout(resolve, 3000));
  const endMark = waitFor(
    (message) => message.event === "mark" && message.id === trial.id && message.label === "ultrasonic_end",
  );
  send({ type: "mark", id: trial.id, label: "ultrasonic_end" });
  await endMark;
  finishTrial({ actual_cm: actualCm, target });
}

async function motionTrial(kind) {
  const rpm = await answerNumber("RPM [10-60]: ", { min: 10, max: 60 });
  const durationMs = await answerNumber("Pulse duration ms [50-500]: ", { min: 50, max: 500 });
  const directionAnswer = (await rl.question(kind === "drive" ? "Forward or backward? [f/b]: " : "Left or right? [l/r]: ")).trim().toLowerCase();
  const direction = directionAnswer === "b" || directionAnswer === "l" ? -1 : 1;
  const trial = beginTrial(kind, { rpm, duration_ms: durationMs, direction });
  await rl.question("Clear the area, place a tape/protractor reference, then press Enter to pulse. ");
  const motionResult = waitFor(
    (message) =>
      message.id === trial.id && ["motion_end", "refused"].includes(message.event),
    3000,
  );
  send({ type: "motion", id: trial.id, kind, rpm, duration_ms: durationMs, direction });
  const result = await motionResult;
  if (result.event === "refused") {
    console.log(`Board refused motion: ${result.reason}`);
    finishTrial({ refused: result.reason });
    return;
  }
  console.log(`Pulse ended: ${result.reason}; board yaw delta will be computed by the analyzer.`);
  const field = kind === "drive" ? "actual displacement in cm (signed): " : "actual turn in degrees (signed): ";
  const actual = await answerNumber(field, { min: -1000, max: 1000 });
  finishTrial(kind === "drive" ? { actual_cm: actual } : { actual_degrees: actual });
}

try {
  while (true) {
    console.log("\n1 stationary yaw drift  2 ultrasonic  3 drive pulse  4 spin pulse  q quit");
    const choice = (await rl.question("> ")).trim().toLowerCase();
    if (choice === "1") await stationaryTrial();
    else if (choice === "2") await ultrasonicTrial();
    else if (choice === "3") await motionTrial("drive");
    else if (choice === "4") await motionTrial("spin");
    else if (choice === "q") break;
  }
} finally {
  if (!socket.destroyed) send({ type: "stop", id: "host-exit" });
  socket.end();
  rl.close();
}

console.log(`saved ${logFile}`);
console.log(`analyze with: pnpm robot:qualify:analyze ${logFile}`);
