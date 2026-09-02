#!/usr/bin/env node
// Proves the device payloads actually *execute* their module level, not just that they parse.
//
// `python3 -m py_compile` only checks syntax. It says nothing about a name being read before it is
// defined, which is precisely the mistake that just got made: a constant used inside the `_state`
// dict literal thirty lines before its assignment. That is a module-level NameError, and on this
// hardware the consequences are the bad kind -- bootstrap.py `exec()`s the payload the instant it
// arrives, so the board would have accepted the push, died on the first line, and then sat there
// running nothing, with the only symptom being "the robot stopped working" after a deploy.
//
// This project's own hard-won rule (AGENTS.md) is that on a single-threaded embedded device, the
// code path that would recover from a mistake and the code path the mistake is in are often the
// same one. A five-second check on the laptop is worth a great deal more than the same discovery
// made on the board.
//
// It runs the payload under stub versions of every device module, so nothing touches hardware and
// nothing blocks. Only module-level code runs: `tick()` is never called.

import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

// Payloads only. bootstrap.py is deliberately excluded: it *is* the program, so its module level
// runs the main loop forever and never returns -- which is correct for it and fatal for a payload.
// That difference is the other half of what this checks.
const PAYLOADS = [
  "../device/rocky_agent.py",
  "../steps/step19_navigation_sensor_qualification.py",
];

// A payload whose module level never returns is exactly as dead as one that raises: bootstrap
// exec()s it and then never gets to call tick(). So a hang is a failure here, not a hang.
const TIMEOUT_MS = 10000;

// Every module the board provides and a laptop does not. `_Any` answers to anything, so the stub
// never has to keep up with the real API surface -- it only has to let module level finish.
const HARNESS = `
import sys, types

class _Any:
    def __init__(self, *a, **k): pass
    def __call__(self, *a, **k): return _Any()
    def __getattr__(self, name): return _Any()
    def __getitem__(self, key): return _Any()
    def __iter__(self): return iter(())
    def __int__(self): return 0
    def __float__(self): return 0.0
    def __bool__(self): return False

def _stub(name, **attrs):
    module = types.ModuleType(name)
    module.__getattr__ = lambda _n: _Any()
    for key, value in attrs.items():
        setattr(module, key, value)
    sys.modules[name] = module
    return module

_stub("cyberpi")
_stub("mbot2")
_stub("mbuild", ultrasonic2=_Any(), quad_rgb_sensor=_Any())
# Real enough to be worth using: ticks arithmetic runs at module level in places, and a stub that
# returned _Any() for these would hide a genuine type error rather than catch one.
_stub(
    "utime",
    ticks_ms=lambda: 0,
    ticks_diff=lambda a, b: 0,
    ticks_add=lambda a, b: a + b,
    sleep_ms=lambda ms: None,
)
import json as _json
_stub("ujson", dumps=_json.dumps, loads=_json.loads)
import socket as _socket
sys.modules["usocket"] = _socket

source = open(sys.argv[1]).read()
namespace = {"__name__": "__payload__"}
exec(compile(source, sys.argv[1], "exec"), namespace)
print("  module level ran clean:", sys.argv[1].split("/")[-1])
`;

let failed = false;
for (const payload of PAYLOADS) {
  const path = fileURLToPath(new URL(payload, import.meta.url));
  const result = spawnSync("python3", ["-c", HARNESS, path], { encoding: "utf8", timeout: TIMEOUT_MS });
  if (result.error?.code === "ETIMEDOUT" || result.signal) {
    failed = true;
    console.error(
      `\n${payload} never finished its module level (${TIMEOUT_MS}ms).\n` +
        "A payload must define things and return; bootstrap.py is what owns the loop.",
    );
  } else if (result.status !== 0) {
    failed = true;
    console.error(`\n${payload} failed to execute its module level:\n${result.stderr}`);
  } else {
    process.stdout.write(result.stdout);
  }
}

if (failed) {
  console.error(
    "A payload that raises at module level is accepted by the push and then runs nothing at all.\n" +
      "The board will look alive (bootstrap keeps its listener) while doing absolutely nothing.",
  );
  process.exit(1);
}
console.log("payload imports ok");
