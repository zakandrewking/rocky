#!/usr/bin/env node
// Receives newline-JSON telemetry from a payload running on the CyberPi and logs it to a JSONL
// file. This is the "real numbers land on the laptop" piece from
// docs/loudness-drive-problem-statement.md -- every loudness experiment before this read samples
// character-by-character off the 128x128 screen, which never scaled past a couple of data points.
//
// Usage: node apps/robot/scripts/telemetry.mjs [port] [logfile]
//   port    defaults to 8767 (the board's push listener is 8766; this is the laptop side)
//   logfile defaults to local-data/robot-telemetry/<timestamp>.jsonl (gitignored)
//
// Leave it running across board reconnects -- each payload push drops and reopens the socket, and
// this keeps appending to the same log. Ctrl-C to stop; it prints the log path for the analysis
// step (scripts/analyze-calibration.mjs).

import { appendFileSync, mkdirSync } from "node:fs";
import net from "node:net";
import path from "node:path";

const port = process.argv[2] ? Number(process.argv[2]) : 8767;
const logFile =
  process.argv[3] ??
  path.join(
    "local-data",
    "robot-telemetry",
    `${new Date().toISOString().replace(/[:.]/g, "-")}.jsonl`,
  );

mkdirSync(path.dirname(logFile), { recursive: true });

let sampleCount = 0;
let lastPhase = null;

function handleLine(line) {
  const trimmed = line.trim();
  if (!trimmed) return;
  appendFileSync(logFile, trimmed + "\n");

  let record;
  try {
    record = JSON.parse(trimmed);
  } catch {
    console.log(`  (unparseable) ${trimmed}`);
    return;
  }

  if (record.phase && record.phase !== lastPhase) {
    lastPhase = record.phase;
    console.log(`\n== phase: ${record.phase} ==`);
  }
  sampleCount += 1;
  console.log(`  ${trimmed}`);
}

const server = net.createServer((socket) => {
  console.log(`board connected from ${socket.remoteAddress}`);
  let buffer = "";
  socket.on("data", (chunk) => {
    buffer += chunk.toString("utf8");
    const lines = buffer.split("\n");
    buffer = lines.pop(); // keep any trailing partial line
    for (const line of lines) handleLine(line);
  });
  socket.on("close", () => {
    if (buffer) handleLine(buffer);
    buffer = "";
    console.log(`board disconnected (${sampleCount} samples logged so far)`);
  });
  socket.on("error", (error) => console.error("socket error:", error.message));
});

server.listen(port, "0.0.0.0", () => {
  console.log(`telemetry listener on :${port}`);
  console.log(`logging to ${logFile}`);
});

process.on("SIGINT", () => {
  console.log(`\n${sampleCount} samples logged to ${logFile}`);
  console.log(`next: node apps/robot/scripts/analyze-calibration.mjs ${logFile}`);
  process.exit(0);
});
