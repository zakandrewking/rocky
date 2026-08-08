# Rocky's thin robot-body agent for stock CyberOS (mBot2 + CyberPi).
#
# UNTESTED ON HARDWARE: written with no board attached to this environment. Every call here is
# taken from real sources (see ../docs/mbuild-api-surface.md) but the wiring between them —
# whether this actually drives the robot correctly — has not been run. Do not trust it past
# apps/robot/STEPS.md's step 5. Standalone on purpose, like apps/cyberpi's step files: mBlock
# uploads one program at a time, so this pastes in whole with no imports from siblings.
#
# Wire protocol: newline-delimited JSON over a plain TCP socket, matching apps/robot/src/protocol.ts
# on the laptop side. See docs/mbuild-api-surface.md for why not WebSocket/MQTT (unconfirmed
# whether a WS handshake is practical here; a raw socket is the least capable thing that still
# works, and that's all this needs).

import cyberpi
import mbot2
import ujson
import utime

# --- Configuration: fill in before uploading ---
WIFI_SSID = ""
WIFI_PASSWORD = ""
TCP_PORT = 8765

# Heartbeat: the laptop sends {"type":"heartbeat"} on an interval (see robot.ts). If none arrives
# within this window, stop the motors and wait for a fresh connection. This is what keeps a
# dropped Wi-Fi link from leaving the robot driving blind — the whole reason the design in
# PLAN.md puts safety on the device, not the network.
HEARTBEAT_TIMEOUT_MS = 2000

# Obstacle-avoidance reflex: stop a commanded drive immediately if the ultrasonic sensor reports
# less than this many cm, regardless of what the laptop asked for. See PLAN.md, "AI goals x mBot2
# Shield obstacle avoidance."
OBSTACLE_STOP_CM = 15

# mbot2.drive_speed(em1, em2) is not time- or distance-boxed (unlike mbot2.straight()/turn(),
# which appear to block until the maneuver finishes -- see docs/mbuild-api-surface.md). Driving in
# short bursts here, polling the ultrasonic between them, is what makes the obstacle reflex and
# the heartbeat watchdog able to cut power quickly instead of only between blocking calls.
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

# mbuild accessory sensors, weaker evidence tier -- see docs/mbuild-api-surface.md. Wrapped in
# try/except everywhere they're used, since it's unconfirmed these import cleanly, and a base
# mBot2 kit may not have every accessory attached.
try:
    from mbuild import ultrasonic2, quad_rgb_sensor

    HAS_ULTRASONIC = True
except ImportError:
    HAS_ULTRASONIC = False

try:
    import usocket as socket
except ImportError:
    import socket


def connect_wifi():
    cyberpi.display.show_label("Rocky: connecting Wi-Fi", 12, 0, 0, 0)
    if not cyberpi.wifi.is_connect():
        cyberpi.wifi.connect(WIFI_SSID, WIFI_PASSWORD)
        while not cyberpi.wifi.is_connect():
            utime.sleep_ms(200)
    cyberpi.display.clear()
    cyberpi.display.show_label("Rocky: Wi-Fi up", 12, 0, 0, 0)


def read_distance_cm():
    if not HAS_ULTRASONIC:
        return -1
    return ultrasonic2.get_distance()


def stop_motors():
    mbot2.drive_speed(0, 0)


def drive_burst(speed_pct, forward):
    """One DRIVE_BURST_MS chunk of driving, aborted early if the ultrasonic reflex trips."""
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
            return False  # tripped the reflex; caller should stop and report
        utime.sleep_ms(10)

    stop_motors()
    return True


def drive_cm(distance_cm, speed_pct):
    """Drives in DRIVE_BURST_MS bursts so the obstacle reflex can cut in between them, rather
    than one long blocking mbot2.straight() call. See docs/mbuild-api-surface.md."""
    forward = distance_cm >= 0
    cm_per_burst = CM_PER_SECOND_AT_MAX_RPM * (speed_pct / 100.0) * (DRIVE_BURST_MS / 1000.0)
    remaining = abs(distance_cm)
    while remaining > 0:
        if not drive_burst(speed_pct, forward):
            return False  # obstacle reflex stopped us short
        remaining -= cm_per_burst
    return True


def turn_degrees(degrees, speed_pct):
    clockwise = degrees >= 0
    rpm = (speed_pct / 100.0) * MAX_RPM
    if not clockwise:
        rpm = -rpm
    em1 = rpm * TURN_RPM_SIGN[0]
    em2 = rpm * TURN_RPM_SIGN[1]
    seconds = abs(degrees) / max(DEGREES_PER_SECOND_AT_MAX_RPM * (speed_pct / 100.0), 1)

    mbot2.drive_speed(em1, em2)
    utime.sleep_ms(int(seconds * 1000))
    stop_motors()


def set_face(face):
    cyberpi.display.clear()
    labels = {
        "idle": ". _ .",
        "listening": "o _ o",
        "thinking": ". ~ .",
        "speaking": ". o .",
        "happy": "^ _ ^",
        "error": "x _ x",
    }
    cyberpi.display.show_label(labels.get(face, "?"), 24, 40, 60, 0)


def set_lights(r, g, b):
    cyberpi.led.on(r, g, b, id="all")


def read_line_sensors():
    if not HAS_ULTRASONIC:
        return []
    try:
        return [quad_rgb_sensor.get_reflect(i) for i in (1, 2)]
    except Exception:
        return []


def handle_command(command, send):
    command_type = command.get("type")
    command_id = command.get("id")

    if command_type == "heartbeat":
        return  # no reply needed; receipt alone resets the watchdog

    if command_type == "drive":
        ok = drive_cm(command["distanceCm"], command["speed"])
        if ok:
            send({"type": "ack", "id": command_id, "ok": True})
        else:
            send({"type": "error", "id": command_id, "ok": False, "message": "obstacle stop"})
    elif command_type == "turn":
        turn_degrees(command["degrees"], command["speed"])
        send({"type": "ack", "id": command_id, "ok": True})
    elif command_type == "stop":
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


def run_server():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("0.0.0.0", TCP_PORT))
    server.listen(1)
    server.settimeout(1)
    cyberpi.display.show_label("Rocky: listening :{}".format(TCP_PORT), 12, 0, 0, 0)

    while True:
        try:
            connection, _addr = server.accept()
        except OSError:
            continue  # accept() timeout; loop so this stays responsive to a future Ctrl-C

        connection.settimeout(0.1)
        set_face("idle")
        buffered = ""
        last_heartbeat = utime.ticks_ms()

        def send(message):
            connection.sendall(ujson.dumps(message) + "\n")

        while True:
            if utime.ticks_diff(utime.ticks_ms(), last_heartbeat) > HEARTBEAT_TIMEOUT_MS:
                stop_motors()
                set_face("error")
                break  # drop back to accept(), waiting for a fresh connection

            try:
                chunk = connection.recv(1024)
            except OSError:
                chunk = None  # recv() timeout; still need to check the heartbeat clock above

            if chunk:
                buffered += chunk.decode("utf-8")
                while "\n" in buffered:
                    line, buffered = buffered.split("\n", 1)
                    if not line:
                        continue
                    last_heartbeat = utime.ticks_ms()
                    command = ujson.loads(line)
                    handle_command(command, send)
            elif chunk == b"":
                stop_motors()
                break  # the laptop closed the connection

        connection.close()


connect_wifi()
run_server()
