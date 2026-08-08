# Permissive stubs for MicroPython-only modules

These `.pyi` files exist so Pyright/BasedPyright (Zed, VS Code, `uv run basedpyright`) stop
reporting false errors on `apps/cyberpi/steps/`, `apps/robot/device/`, and `apps/robot/steps/`,
which only ever run as MicroPython on a real CyberPi, never as CPython.

**Why permissive (`__getattr__` -> `Any`) instead of real, precise stubs**: this project's own
research (`apps/cyberpi/docs/cyberos-api-surface.md`, `apps/robot/docs/mbuild-api-surface.md`)
found that every published description of these modules — Makeblock's own `makeblock` PyPI
package included — is an incomplete subset of what the real firmware exposes. A precise stub
built from that same incomplete source would reintroduce the exact mistake those docs are about:
flagging `cyberpi.mic_o` or `cyberpi.display` as errors because a generated package didn't happen
to document them. Permissive stubs say "this module is real, its shape is unknown" — true — rather
than "this module's shape is exactly this list" — false, on the evidence already gathered.

`gc.pyi` and `time.pyi` are the two exceptions: they shadow real standard-library modules
project-wide (Pyright's `stubPath` doesn't support scoping an override to only some directories)
because the device scripts use MicroPython-only extensions (`gc.mem_free()`, `time.ticks_ms()`,
`time.ticks_diff()`) that don't exist in CPython's real `time`/`gc`. The tradeoff: `services/
voice-clone`'s real CPython `time`/`gc` usage loses precise stdlib type checking too. Given how
little either module is used there, that's a fine trade for not hand-editing a dozen
already-hardware-verified step files with per-line suppression comments. Revisit if it ever costs
something real.
