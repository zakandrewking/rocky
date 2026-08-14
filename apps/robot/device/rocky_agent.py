# Rocky's thin robot-body agent for stock CyberOS (mBot2 + CyberPi).
#
# A bootstrap.py PAYLOAD, not a standalone program: push it with
#   node apps/robot/scripts/push.mjs <board-ip> apps/robot/device/rocky_agent.py
# bootstrap.py must already be running on the board (uploaded once via mBlock, see its own
# header) -- it owns Wi-Fi and the push listener, and calls this file's tick() once per loop
# iteration forever. This file must never block for more than about one DRIVE_BURST_MS chunk
# inside a single tick() call, or bootstrap's own push-listener and this file's own heartbeat
# watchdog both stop being checked for that long. See docs/mbuild-api-surface.md for why
# mbot2.straight()/turn() (which block until the maneuver finishes) are avoided in favor of
# mbot2.drive_speed(), driven here in short interruptible bursts instead.
#
# Wire protocol: newline-delimited JSON over a plain TCP socket, matching apps/robot/src/protocol.ts
# on the client side (laptop or iOS) -- same protocol either way, this file doesn't know which
# kind of client connected.
#
# Only one drive/turn may be in flight at a time -- a second one while busy gets an immediate
# "busy" error rather than being queued, which keeps the tick()-driven state machine below simple.
# `stop` always wins: it cancels an in-progress action on the very next tick, from any client.

import cyberpi
import mbot2
import ujson
import utime

# Deliberately NO `import network` -- see the block comment above _boot(): touching the standard
# `network` module on this firmware is the prime suspect for the 2026-08-13/14 board freezes.

try:
    import usocket as socket
except ImportError:
    import socket

# mbuild accessory sensors, weaker evidence tier -- see docs/mbuild-api-surface.md. Wrapped in
# try/except everywhere they're used, since it's unconfirmed these import cleanly, and a base
# mBot2 kit may not have every accessory attached.
try:
    from mbuild import ultrasonic2, quad_rgb_sensor

    HAS_ULTRASONIC = True
except ImportError:
    HAS_ULTRASONIC = False

TCP_PORT = 8765

# Discovery beacon: a plain UDP broadcast rather than real mDNS/Bonjour -- Bonjour would need a
# hand-rolled DNS-SD responder here (probing/announcing state machine, record encoding) and a
# multicast entitlement on the iOS side (Apple has to grant it), whereas a broadcast needs
# neither. RobotDiscovery.swift listens for this; apps/ios/README.md has the client side.
DISCOVERY_PORT = 41900
DISCOVERY_INTERVAL_MS = 1000

# Heartbeat: a connected client sends {"type":"heartbeat"} on an interval (see robot.ts /
# RobotProtocol.swift). If none arrives within this window, stop the motors and wait for a fresh
# connection. This is what keeps a dropped Wi-Fi link from leaving the robot driving blind -- the
# whole reason safety lives on the device, not the network.
HEARTBEAT_TIMEOUT_MS = 2000

# Obstacle-avoidance reflex: stop a commanded drive immediately if the ultrasonic sensor reports
# less than this many cm, regardless of what the client asked for. See PLAN.md, "AI goals x mBot2
# Shield obstacle avoidance."
OBSTACLE_STOP_CM = 15

# mbot2.drive_speed(em1, em2) is not time- or distance-boxed (unlike mbot2.straight()/turn(),
# which appear to block until the maneuver finishes -- see docs/mbuild-api-surface.md). Driving in
# short bursts, one per tick(), is what makes the obstacle reflex and the heartbeat watchdog able
# to cut power quickly instead of only between blocking calls -- and what keeps a single tick()
# call bounded instead of looping internally for the whole commanded distance/angle.
DRIVE_BURST_MS = 100

# UNCONFIRMED (apps/robot/STEPS.md step 8): sign convention and left/right mapping for
# mbot2.drive_speed(em1, em2). Flip these if a "forward" command actually drives backward, spins
# in place, or drives the wrong wheel.
DRIVE_RPM_SIGN = (1, -1)  # (em1, em2) multipliers so drive_speed(v, v) drives straight
TURN_RPM_SIGN = (1, 1)  # (em1, em2) multipliers so drive_speed(v, v) turns in place

# UNCONFIRMED (apps/robot/STEPS.md step 9): measured cm and degrees covered per second at
# MAX_RPM. Placeholder numbers; do not trust distances/angles until this is calibrated.
MAX_RPM = 100
CM_PER_SECOND_AT_MAX_RPM = 30.0
DEGREES_PER_SECOND_AT_MAX_RPM = 90.0

_server = None
_conn = None
_buffered = ""
_last_heartbeat = 0
_action = None  # None, or an in-progress drive/turn dict (see _start_drive/_start_turn)
_booted = False
_discovery_sock = None
_last_beacon = 0
_beacon_count = 0


# On-screen status, so watching the board's own display is enough to follow along without
# needing to read the laptop's logs -- four independent label slots (bootstrap.py established
# this "clear once at boot, then update labels by id in place" pattern), plus the face glyph.
def _set_status(text):
    cyberpi.display.show_label(text, 12, 0, 0, 0)


def _set_connection_line(text):
    cyberpi.display.show_label(text, 12, 0, 16, 1)


def _set_command_line(text):
    cyberpi.display.show_label(text, 12, 0, 32, 2)


def _set_result_line(text):
    cyberpi.display.show_label(text, 12, 0, 48, 3)


# THE BOARD CANNOT KNOW ITS OWN IP. Settled by source research (2026-08-14), not just probing:
#
# - socket.getsockname() has NEVER existed in MicroPython's ESP32 port -- verified against the
#   socket object's actual C method table in upstream modsocket.c at v1.12, v1.17, v1.19, and
#   master. Makeblock's firmware is a fork of this. Any getsockname() call raises AttributeError,
#   always. (The earlier "UDP connect then getsockname" attempt here was a CPython idiom that
#   simply doesn't exist on this platform.)
# - network.WLAN(STA_IF).ifconfig() returns "0.0.0.0" on this firmware (proven live, STEPS.md):
#   CyberOS manages Wi-Fi through its own private C layer, so the standard `network` module is
#   decoupled from the real connection. WORSE -- calling network.WLAN(network.STA_IF) from the
#   payload's boot path is the prime suspect for hanging the interpreter and eventually knocking
#   the whole board off the network (2026-08-13/14 incident: board froze after the push that
#   added it, and after *every* subsequent power cycle the board reached "waiting for client"
#   then dropped off the network with no client ever connecting -- the boot-path WLAN call was
#   the only network-touching code that ran). NEVER call into the `network` module in this file.
# - Makeblock's published wifi API is connect() + is_connect() -- nothing else. No IP getter
#   exists, and no community example anywhere reads the board's own IP; every known networking
#   example is outbound-only. This is a platform property, not a missing trick.
#
# Consequence for discovery: the beacon does NOT include the board's IP, and doesn't need to --
# UDP receivers learn the sender's address from the packet itself (recvfrom / NWConnection
# endpoint), which is exactly how RobotDiscovery.swift already reads it.


def _boot():
    global _server, _discovery_sock, _booted
    _server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    _server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    _server.bind(("0.0.0.0", TCP_PORT))
    _server.listen(1)
    _server.settimeout(0)  # non-blocking accept() -- this is a payload, not the owner of the loop

    try:
        _discovery_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        _discovery_sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    except Exception as error:
        # Discovery is a convenience, not a safety-relevant feature -- if UDP broadcast doesn't
        # work on this firmware (unconfirmed, like everything else in this file), fall back to
        # no beacon rather than failing boot; manual IP entry in the app still works either way.
        _discovery_sock = None
        _set_beacon_line("socket failed")
        print("discovery socket failed:", error)

    cyberpi.display.clear()
    _set_status("Rocky motion :{}".format(TCP_PORT))
    _set_connection_line("waiting for client")
    cyberpi.led.on(0, 255, 0, id="all")
    _booted = True


def _set_beacon_line(text):
    cyberpi.display.show_label(text, 10, 0, 96, 5)


def _beacon_discovery():
    """Broadcasts a small 'here I am' UDP packet at most once per DISCOVERY_INTERVAL_MS, so
    RobotDiscovery.swift can find this board without its IP being typed in by hand. The packet
    deliberately carries no IP -- the board cannot know its own (see the block comment above
    _boot()); the receiver reads the sender's address off the packet itself, which is the one
    address that is always correct. Shows a live send counter on screen because the first time
    this ran, nothing arrived on the laptop side and there was no way to tell "not sending"
    from "sending but not received". Limited broadcast (255.255.255.255) only: the subnet-
    directed variant (192.168.1.255-style) needed self-IP knowledge this platform can't give."""
    global _last_beacon, _beacon_count
    if _discovery_sock is None:
        return
    now = utime.ticks_ms()
    if utime.ticks_diff(now, _last_beacon) < DISCOVERY_INTERVAL_MS:
        return
    _last_beacon = now
    message = ujson.dumps({"service": "rocky-robot", "tcpPort": TCP_PORT})
    try:
        _discovery_sock.sendto(message.encode(), ("255.255.255.255", DISCOVERY_PORT))
        _beacon_count += 1
        _set_beacon_line("beacon #{}".format(_beacon_count))
    except Exception as error:
        _set_beacon_line("beacon err: {}".format(str(error)[:16]))


def read_distance_cm():
    if not HAS_ULTRASONIC:
        return -1
    try:
        return ultrasonic2.get_distance()
    except Exception:
        return -1


def read_line_sensors():
    if not HAS_ULTRASONIC:
        return []
    try:
        # get_reflect() doesn't exist on this firmware -- confirmed live on real hardware
        # (2026-08-08, steps/step16_loudness_drive_sticky.py's touch-detection work): dir() has no
        # such method, and get_all_data()'s first 4 elements are the real per-channel readings
        # (get_intensity(1) matched get_all_data()[0] exactly).
        return list(quad_rgb_sensor.get_all_data()[0:2])
    except Exception:
        return []


def stop_motors():
    mbot2.drive_speed(0, 0)


def set_face(face):
    # No cyberpi.display.clear() here -- this used to wipe the status/connection/command/result
    # lines (ids 0-3) every time the face changed, which is often (every connect/disconnect/
    # error). Own a distinct label id (4) instead, so this only ever touches its own line.
    labels = {
        "idle": ". _ .",
        "listening": "o _ o",
        "thinking": ". ~ .",
        "speaking": ". o .",
        "happy": "^ _ ^",
        "error": "x _ x",
    }
    cyberpi.display.show_label(labels.get(face, "?"), 24, 40, 68, 4)


def set_lights(r, g, b):
    cyberpi.led.on(r, g, b, id="all")


def drive_burst(speed_pct, forward):
    """One DRIVE_BURST_MS chunk of driving, aborted early if the ultrasonic reflex trips.
    Returns False if the reflex tripped, True if the burst completed normally."""
    rpm = (speed_pct / 100.0) * MAX_RPM
    if not forward:
        rpm = -rpm
    em1 = rpm * DRIVE_RPM_SIGN[0]
    em2 = rpm * DRIVE_RPM_SIGN[1]
    mbot2.drive_speed(em1, em2)

    start = utime.ticks_ms()
    while utime.ticks_diff(utime.ticks_ms(), start) < DRIVE_BURST_MS:
        distance = read_distance_cm()
        if forward and HAS_ULTRASONIC and 0 <= distance < OBSTACLE_STOP_CM:
            stop_motors()
            return False
        utime.sleep_ms(10)

    stop_motors()
    return True


def turn_burst(speed_pct, clockwise, burst_ms):
    """One burst_ms chunk of turning (no obstacle reflex -- turning in place doesn't translate
    the robot into new space the way driving forward does)."""
    rpm = (speed_pct / 100.0) * MAX_RPM
    if not clockwise:
        rpm = -rpm
    em1 = rpm * TURN_RPM_SIGN[0]
    em2 = rpm * TURN_RPM_SIGN[1]
    mbot2.drive_speed(em1, em2)
    utime.sleep_ms(burst_ms)
    stop_motors()


def _start_drive(distance_cm, speed_pct, command_id, send):
    global _action
    _action = {
        "kind": "drive",
        "forward": distance_cm >= 0,
        "speed": speed_pct,
        "remaining_cm": abs(distance_cm),
        "id": command_id,
        "send": send,
    }


def _start_turn(degrees, speed_pct, command_id, send):
    global _action
    total_ms = abs(degrees) / max(DEGREES_PER_SECOND_AT_MAX_RPM * (speed_pct / 100.0), 1) * 1000.0
    _action = {
        "kind": "turn",
        "clockwise": degrees >= 0,
        "speed": speed_pct,
        "remaining_ms": total_ms,
        "id": command_id,
        "send": send,
    }


def _pump_action():
    """Advances the in-progress drive/turn by exactly one burst, then returns -- tick() gets
    called again by bootstrap.py's own loop for the next burst. This is what keeps a multi-second
    drive/turn from blocking the push-listener the way one long synchronous call would."""
    global _action
    if _action is None:
        return

    if _action["kind"] == "drive":
        ok = drive_burst(_action["speed"], _action["forward"])
        if not ok:
            _action["send"](
                {"type": "error", "id": _action["id"], "ok": False, "message": "obstacle stop"}
            )
            _action = None
            return
        cm_per_burst = (
            CM_PER_SECOND_AT_MAX_RPM * (_action["speed"] / 100.0) * (DRIVE_BURST_MS / 1000.0)
        )
        _action["remaining_cm"] -= cm_per_burst
        if _action["remaining_cm"] <= 0:
            _action["send"]({"type": "ack", "id": _action["id"], "ok": True})
            _action = None

    elif _action["kind"] == "turn":
        chunk_ms = min(DRIVE_BURST_MS, _action["remaining_ms"])
        turn_burst(_action["speed"], _action["clockwise"], int(chunk_ms))
        _action["remaining_ms"] -= chunk_ms
        if _action["remaining_ms"] <= 0:
            _action["send"]({"type": "ack", "id": _action["id"], "ok": True})
            _action = None


def handle_command(command, send):
    global _action
    command_type = command.get("type")
    command_id = command.get("id")

    if command_type == "heartbeat":
        return  # no reply needed, and skip the screen log below -- heartbeats arrive every
        # ~500ms and would just be noise over whatever's actually useful

    _set_command_line("cmd: {}".format(command_type))

    if command_type == "drive":
        if _action is not None:
            send({"type": "error", "id": command_id, "ok": False, "message": "busy"})
            return
        _start_drive(command["distanceCm"], command["speed"], command_id, send)
    elif command_type == "turn":
        if _action is not None:
            send({"type": "error", "id": command_id, "ok": False, "message": "busy"})
            return
        _start_turn(command["degrees"], command["speed"], command_id, send)
    elif command_type == "stop":
        _action = None  # cancel any in-progress drive/turn -- stop always wins
        stop_motors()
        send({"type": "ack", "id": command_id, "ok": True})
    elif command_type == "setFace":
        set_face(command["face"])
        send({"type": "ack", "id": command_id, "ok": True})
    elif command_type == "setLights":
        set_lights(command["r"], command["g"], command["b"])
        send({"type": "ack", "id": command_id, "ok": True})
    elif command_type == "readDistance":
        send({"type": "distance", "id": command_id, "ok": True, "cm": read_distance_cm()})
    elif command_type == "readLineSensors":
        send({"type": "lineSensors", "id": command_id, "ok": True, "values": read_line_sensors()})
    else:
        send({"type": "error", "id": command_id, "ok": False, "message": "unknown command"})


def _log_result(message):
    message_type = message.get("type")
    if message_type == "ack":
        _set_result_line("ok")
    elif message_type == "error":
        _set_result_line("err: {}".format(message.get("message", "?"))[:20])
    elif message_type == "distance":
        _set_result_line("dist: {}cm".format(message.get("cm")))
    elif message_type == "lineSensors":
        _set_result_line("line sensors sent")


def _make_send(connection):
    def send(message):
        _log_result(message)
        try:
            connection.sendall(ujson.dumps(message) + "\n")
        except Exception:
            pass  # the client is gone; the next tick's heartbeat-timeout check cleans this up

    return send


def _pump_network():
    """One non-blocking step of connection/command handling per tick(). Accepts at most one new
    connection, processes at most whatever's already buffered from recv(), and checks the
    heartbeat watchdog -- never waits for any of these."""
    global _conn, _buffered, _last_heartbeat, _action

    if _server is None:
        return  # tick() only calls this after _boot() has run

    if _conn is None:
        try:
            connection, addr = _server.accept()
        except OSError:
            return  # nothing pending this tick
        connection.settimeout(0)
        _conn = connection
        _buffered = ""
        _last_heartbeat = utime.ticks_ms()
        _action = None
        _set_connection_line("connected: {}".format(addr[0]))
        _set_command_line("")
        _set_result_line("")
        set_face("idle")
        cyberpi.led.on(0, 255, 0, id="all")
        return

    if utime.ticks_diff(utime.ticks_ms(), _last_heartbeat) > HEARTBEAT_TIMEOUT_MS:
        stop_motors()
        _action = None
        _set_connection_line("no heartbeat")
        set_face("error")
        cyberpi.led.on(255, 0, 0, id="all")
        try:
            _conn.close()
        except Exception:
            pass
        _conn = None
        return

    try:
        chunk = _conn.recv(1024)
    except OSError:
        chunk = None  # nothing to read this tick

    if chunk:
        _buffered += chunk.decode("utf-8")
        while "\n" in _buffered:
            line, _buffered = _buffered.split("\n", 1)
            if not line:
                continue
            _last_heartbeat = utime.ticks_ms()
            try:
                command = ujson.loads(line)
            except Exception:
                continue
            handle_command(command, _make_send(_conn))
    elif chunk == b"":
        stop_motors()
        _action = None
        _set_connection_line("waiting for client")
        set_face("idle")
        try:
            _conn.close()
        except Exception:
            pass
        _conn = None


def tick():
    if not _booted:
        _boot()
        return
    _beacon_discovery()
    _pump_network()
    _pump_action()
