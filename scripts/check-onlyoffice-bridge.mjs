import { readFile } from "node:fs/promises";

const root = new URL("../", import.meta.url);
const config = JSON.parse(await readFile(new URL("local-data/onlyoffice-bridge.json", root), "utf8"));
let response;
try {
  response = await fetch(`http://127.0.0.1:${config.port}/status?token=${encodeURIComponent(config.token)}`);
} catch (error) {
  const code = error?.cause?.code;
  if (code === "ECONNREFUSED") {
    console.log("Rocky bridge is not running. Start the app, then retry.");
    process.exit(1);
  }
  if (code === "EPERM") {
    console.log("Loopback access was blocked by the current sandbox. Run this outside the sandbox.");
    process.exit(1);
  }
  throw error;
}
if (!response.ok) throw new Error(`Rocky bridge status failed (${response.status}).`);
const status = await response.json();
console.log(status.connected ? "ONLYOFFICE Rocky plugin connected." : "ONLYOFFICE Rocky plugin not connected.");
if (typeof status.msSinceLastPoll === "number") {
  console.log(`Last plugin poll: ${Math.round(status.msSinceLastPoll)}ms ago.`);
} else {
  console.log("Last plugin poll: never.");
}
console.log(`Queued commands: ${status.queued ?? 0}. Pending confirmations: ${status.pending ?? 0}.`);
if (!status.connected) process.exitCode = 1;
