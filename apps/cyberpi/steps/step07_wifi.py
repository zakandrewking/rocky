"""Step 7 - does Wi-Fi connect, and how long does it take?

Prerequisite for steps 8-12. Also worth timing: if joining the network takes
15 seconds every boot, that is 15 seconds before Rocky can say hello, and the
screen needs a "connecting" state to cover it.

EDIT THE TWO LINES BELOW before uploading.

EXPECTED
  - connects within a few seconds
  - MAC address prints (useful for a DHCP reservation, which makes step 8's
    host address stable)

IF IT FAILS
  - CyberPi is 2.4 GHz only. A 5 GHz-only SSID will never connect.
  - Hidden SSIDs and captive portals do not work.
  - WPA3-only networks may not work; try WPA2 compatibility mode.
"""

import time

import cyberpi

WIFI_SSID = ""
WIFI_PASSWORD = ""


def ticks_ms():
    if hasattr(time, "ticks_ms"):
        return time.ticks_ms()
    return int(time.time() * 1000)


def elapsed_since(start):
    if hasattr(time, "ticks_diff"):
        return time.ticks_diff(time.ticks_ms(), start)
    return int(time.time() * 1000) - start


cyberpi.console.clear()
cyberpi.console.println("Rocky step 7: wifi")
print("Rocky step 7: Wi-Fi")

if not WIFI_SSID:
    cyberpi.console.println("SET WIFI_SSID FIRST")
    print("Edit WIFI_SSID and WIFI_PASSWORD at the top of this file.")
else:
    cyberpi.led.on(60, 40, 0)
    cyberpi.console.println("connecting to " + WIFI_SSID)
    started = ticks_ms()
    cyberpi.wifi.connect(WIFI_SSID, WIFI_PASSWORD)

    connected = False
    for _ in range(40):  # 20 seconds
        if cyberpi.wifi.is_connect():
            connected = True
            break
        time.sleep(0.5)

    took = elapsed_since(started)
    if connected:
        cyberpi.led.on(0, 60, 0)
        cyberpi.console.println("PASS in " + str(took) + " ms")
        print("connected in " + str(took) + " ms")
        print("this delay happens every boot - the screen needs a connecting state")
    else:
        cyberpi.led.on(60, 0, 0)
        cyberpi.console.println("FAIL after " + str(took) + " ms")
        print("no connection after " + str(took) + " ms")
        print("CyberPi is 2.4 GHz only - check the band, and avoid hidden SSIDs")

    try:
        mac = cyberpi.get_mac_address()
        print("MAC: " + str(mac))
        print("reserve this in DHCP so step 8's host address stays stable")
    except Exception as exc:
        print("MAC unavailable: " + str(exc))
