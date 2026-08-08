# apps/robot STEPS.md, step 4, outbound variant.
#
# step01_socket_gate.py (inbound: board binds/listens, laptop connects in) showed "LISTENING"
# on screen but nothing on the LAN could ever reach it, and network.WLAN(network.STA_IF).ifconfig()
# never resolved a real address even after a 10s retry loop. socket.bind(("0.0.0.0", port))
# succeeds locally regardless of whether Wi-Fi actually has a routable IP, so "LISTENING" was not
# proof of real connectivity.
#
# This flips the direction: the board connects OUT to a listener on the laptop, mirroring the one
# thing we have real precedent for (docs/mbuild-api-surface.md's MQTT example reaching an external
# broker). If this works, sockets and routing are fine and the earlier bug is specific to inbound
# listening. If this also fails, Wi-Fi itself isn't really up despite is_connect() saying so.

import cyberpi

WIFI_SSID = ""
WIFI_PASSWORD = ""
LAPTOP_HOST = "192.168.1.138"  # this Mac's current LAN IP
LAPTOP_PORT = 9999

try:
    import usocket as socket
except ImportError:
    import socket

cyberpi.display.clear()
cyberpi.led.on(255, 165, 0, id="all")
cyberpi.display.show_label("step 4b: outbound", 12, 0, 0, 0)

cyberpi.display.show_label("Wi-Fi: connecting", 12, 0, 20, 1)
if not cyberpi.wifi.is_connect():
    cyberpi.wifi.connect(WIFI_SSID, WIFI_PASSWORD)
    while not cyberpi.wifi.is_connect():
        pass

cyberpi.display.clear()
cyberpi.display.show_label("Wi-Fi: associated", 12, 0, 0, 0)
cyberpi.display.show_label("Connecting out...", 12, 0, 20, 1)
print("attempting outbound connect to", LAPTOP_HOST, LAPTOP_PORT)

outbound_ok = False
try:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(5)
    sock.connect((LAPTOP_HOST, LAPTOP_PORT))
    sock.sendall(b"hello from cyberpi\n")
    cyberpi.display.clear()
    cyberpi.display.show_label("CONNECTED + SENT", 16, 0, 40, 2)
    cyberpi.led.on(0, 255, 0, id="all")
    print("PASS: outbound connect + send succeeded")
    sock.close()
    outbound_ok = True
except Exception as error:
    cyberpi.display.clear()
    cyberpi.display.show_label("OUTBOUND FAILED", 16, 0, 40, 2)
    cyberpi.led.on(255, 0, 0, id="all")
    print("FAIL: outbound connect failed:", error)

# Now try the direction that failed before the power cycle: board listens, laptop connects in.
# Same run, same already-confirmed-good Wi-Fi state -- no re-upload, no risk of the upload stall
# STEPS.md now warns about.
if outbound_ok:
    import utime

    utime.sleep_ms(1500)
    cyberpi.display.clear()
    cyberpi.display.show_label("Now: inbound test", 12, 0, 0, 0)
    try:
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("0.0.0.0", 8765))
        server.listen(1)
        cyberpi.display.show_label("LISTENING :8765", 12, 0, 20, 1)
        print("PASS so far: inbound socket bound and listening on 8765")

        connection, addr = server.accept()
        print("inbound connection from", addr)
        cyberpi.display.clear()
        cyberpi.display.show_label("INBOUND OK: {}".format(addr[0]), 12, 0, 40, 2)
        cyberpi.led.on(0, 255, 0, id="all")
        connection.sendall(b"hello back from cyberpi\n")
        connection.close()
    except Exception as error:
        cyberpi.display.clear()
        cyberpi.display.show_label("INBOUND FAILED", 16, 0, 40, 2)
        cyberpi.led.on(255, 0, 0, id="all")
        print("FAIL: inbound listen/accept failed:", error)
