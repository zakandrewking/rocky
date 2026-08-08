# apps/robot STEPS.md, step 4: the one fact that decides everything else.
#
# Proves: can an uploaded (standalone) CyberOS program open a real TCP socket, bind, listen, and
# accept a connection from another machine on the LAN? rocky_agent.py's whole design depends on
# this. Circumstantial evidence says yes (see docs/mbuild-api-surface.md's MQTT example), but
# nobody has run it for this project until now.
#
# Standalone on purpose, same reason as apps/cyberpi's step files: mBlock uploads one program at a
# time, so this pastes in whole with no imports from siblings.

import cyberpi
import utime

WIFI_SSID = ""
WIFI_PASSWORD = ""
TCP_PORT = 8765

try:
    import usocket as socket
except ImportError:
    import socket

cyberpi.display.clear()
cyberpi.led.on(255, 165, 0, id="all")
cyberpi.display.show_label("step 4: socket gate", 12, 0, 0, 0)

# --- Wi-Fi ---
cyberpi.display.show_label("Wi-Fi: connecting", 12, 0, 20, 1)
if not cyberpi.wifi.is_connect():
    cyberpi.wifi.connect(WIFI_SSID, WIFI_PASSWORD)
    while not cyberpi.wifi.is_connect():
        pass

# is_connect() apparently means "associated to the AP," not "DHCP finished" -- reading the IP
# immediately after it returned true gave "0.0.0.0" on the first run of this step. Poll instead of
# trusting the first read.
ip = "unknown"
try:
    import network

    wlan = network.WLAN(network.STA_IF)
    for attempt in range(50):  # ~10s at 200ms/attempt
        candidate = wlan.ifconfig()[0]
        if candidate not in ("0.0.0.0", ""):
            ip = candidate
            break
        cyberpi.display.show_label("Wi-Fi: DHCP... ({})".format(attempt), 12, 0, 20, 1)
        utime.sleep_ms(200)
    else:
        print("gave up waiting for a real IP; last value was", candidate)
except Exception as error:
    print("could not read IP via network.WLAN:", error)

cyberpi.display.clear()
cyberpi.display.show_label("Wi-Fi: {}".format(ip), 12, 0, 0, 0)
print("Wi-Fi connected, IP:", ip)

# --- The actual gate: bind, listen, accept ---
try:
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("0.0.0.0", TCP_PORT))
    server.listen(1)
except Exception as error:
    cyberpi.display.show_label("SOCKET FAILED", 16, 0, 40, 2)
    cyberpi.led.on(255, 0, 0, id="all")
    print("PASS/FAIL: socket setup failed:", error)
    raise

cyberpi.display.show_label("LISTENING :{}".format(TCP_PORT), 12, 0, 20, 1)
cyberpi.led.on(0, 255, 0, id="all")
print("PASS so far: socket bound and listening on port", TCP_PORT)

while True:
    connection, addr = server.accept()
    print("connection from", addr)
    cyberpi.display.show_label("Connected: {}".format(addr[0]), 12, 0, 40, 2)

    data = connection.recv(1024)
    text = data.decode("utf-8", "replace") if data else ""
    print("received:", text)
    cyberpi.display.show_label("Got: {}".format(text[:16]), 12, 0, 60, 3)

    connection.sendall(b"echo: " + data)
    connection.close()
    cyberpi.display.show_label("Waiting again...", 12, 0, 40, 2)
