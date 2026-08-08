#!/usr/bin/env node
// Sends a payload file to a running apps/robot/device/bootstrap.py over the network.
// Usage: node apps/robot/scripts/push.mjs <host> <payload-file> [port]
//
// A plain shell nc one-liner kept exiting before reading the board's reply (BSD nc's default
// behavior on stdin EOF, worked around badly during STEPS.md's socket-gate testing) -- this
// avoids that class of bug entirely by controlling both write-then-half-close and the read
// timeout directly.

import { readFileSync } from "node:fs";
import net from "node:net";

const [, , host, payloadFile, portArg] = process.argv;

if (!host || !payloadFile) {
  console.error("usage: node apps/robot/scripts/push.mjs <host> <payload-file> [port]");
  process.exit(1);
}

const port = portArg ? Number(portArg) : 8766;
const code = readFileSync(payloadFile);

const socket = net.createConnection({ host, port }, () => {
  socket.end(code); // half-close after writing, so bootstrap.py's recv loop sees EOF and stops
});

let reply = "";
socket.setTimeout(5000);
socket.on("data", (chunk) => {
  reply += chunk.toString("utf8");
});
socket.on("end", () => {
  process.stdout.write(reply || "(board closed without replying)\n");
});
socket.on("timeout", () => {
  console.error("timed out waiting for the board's reply");
  socket.destroy();
  process.exit(1);
});
socket.on("error", (error) => {
  console.error("push failed:", error.message);
  process.exit(1);
});
