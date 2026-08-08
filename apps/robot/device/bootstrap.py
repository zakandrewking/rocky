# Rocky's robot-body OTA loader.
#
# Upload this ONCE via mBlock (matches the original plan's "install the CyberPi bootstrap
# manually through mBlock once"). After that, iteration never touches mBlock or USB again:
# apps/robot/scripts/push.mjs sends new payload code over the network, this loader writes it to
# PAYLOAD_PATH and reloads it. See apps/robot/PLAN.md's "Can we do OTA?" -- this supersedes that
# answer now that apps/robot/STEPS.md's socket gate confirmed both directions work for real.
#
# Design point that matters: this loader's own push-listener must keep working even when the
# payload is completely broken, or one bad push bricks remote recovery and you're back to a USB
# cable. So this file owns the ONE real event loop forever and never blocks inside the payload --
# it calls payload.tick() once per loop iteration instead of handing off control. A payload that
# throws gets dropped (stops being called) without stopping the loop that listens for the next
# push. Standalone on purpose, same reason as every other file in steps/ and device/: mBlock
# uploads one program at a time.

import cyberpi

try:
    import usocket as socket
except ImportError:
    import socket

WIFI_SSID = ""
WIFI_PASSWORD = ""
PAYLOAD_PATH = "/flash/rocky_payload.py"
PUSH_PORT = 8766

cyberpi.display.clear()
cyberpi.led.on(255, 165, 0, id="all")
cyberpi.display.show_label("Rocky bootstrap", 12, 0, 0, 0)
cyberpi.display.show_label("Wi-Fi: connecting", 12, 0, 20, 1)

if not cyberpi.wifi.is_connect():
    cyberpi.wifi.connect(WIFI_SSID, WIFI_PASSWORD)
    while not cyberpi.wifi.is_connect():
        pass

push_server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
push_server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
push_server.bind(("0.0.0.0", PUSH_PORT))
push_server.listen(1)
push_server.settimeout(0.05)


def check_for_push():
    """Non-blocking: returns True if a new payload was received and written this tick."""
    try:
        connection, _addr = push_server.accept()
    except OSError:
        return False

    connection.settimeout(5)
    chunks = []
    try:
        while True:
            chunk = connection.recv(1024)
            if not chunk:
                break
            chunks.append(chunk)
    except OSError:
        pass  # timeout after the sender closed its write side -- treat what we have as complete

    code = b"".join(chunks)
    try:
        with open(PAYLOAD_PATH, "wb") as f:
            f.write(code)
        connection.sendall("ok, wrote {} bytes\n".format(len(code)).encode())
    except Exception as error:
        connection.sendall("write failed: {}\n".format(error).encode())
    connection.close()
    return True


def load_payload():
    """Returns the payload's namespace dict, or None if there's no payload or it failed to load."""
    try:
        with open(PAYLOAD_PATH) as f:
            code = f.read()
    except OSError:
        return None

    namespace = {"__name__": "rocky_payload"}  # type: dict[str, object]
    try:
        exec(compile(code, PAYLOAD_PATH, "exec"), namespace)
    except Exception as error:
        cyberpi.display.show_label("PAYLOAD LOAD FAILED", 12, 0, 60, 3)
        print("payload failed to load:", error)
        return None
    return namespace


payload = load_payload()
cyberpi.display.clear()
cyberpi.display.show_label("Ready. Push :{}".format(PUSH_PORT), 12, 0, 0, 0)
cyberpi.led.on(0, 255, 0, id="all")

while True:
    if check_for_push():
        cyberpi.display.clear()
        cyberpi.display.show_label("New payload pushed", 12, 0, 0, 0)
        payload = load_payload()
        cyberpi.display.show_label("Reloaded" if payload else "Load failed", 12, 0, 20, 1)
        if payload:
            cyberpi.led.on(0, 255, 0, id="all")
        else:
            cyberpi.led.on(255, 0, 0, id="all")

    if payload and "tick" in payload:
        try:
            payload["tick"]()  # pyright: ignore[reportCallIssue]
        except Exception as error:
            print("payload tick raised:", error)
            payload = None  # stop calling a payload that's throwing; keep the loop (and pushes) alive
            cyberpi.display.clear()
            cyberpi.display.show_label("PAYLOAD CRASHED", 16, 0, 40, 2)
            cyberpi.display.show_label("Push a fix", 12, 0, 60, 3)
            cyberpi.led.on(255, 0, 0, id="all")
