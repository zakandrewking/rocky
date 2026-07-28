#!/usr/bin/env bash
# Shared helpers for the CyberPi recovery scripts. Sourced, not run directly.
#
# UNVERIFIED AGAINST HARDWARE. Written from esptool's own documentation and the
# port name (/dev/cu.wchusbserial14120) seen in Makeblock's own platformio.ini
# for this board (apps/cyberpi/docs/upstream-sources.md). The first real run of
# cyberpi:backup is this script's actual test. Fix what's wrong here rather
# than working around it silently - the next person needs it to work too.

cyberpi_log() {
  echo "[cyberpi] $*" >&2
}

cyberpi_die() {
  echo "[cyberpi] ERROR: $*" >&2
  exit 1
}

# Finds a working esptool invocation and prints it as a single string, e.g.
# "esptool.py" or "python3 -m esptool". Callers eval-split this into an array.
cyberpi_find_esptool() {
  if command -v esptool.py >/dev/null 2>&1; then
    echo "esptool.py"
    return 0
  fi
  if command -v esptool >/dev/null 2>&1; then
    echo "esptool"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1 && python3 -c "import esptool" >/dev/null 2>&1; then
    echo "python3 -m esptool"
    return 0
  fi
  cyberpi_die "esptool not found. Install it with: uv tool install esptool"
}

# Finds the CyberPi's USB-serial port. Honors CYBERPI_PORT if set. Otherwise
# globs the macOS device node patterns for the USB-serial chips ESP32 boards
# commonly use (WCH CH34x, Silicon Labs CP210x, native USB CDC). Dies with a
# clear message - listing what it did find - rather than guessing among
# several candidates, since writing to the wrong serial port is silent and
# consequence-free, but flashing the wrong *thing* over the wrong port is not
# a mistake worth risking.
cyberpi_find_port() {
  if [[ -n "${CYBERPI_PORT:-}" ]]; then
    echo "${CYBERPI_PORT}"
    return 0
  fi

  local candidates=()
  # macOS device node patterns, in likelihood order for this board (the
  # Arduino library's platformio.ini names a wchusbserial port).
  for pattern in /dev/cu.wchusbserial* /dev/cu.usbserial-* /dev/cu.SLAB_USBtoUART* /dev/cu.usbmodem*; do
    for match in $pattern; do
      [[ -e "$match" ]] && candidates+=("$match")
    done
  done

  if [[ ${#candidates[@]} -eq 1 ]]; then
    echo "${candidates[0]}"
    return 0
  fi

  if [[ ${#candidates[@]} -eq 0 ]]; then
    cyberpi_die "No USB-serial device found. Is the CyberPi connected and powered on? \
Set CYBERPI_PORT=/dev/cu.xxxx explicitly if it's a pattern this script doesn't recognize \
(check with: ls /dev/cu.*)."
  fi

  cyberpi_die "Found ${#candidates[@]} possible ports, not sure which is the CyberPi: \
${candidates[*]}. Set CYBERPI_PORT=/dev/cu.xxxx to pick one."
}

# Backups live outside git (binary firmware dumps, and this ensures a stale
# entry is never accidentally overwritten) under a fixed, findable directory.
cyberpi_backup_dir() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  echo "${here}/firmware/backups"
}
