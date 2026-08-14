#!/usr/bin/env node
// Rescue push: hammers bootstrap.py's OTA port with retries from the moment the board powers on,
// to replace a payload whose *boot path* wedges the board (2026-08-13/14 incident: a payload
// calling network.WLAN() at boot hung the interpreter and dropped the board off the network on
// every power cycle -- a normal one-shot push.mjs can't land because the board dies seconds
// after boot).
//
// Why this can win: bootstrap.py's loop runs check_for_push() BEFORE each payload tick, and the
// bad boot path only runs inside the first tick. A connection already waiting in the listen
// backlog when the loop starts gets the new payload written and exec'd first, so the bad code
// never runs. The window is small (Wi-Fi join -> first tick), hence the fast retry loop.
//
// Usage: node apps/robot/scripts/rescue.mjs <host> <payload-file> [port]
//        start it FIRST, then power the board on.

import { readFileSync } from "node:fs";
import net from "node:net";

const [, , host, payloadFile, portArg] = process.argv;

if (!host || !payloadFile) {
  console.error("usage: node apps/robot/scripts/rescue.mjs <host> <payload-file> [port]");
  process.exit(1);
}

const port = portArg ? Number(portArg) : 8766;
const code = readFileSync(payloadFile);
const startedAt = Date.now();
const GIVE_UP_MS = 5 * 60 * 1000;
const RETRY_MS = 150;

let attempt = 0;

function tryPush() {
  attempt += 1;
  if (Date.now() - startedAt > GIVE_UP_MS) {
    console.error(`giving up after ${attempt} attempts / 5 minutes`);
    process.exit(1);
  }

  const socket = net.createConnection({ host, port }, () => {
    socket.end(code); // half-close so bootstrap's recv loop sees EOF, same as push.mjs
  });
  // Short timeout on purpose: a SYN that isn't answered promptly means the board isn't up yet
  // (or its loop is already hung and lwIP is just queuing the handshake) -- move on and retry.
  socket.setTimeout(2000);

  let reply = "";
  socket.on("data", (chunk) => {
    reply += chunk.toString("utf8");
  });
  socket.on("end", () => {
    if (reply.includes("ok")) {
      console.log(`\nSUCCESS on attempt ${attempt}: ${reply.trim()}`);
      process.exit(0);
    }
    retry(`board replied without ok: ${reply.trim() || "(empty)"}`);
  });
  socket.on("timeout", () => {
    socket.destroy();
    retry("timeout");
  });
  socket.on("error", (error) => {
    retry(error.code ?? error.message);
  });
}

function retry(why) {
  if (attempt % 20 === 0) {
    process.stdout.write(`\rattempt ${attempt} (${why})            `);
  }
  setTimeout(tryPush, RETRY_MS);
}

console.log(`hammering ${host}:${port} with ${payloadFile} -- power the board on now`);
tryPush();
