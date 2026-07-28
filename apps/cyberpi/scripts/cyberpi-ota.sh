#!/usr/bin/env bash
# Pushes a new build to the CyberPi over Wi-Fi, once it's running firmware
# with the OTA HTTP receiver (apps/cyberpi/src/main.c) already on it. This is
# the fast path PLAN.md's OTA step exists for - no USB required after the
# first flash-rocky.
#
# Usage:
#   CYBERPI_OTA_HOST=192.168.1.42 pnpm cyberpi:ota
#
# The IP is whatever the board printed over serial after joining Wi-Fi
# (cyberpi-flash-rocky.sh's first run still needs USB + serial to read it).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

: "${CYBERPI_OTA_HOST:?Set CYBERPI_OTA_HOST=<device-ip>, printed over serial after Wi-Fi connects}"

PROJECT_DIR="$(cd .. && pwd)"
BIN="${PROJECT_DIR}/.pio/build/esp32dev/firmware.bin"

cyberpi_log "building ${PROJECT_DIR}"
(cd "${PROJECT_DIR}" && pio run)

cyberpi_log "pushing ${BIN} to http://${CYBERPI_OTA_HOST}/ota"
curl -sS --fail -X POST --data-binary "@${BIN}" "http://${CYBERPI_OTA_HOST}/ota"

cyberpi_log "PASS: OTA push accepted, board is rebooting into the new firmware"
