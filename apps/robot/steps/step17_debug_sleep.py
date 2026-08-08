# Pushed into bootstrap.py as a payload. A safe base for debugging/diagnostic sessions --
# nothing else in apps/robot's step files should be trusted to poke at sensors or dir()-probe an
# API while it's also capable of driving. Push this FIRST whenever investigating something new
# (a new sensor, an unconfirmed API, anything exploratory), then push the real experiment back
# once the investigation is done.
#
# Born from a real near-miss (2026-08-08): step16_loudness_drive_sticky.py's floor-sensor dir()/
# probe diagnostics were pushed as part of the full driving payload, so a loud noise or a bug
# during that investigation could still have sent the robot driving while its attention was on
# debugging a sensor, not on safety. This payload can't do that: drive_speed(0, 0) is the ONLY
# call ever made to the motors, unconditionally, every tick -- there is no code path to anything
# else. Streams whatever sensors are currently interesting so debugging can happen live via
# scripts/telemetry.mjs without ever risking the robot actually moving.

import cyberpi
import mbot2
import utime

try:
    import usocket as socket
except ImportError:
    import socket

try:
    from mbuild import ultrasonic2

    HAS_ULTRASONIC = True
except ImportError:
    HAS_ULTRASONIC = False

try:
    from mbuild import quad_rgb_sensor

    HAS_LINE_SENSOR = True
except ImportError:
    HAS_LINE_SENSOR = False

LAPTOP_HOST = "192.168.1.138"  # this Mac's current LAN IP -- check `ipconfig getifaddr en0`
LAPTOP_PORT = 8767

_sock = None
_booted = False


def _connect_telemetry():
    global _sock
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(3)
        sock.connect((LAPTOP_HOST, LAPTOP_PORT))
        sock.settimeout(2)
        _sock = sock
    except Exception:
        _sock = None


def _send(extra):
    global _sock
    if _sock is None:
        _connect_telemetry()  # keep retrying -- debugging shouldn't need a fresh push just
        return  # because the laptop-side listener started late
    try:
        _sock.sendall('{{"t":{},"phase":"live"{}}}\n'.format(utime.ticks_ms(), extra).encode())
    except Exception:
        try:
            _sock.close()
        except Exception:
            pass
        _sock = None


def _boot():
    global _booted
    mbot2.drive_speed(0, 0)
    _connect_telemetry()
    cyberpi.display.clear()
    cyberpi.display.show_label("- -", 32, 40, 50, 0)  # asleep -- visually distinct from every
    cyberpi.led.on(60, 60, 60, id="all")  # other face this project uses, dim/neutral on purpose
    _booted = True


def tick():
    mbot2.drive_speed(0, 0)  # the only call to the motors in this entire file, every tick

    if not _booted:
        _boot()
        return

    loudness = cyberpi.get_loudness()
    extra = ',"loud":{}'.format(loudness)

    if HAS_ULTRASONIC:
        try:
            extra += ',"distance_cm":{}'.format(ultrasonic2.get_distance())
        except Exception as error:
            extra += ',"distance_error":"{}"'.format(str(error).replace('"', "'"))

    if HAS_LINE_SENSOR:
        try:
            extra += ',"reflect":[{}]'.format(
                ",".join(str(v) for v in quad_rgb_sensor.get_all_data()[0:4])
            )
        except Exception as error:
            extra += ',"reflect_error":"{}"'.format(str(error).replace('"', "'"))

    _send(extra)
