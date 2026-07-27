"""Step 8 - can the robot reach Rocky's own backend, and how fast?

First proof that CyberPi can talk to something other than Makeblock's cloud.
Also measures the latency floor: every round trip in a conversation pays this,
before the model has thought about anything.

Uses a raw socket rather than urequests, so the number reflects the network
stack rather than a library, and so the step still works if urequests is
missing (see step 6).

BEFORE RUNNING
  1. Start the service on your computer:
       pnpm device-api
  2. Find that computer's LAN IP (`ipconfig getifaddr en0` on macOS) and put it
     in API_HOST below. "localhost" would mean the robot itself.
  3. Fill in the Wi-Fi details, same as step 7.

EXPECTED
  - status 200 and a JSON body naming rocky-device-api
  - average round trip well under 250 ms on a quiet 2.4 GHz network

IF IT FAILS
  - connection refused: the service binds 0.0.0.0, so check the computer's
    firewall rather than the service
  - times out: robot and computer are probably on different VLANs, or the
    router has client isolation enabled for the guest network
"""

import time

import cyberpi

WIFI_SSID = ""
WIFI_PASSWORD = ""
API_HOST = "192.168.1.10"
API_PORT = 8787
POST_RESULTS = True  # also send the numbers to the service, so they are saved


def ticks_ms():
    if hasattr(time, "ticks_ms"):
        return time.ticks_ms()
    return int(time.time() * 1000)


def elapsed_since(start):
    if hasattr(time, "ticks_diff"):
        return time.ticks_diff(time.ticks_ms(), start)
    return int(time.time() * 1000) - start


def http(method, path, body=None):
    """Minimal HTTP/1.1 over a raw socket. Returns (status, body, elapsed_ms)."""
    try:
        import usocket as socket
    except ImportError:
        import socket

    payload = body.encode() if isinstance(body, str) else (body or b"")
    address = socket.getaddrinfo(API_HOST, API_PORT)[0][-1]
    sock = socket.socket()
    try:
        sock.settimeout(10)
    except Exception:
        pass

    started = ticks_ms()
    try:
        sock.connect(address)
        head = "%s %s HTTP/1.1\r\nHost: %s:%d\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n" % (
            method,
            path,
            API_HOST,
            API_PORT,
            len(payload),
        )
        request = head.encode() + payload
        if hasattr(sock, "write"):
            sock.write(request)
        else:
            sock.send(request)

        chunks = []
        while True:
            chunk = sock.read(512) if hasattr(sock, "read") else sock.recv(512)
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
    header, _, response_body = raw.partition(b"\r\n\r\n")
    status_line = header.decode("utf-8", "ignore").split("\r\n")[0]
    parts = status_line.split(" ")
    status = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
    return status, response_body.decode("utf-8", "ignore"), took


cyberpi.console.clear()
cyberpi.console.println("Rocky step 8: HTTP")
print("Rocky step 8: HTTP round trip to device-api")

cyberpi.console.println("wifi...")
cyberpi.wifi.connect(WIFI_SSID, WIFI_PASSWORD)
for _ in range(40):
    if cyberpi.wifi.is_connect():
        break
    time.sleep(0.5)

if not cyberpi.wifi.is_connect():
    cyberpi.console.println("NO WIFI - see step 7")
    print("no Wi-Fi; step 7 has the troubleshooting notes")
else:
    cyberpi.console.println("GET /v1/health")
    status, body, took = http("GET", "/v1/health")
    print("status " + str(status) + " in " + str(took) + " ms")
    print("body: " + body[:200])

    if status != 200:
        cyberpi.console.println("FAIL status " + str(status))
    else:
        # Repeat, because the first request pays for DNS and ARP.
        timings = []
        for _ in range(5):
            _, _, each = http("GET", "/v1/health")
            timings.append(each)
        average = sum(timings) / len(timings)

        print("timings: " + str(timings))
        print("average: " + str(int(average)) + " ms")
        # Every conversational turn pays this twice, before the model runs.
        print("verdict: " + ("good" if average < 250 else "SLOW - realtime will suffer"))
        cyberpi.console.println("avg " + str(int(average)) + " ms")

        if POST_RESULTS:
            report = (
                '{"probe":"rocky-cyberpi-stage1","step":8,"passed":1,"failed":0,'
                '"checks":[{"section":"http","name":"health_latency","ok":true,"detail":"avg %d ms %s"}]}'
                % (int(average), str(timings))
            )
            code, _, _ = http("POST", "/v1/probe/report", report)
            print("results posted: status " + str(code))

print("Record the average in apps/cyberpi/STEPS.md")
