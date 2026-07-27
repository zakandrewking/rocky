"""Step 6 - what does the MicroPython runtime underneath CyberOS actually give us?

Two separate questions, both decisive.

**Sockets.** The cyberpi namespace has no HTTP client at all - no get, no post,
no socket. If Rocky is going to talk to its own backend, the capability has to
come from the MicroPython runtime below: `socket`, `ssl`, or `urequests`. If
none of those import, the only remaining network path is Makeblock's cloud
service, and Stage 1 becomes a very different, much worse project.

**machine.I2S.** This is the native way to push arbitrary PCM at a codec. If it
exists and is not locked down, raw playback is possible even though the cyberpi
API refuses it - and that would flip the gate to "yes" on its own.

EXPECTED
  - socket or usocket importable (Wi-Fi works, so something must be there)
  - urequests possibly present
  - machine present but I2S likely absent or unusable from CyberOS

WHAT WOULD CHANGE EVERYTHING
  - machine.I2S available: raw speaker output is on the table, go look at
    whether it can be opened without fighting CyberOS for the peripheral
"""

import cyberpi

CANDIDATES = (
    "socket",
    "usocket",
    "ssl",
    "ussl",
    "urequests",
    "requests",
    "network",
    "machine",
    "esp32",
    "uasyncio",
    "_thread",
    "ubinascii",
    "uhashlib",
)

cyberpi.console.clear()
cyberpi.console.println("Rocky step 6: modules")
print("Rocky step 6: importable modules")
print("")

available = []
for name in CANDIDATES:
    try:
        module = __import__(name)
        members = sorted([m for m in dir(module) if not m.startswith("_")])
        available.append(name)
        print("OK   " + name + " (" + str(len(members)) + " members)")
        print("       " + ", ".join(members[:20]) + ("..." if len(members) > 20 else ""))
    except Exception as exc:
        print("MISS " + name + ": " + type(exc).__name__)

print("")
print("available: " + ", ".join(available))
cyberpi.console.println(str(len(available)) + "/" + str(len(CANDIDATES)) + " modules")

# --- the socket verdict ----------------------------------------------------
has_socket = "socket" in available or "usocket" in available
has_tls = "ssl" in available or "ussl" in available
print("")
print("sockets: " + ("yes" if has_socket else "NO - cannot reach Rocky's backend"))
print("TLS:     " + ("yes" if has_tls else "NO - plaintext only"))
cyberpi.console.println("sockets: " + ("yes" if has_socket else "NO"))

# --- the raw playback verdict ---------------------------------------------
print("")
try:
    import machine

    has_i2s = hasattr(machine, "I2S")
    has_dac = hasattr(machine, "DAC")
    print("machine.I2S: " + ("*** AVAILABLE - raw playback may be possible" if has_i2s else "missing"))
    print("machine.DAC: " + ("*** AVAILABLE" if has_dac else "missing"))
    if has_i2s or has_dac:
        cyberpi.console.println("I2S/DAC present!")
    else:
        cyberpi.console.println("no I2S/DAC (expected)")
except Exception as exc:
    print("machine module unavailable: " + str(exc))
    cyberpi.console.println("no machine module")

print("")
print("Record the module list in apps/cyberpi/STEPS.md")
