# Disposable navigation-sensor qualification payload. This does not run Rocky's autonomous
# behaviour and does not become part of the boot path. It exists to answer three hardware
# questions with measured data before navigation is designed around guesses:
#
#   - how quickly CyberPi yaw drifts while still, and whether its delta agrees with a physical turn;
#   - whether short, closed-loop drive_speed pulses repeat on the floor with the phone mounted;
#   - how ultrasonic readings compare with tape-measured targets and troublesome materials.
#
# The stock CyberOS mbot2 API has no published readable wheel-position primitive. Do not call the
# commanded RPM and elapsed time "encoder deltas": the host records physical displacement as the
# ground truth instead. The encoder's only role here is whatever closed-loop speed regulation
# drive_speed() performs internally.
#
# Run:
#   1. pnpm robot:push <board-ip> apps/robot/steps/step19_navigation_sensor_qualification.py
#   2. pnpm robot:qualify <board-ip>
#
# Safety: motion is accepted only as a <=500 ms pulse at <=60 RPM. Forward motion is refused when
# the ultrasonic sensor already reports something within 35 cm and is stopped between ticks if
# that threshold is crossed. Every exception and disconnect stops both motors. A host-side stop is
# useful, but correctness never depends on Wi-Fi delivering it.

import cyberpi
import mbot2
import utime

try:
    import ujson as json
except ImportError:
    import json

try:
    import usocket as socket
except ImportError:
    import socket

try:
    from mbuild import ultrasonic2

    HAS_ULTRASONIC = True
except ImportError:
    ultrasonic2 = None
    HAS_ULTRASONIC = False


PORT = 8770
MAX_RPM = 60
MAX_PULSE_MS = 500
OBSTACLE_STOP_CM = 35
SAMPLE_INTERVAL_MS = 50
SERVER_RETRY_MS = 3000


def _distance_cm():
    if not HAS_ULTRASONIC:
        return None
    try:
        value = ultrasonic2.get_distance()
        return value if value >= 0 else None
    except Exception:
        return None


def _stop_motors():
    mbot2.drive_speed(0, 0)


_state = {
    "server": None,
    "client": None,
    "buffer": "",
    "last_sample": 0,
    "server_retry_at": 0,
    "motion": None,
}


def _send(message):
    client = _state["client"]
    if client is None:
        return
    try:
        client.sendall((json.dumps(message) + "\n").encode())
    except Exception:
        _disconnect()


def _sample(event="sample", **extra):
    message = {
        "event": event,
        "t": utime.ticks_ms(),
        "yaw": cyberpi.get_yaw(),
        "distance_cm": _distance_cm(),
    }
    message.update(extra)
    return message


def _disconnect():
    _stop_motors()
    _state["motion"] = None
    client = _state["client"]
    _state["client"] = None
    _state["buffer"] = ""
    if client is not None:
        try:
            client.close()
        except Exception:
            pass
    cyberpi.led.on(255, 165, 0, id="all")
    cyberpi.display.show_label("Sensor qualification", 12, 0, 0, 0)
    cyberpi.display.show_label("waiting on :{}".format(PORT), 12, 0, 24, 1)


def _finish_motion(reason):
    motion = _state["motion"]
    if motion is None:
        return
    _stop_motors()
    _state["motion"] = None
    _send(
        _sample(
            "motion_end",
            id=motion["id"],
            kind=motion["kind"],
            reason=reason,
            started_t=motion["started"],
            start_yaw=motion["start_yaw"],
            min_distance_cm=motion["min_distance"],
        )
    )
    cyberpi.led.on(0, 255, 0, id="all")


def _start_motion(command):
    if _state["motion"] is not None:
        _send({"event": "refused", "id": command.get("id"), "reason": "motion already active"})
        return

    kind = command.get("kind")
    rpm = int(command.get("rpm", 0))
    duration_ms = int(command.get("duration_ms", 0))
    direction = 1 if int(command.get("direction", 1)) >= 0 else -1
    if kind not in ("drive", "spin"):
        _send({"event": "refused", "id": command.get("id"), "reason": "unsupported motion"})
        return
    if rpm < 10 or rpm > MAX_RPM or duration_ms < 50 or duration_ms > MAX_PULSE_MS:
        _send({"event": "refused", "id": command.get("id"), "reason": "outside safe bounds"})
        return

    distance = _distance_cm()
    if kind == "drive" and direction > 0 and distance is not None and distance < OBSTACLE_STOP_CM:
        _send(
            {
                "event": "refused",
                "id": command.get("id"),
                "reason": "obstacle",
                "distance_cm": distance,
            }
        )
        return

    now = utime.ticks_ms()
    _state["motion"] = {
        "id": command.get("id", "motion"),
        "kind": kind,
        "direction": direction,
        "rpm": rpm,
        "duration_ms": duration_ms,
        "started": now,
        "start_yaw": cyberpi.get_yaw(),
        "min_distance": distance,
    }
    if kind == "drive":
        mbot2.drive_speed(direction * rpm, direction * -rpm)
    else:
        mbot2.drive_speed(direction * rpm, direction * rpm)
    cyberpi.led.on(255, 0, 255, id="all")
    _send(_sample("motion_start", id=_state["motion"]["id"], kind=kind))


def _handle(command):
    command_type = command.get("type")
    if command_type == "hello":
        _send(
            _sample(
                "hello",
                service="rocky-navigation-qualification",
                has_ultrasonic=HAS_ULTRASONIC,
                max_rpm=MAX_RPM,
                max_pulse_ms=MAX_PULSE_MS,
            )
        )
    elif command_type == "mark":
        _send(_sample("mark", id=command.get("id"), label=command.get("label", "")))
    elif command_type == "motion":
        _start_motion(command)
    elif command_type == "stop":
        if _state["motion"] is not None:
            _finish_motion("host_stop")
        else:
            _stop_motors()
            _send(_sample("stopped", id=command.get("id")))
    else:
        _send({"event": "refused", "id": command.get("id"), "reason": "unknown command"})


def _open_server():
    try:
        import gc

        gc.collect()
    except Exception:
        pass
    server = None
    try:
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        except Exception:
            pass
        server.bind(("0.0.0.0", PORT))
        server.listen(1)
        server.settimeout(0)
        _state["server"] = server
        _disconnect()
        return True
    except Exception:
        if server is not None:
            try:
                server.close()
            except Exception:
                pass
        _state["server"] = None
        return False


def _ensure_server(now):
    if _state["server"] is not None:
        return
    if utime.ticks_diff(now, _state["server_retry_at"]) < 0:
        return
    if not _open_server():
        _state["server_retry_at"] = utime.ticks_add(now, SERVER_RETRY_MS)


def _accept_client():
    if _state["client"] is not None or _state["server"] is None:
        return
    try:
        client, _ = _state["server"].accept()
        client.settimeout(0)
        _state["client"] = client
        _state["buffer"] = ""
        cyberpi.led.on(0, 80, 255, id="all")
        cyberpi.display.show_label("host connected", 12, 0, 48, 2)
    except Exception:
        pass


def _read_commands():
    client = _state["client"]
    if client is None:
        return
    try:
        chunk = client.recv(1024)
        if not chunk:
            _disconnect()
            return
        _state["buffer"] += chunk.decode()
    except Exception:
        return

    while "\n" in _state["buffer"]:
        line, _state["buffer"] = _state["buffer"].split("\n", 1)
        if not line.strip():
            continue
        try:
            _handle(json.loads(line))
        except Exception as error:
            _send({"event": "refused", "reason": "bad command", "detail": str(error)})


def _tick_motion(now):
    motion = _state["motion"]
    if motion is None:
        return
    distance = _distance_cm()
    if distance is not None and (
        motion["min_distance"] is None or distance < motion["min_distance"]
    ):
        motion["min_distance"] = distance
    if motion["kind"] == "drive" and motion["direction"] > 0:
        if distance is not None and distance < OBSTACLE_STOP_CM:
            _finish_motion("obstacle")
            return
    if utime.ticks_diff(now, motion["started"]) >= motion["duration_ms"]:
        _finish_motion("complete")


# Stop immediately on load, including when this payload replaces one that happened to be moving.
# Open the server lazily from tick(): during an OTA replacement the previous payload still owns its
# sockets until bootstrap swaps namespaces, so binding here would make a same-payload re-push fail.
_stop_motors()


def tick():
    now = utime.ticks_ms()
    try:
        _ensure_server(now)
        _accept_client()
        _read_commands()
        _tick_motion(now)
        if _state["client"] is not None and utime.ticks_diff(now, _state["last_sample"]) >= SAMPLE_INTERVAL_MS:
            _state["last_sample"] = now
            _send(_sample())
    except Exception:
        _stop_motors()
        raise
