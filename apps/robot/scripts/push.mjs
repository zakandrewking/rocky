#!/usr/bin/env node
// Sends a payload file to a running apps/robot/device/bootstrap.py over the network.
// Usage: node apps/robot/scripts/push.mjs <host> <payload-file> [port]
//
// Node's TCP stack has intermittently reported EHOSTUNREACH for a reachable CyberPi on macOS
// while the native nc client connects immediately. Keep Node as the normal, portable path and
// retry those local-route failures through nc. This is deliberately a fallback, not a probe: the
// board receives the payload at most once.

import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import net from "node:net";

const [, , host, payloadFile, portArg] = process.argv;

if (!host || !payloadFile) {
  console.error("usage: node apps/robot/scripts/push.mjs <host> <payload-file> [port]");
  process.exit(1);
}

const port = portArg ? Number(portArg) : 8766;
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  console.error(`invalid port: ${portArg}`);
  process.exit(1);
}

const code = readFileSync(payloadFile);
const nativeFallbackErrors = new Set(["EADDRNOTAVAIL", "EHOSTUNREACH", "ENETUNREACH"]);

function pushWithNode() {
  return new Promise((resolve, reject) => {
    let reply = "";
    let connected = false;
    const socket = net.createConnection({ host, port }, () => {
      connected = true;
      socket.end(code); // half-close so bootstrap.py's recv loop sees EOF and stops
    });

    socket.setTimeout(5000);
    socket.on("data", (chunk) => {
      reply += chunk.toString("utf8");
    });
    socket.on("end", () => resolve(reply));
    socket.on("timeout", () => {
      const error = new Error("timed out waiting for the board's reply");
      error.code = "ETIMEDOUT";
      socket.destroy(error);
    });
    socket.on("error", (error) => {
      error.connected = connected;
      reject(error);
    });
  });
}

function pushWithNativeClient() {
  return new Promise((resolve, reject) => {
    const child = spawn("nc", ["-w", "12", host, String(port)], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let reply = "";
    let stderr = "";

    child.stdout.on("data", (chunk) => {
      reply += chunk.toString("utf8");
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString("utf8");
    });
    child.on("error", reject);
    child.on("close", (exitCode) => {
      if (exitCode === 0) {
        resolve(reply);
        return;
      }
      reject(new Error(stderr.trim() || `nc exited with status ${exitCode}`));
    });
    child.stdin.on("error", reject);
    child.stdin.end(code);
  });
}

function printReply(reply) {
  process.stdout.write(reply || "(board closed without replying)\n");
}

try {
  printReply(await pushWithNode());
} catch (error) {
  // Never retry after connecting: the board might already have received a partial/full payload.
  if (error.connected || !nativeFallbackErrors.has(error.code)) {
    console.error("push failed:", error.message);
    process.exit(1);
  }

  console.warn(`Node TCP reported ${error.code}; retrying with the native TCP client...`);
  try {
    printReply(await pushWithNativeClient());
  } catch (fallbackError) {
    console.error(`push failed: ${error.message}; native fallback: ${fallbackError.message}`);
    process.exit(1);
  }
}
