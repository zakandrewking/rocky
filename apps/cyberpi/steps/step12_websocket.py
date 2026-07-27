"""Step 12 - is a streaming transport possible from CyberOS?

The plan asks for WebSocket support, because that is what an OpenAI Realtime
session speaks. Request/response HTTP can carry a turn-based conversation, but
not barge-in and not incremental audio.

This step does not implement WebSocket. It answers the question that comes
first: can a CyberOS socket complete the RFC 6455 upgrade handshake at all?
That is where embedded stacks usually fail — a socket layer that only speaks
request/response, or one that mangles headers.

The service replies 101 with the correct Sec-WebSocket-Accept and then hangs
up, which is enough to prove the handshake survives the round trip. Framing,
masking, and ping/pong come later, and only if Stage 1 gets that far.

EXPECTED
  - status 101 and an Upgrade: websocket header echoed back

IF IT FAILS
  - status 0 or a timeout: the socket layer likely cannot send custom headers
  - a 400: the request reached the service malformed; print the raw response
    and compare it against what the service expects
"""

import time

import cyberpi

WIFI_SSID = ""
WIFI_PASSWORD = ""
API_HOST = "192.168.1.10"
API_PORT = 8787
POST_RESULTS = True

# Matches the fixture asserted in services/device-api/src/websocket.test.ts, so
# a mismatch here is the robot's fault rather than a stale test.
CLIENT_KEY = "cm9ja3lwcm9iZWtleTEyMw=="
EXPECTED_ACCEPT = "5PIn9tIFvwkCRAeICcutP+2gmDw="


def ticks_ms():
    if hasattr(time, "ticks_ms"):
        return time.ticks_ms()
    return int(time.time() * 1000)


def elapsed_since(start):
    if hasattr(time, "ticks_diff"):
        return time.ticks_diff(time.ticks_ms(), start)
    return int(time.time() * 1000) - start


def upgrade():
    """Send an RFC 6455 handshake. Returns (status, raw response text, elapsed_ms)."""
    try:
        import usocket as socket
    except ImportError:
        import socket

    address = socket.getaddrinfo(API_HOST, API_PORT)[0][-1]
    sock = socket.socket()
    try:
        sock.settimeout(10)
    except Exception:
        pass

    started = ticks_ms()
    try:
        sock.connect(address)
        request = (
            "GET /v1/probe/ws HTTP/1.1\r\n"
            "Host: %s:%d\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Key: %s\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n" % (API_HOST, API_PORT, CLIENT_KEY)
        ).encode()

        if hasattr(sock, "write"):
            sock.write(request)
        else:
            sock.send(request)

        chunks = []
        while True:
            chunk = sock.read(256) if hasattr(sock, "read") else sock.recv(256)
            if not chunk:
                break
            chunks.append(chunk)
        raw = b"".join(chunks)
    finally:
        try:
            sock.close()
        except Exception:
            pass

    took = elapsed_since(started)
    text = raw.decode("utf-8", "ignore")
    status_line = text.split("\r\n")[0] if text else ""
    parts = status_line.split(" ")
    status = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
    return status, text, took


def post_report(body):
    """Plain HTTP POST, so this step can save its own result. Returns the status."""
    try:
        import usocket as socket
    except ImportError:
        import socket

    payload = body.encode()
    address = socket.getaddrinfo(API_HOST, API_PORT)[0][-1]
    sock = socket.socket()
    try:
        sock.settimeout(10)
    except Exception:
        pass

    try:
        sock.connect(address)
        head = "POST /v1/probe/report HTTP/1.1\r\nHost: %s:%d\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n" % (
            API_HOST,
            API_PORT,
            len(payload),
        )
        request = head.encode() + payload
        if hasattr(sock, "write"):
            sock.write(request)
        else:
            sock.send(request)

        chunk = sock.read(64) if hasattr(sock, "read") else sock.recv(64)
    finally:
        try:
            sock.close()
        except Exception:
            pass

    status_line = (chunk or b"").decode("utf-8", "ignore").split("\r\n")[0]
    parts = status_line.split(" ")
    return int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0


cyberpi.console.clear()
cyberpi.console.println("Rocky step 12: websocket")
print("Rocky step 12: WebSocket upgrade handshake")

cyberpi.wifi.connect(WIFI_SSID, WIFI_PASSWORD)
for _ in range(40):
    if cyberpi.wifi.is_connect():
        break
    time.sleep(0.5)

if not cyberpi.wifi.is_connect():
    cyberpi.console.println("NO WIFI - see step 7")
    print("no Wi-Fi; step 7 has the troubleshooting notes")
else:
    try:
        status, text, took = upgrade()
    except Exception as exc:
        status, text, took = 0, type(exc).__name__ + ": " + str(exc), 0

    print("status " + str(status) + " in " + str(took) + " ms")
    print("raw response:")
    for line in text.split("\r\n")[:8]:
        print("  " + line)

    upgraded = status == 101 and "websocket" in text.lower()
    accept_ok = EXPECTED_ACCEPT in text

    if upgraded and accept_ok:
        print("")
        print("PASS - the handshake completed and the accept key matched")
        print("a streaming transport is possible; framing is still to be written")
        cyberpi.console.println("PASS 101 upgrade")
    elif upgraded:
        print("")
        print("upgraded, but the accept key did not match - the socket may be mangling headers")
        cyberpi.console.println("101 but bad key")
    else:
        print("")
        print("FAIL - no upgrade. Streaming is not available from CyberOS.")
        print("a turn-based request/response loop would be the only option")
        cyberpi.console.println("FAIL no upgrade")

    if POST_RESULTS:
        ok = upgraded and accept_ok
        report = (
            '{"probe":"rocky-cyberpi-stage1","step":12,"passed":%d,"failed":%d,'
            '"checks":[{"section":"websocket","name":"upgrade_handshake","ok":%s,"detail":"status %d in %d ms"}]}'
            % (1 if ok else 0, 0 if ok else 1, "true" if ok else "false", status, took)
        )
        try:
            print("results posted: status " + str(post_report(report)))
        except Exception as exc:
            print("could not post results: " + str(exc))
            print("copy this into STEPS.md instead: " + report)

print("Record the handshake result in apps/cyberpi/STEPS.md")
