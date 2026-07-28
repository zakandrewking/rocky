#!/usr/bin/env bash
# Dumps the CyberPi's ENTIRE current flash to a local file, before any custom
# firmware ever touches the board. This backup - not a downloaded copy of
# Makeblock's official firmware - is what `cyberpi-restore.sh` writes back.
#
# Why a self-made dump instead of hunting for an official firmware .bin:
# Makeblock does not appear to publish one as a standalone file - firmware
# updates happen through mBlock's own GUI flow, not a downloadable image (see
# apps/cyberpi/docs/upstream-sources.md and PLAN.md for what was and wasn't
# found). A full dump of flash taken from this exact board, before we ever
# write to it, is guaranteed byte-identical to what shipped, needs no
# Makeblock server to be reachable at restore time, and is the standard,
# well-established ESP32 recovery technique.
#
# UNVERIFIED AGAINST HARDWARE. Written from esptool's documented behavior, not
# tested against a real CyberPi. Run this FIRST, before anything in
# apps/cyberpi/firmware/ is ever flashed. If it fails or the output looks
# wrong, fix this script - don't work around it by hand.
#
# Usage:
#   pnpm cyberpi:backup
#   CYBERPI_PORT=/dev/cu.wchusbserial14120 pnpm cyberpi:backup   # if auto-detect can't pick one

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

ESPTOOL="$(cyberpi_find_esptool)"
PORT="$(cyberpi_find_port)"
BACKUP_DIR="$(cyberpi_backup_dir)"
mkdir -p "${BACKUP_DIR}"

cyberpi_log "esptool: ${ESPTOOL}"
cyberpi_log "port: ${PORT}"
cyberpi_log "detecting flash size (flash-id is read-only, safe to run any time)..."

FLASH_ID_OUTPUT="$(${ESPTOOL} --port "${PORT}" flash-id 2>&1)" || {
  echo "${FLASH_ID_OUTPUT}" >&2
  cyberpi_die "flash-id failed - see esptool's output above. Common causes: wrong port \
(set CYBERPI_PORT), board not in bootloader mode (some boards need BOOT held during reset - \
try that if auto-reset doesn't work), or a cable that only carries power."
}
echo "${FLASH_ID_OUTPUT}"

DETECTED_SIZE_MB="$(echo "${FLASH_ID_OUTPUT}" | grep -oE 'Detected flash size: [0-9]+MB' | grep -oE '[0-9]+' || true)"
if [[ -z "${DETECTED_SIZE_MB}" ]]; then
  cyberpi_die "Could not parse a flash size out of flash_id's output above. This script's \
regex expects a line like 'Detected flash size: 4MB' - esptool's wording may have changed. \
Fix the grep in this file rather than guessing a size; reading the wrong number of bytes \
produces a truncated, useless backup."
fi

FLASH_BYTES=$((DETECTED_SIZE_MB * 1024 * 1024))
FLASH_HEX="$(printf '0x%X' "${FLASH_BYTES}")"
cyberpi_log "flash size: ${DETECTED_SIZE_MB}MB (${FLASH_HEX} bytes)"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_FILE="${BACKUP_DIR}/cyberpi-stock-${DETECTED_SIZE_MB}MB-${TIMESTAMP}.bin"

cyberpi_log "reading ${FLASH_HEX} bytes from 0x0 -> ${OUT_FILE}"
cyberpi_log "this takes a few minutes at typical serial speeds - do not unplug the board"

${ESPTOOL} --port "${PORT}" read-flash 0x0 "${FLASH_BYTES}" "${OUT_FILE}"

ACTUAL_BYTES="$(wc -c < "${OUT_FILE}" | tr -d ' ')"
if [[ "${ACTUAL_BYTES}" != "${FLASH_BYTES}" ]]; then
  cyberpi_die "Backup file is ${ACTUAL_BYTES} bytes, expected ${FLASH_BYTES}. \
Something truncated the read. Delete ${OUT_FILE} and re-run - do not trust a short file as a backup."
fi

CHECKSUM="$(shasum -a 256 "${OUT_FILE}" | cut -d' ' -f1)"

cyberpi_log "PASS: backed up ${ACTUAL_BYTES} bytes"
cyberpi_log "  file:     ${OUT_FILE}"
cyberpi_log "  sha256:   ${CHECKSUM}"
cyberpi_log ""
cyberpi_log "This file is the only way back to stock CyberOS that doesn't depend on Makeblock's"
cyberpi_log "servers. Keep it. It is gitignored on purpose - do not commit it, but do not delete"
cyberpi_log "it either. cyberpi-restore.sh writes back whichever backup is newest by default."
