#!/usr/bin/env bash
# Writes a backup taken by cyberpi-backup.sh back to the board, restoring
# whatever firmware that backup captured - normally stock CyberOS, since the
# whole point is to run cyberpi-backup.sh before anything else ever touches
# the board.
#
# UNVERIFIED AGAINST HARDWARE. See cyberpi-backup.sh's header for why a
# self-made dump is the recovery strategy here instead of a downloaded
# official image.
#
# Usage:
#   pnpm cyberpi:restore                                  # restores the newest backup
#   CYBERPI_BACKUP=path/to/file.bin pnpm cyberpi:restore   # restores a specific one
#   CYBERPI_PORT=/dev/cu.wchusbserial14120 pnpm cyberpi:restore

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

ESPTOOL="$(cyberpi_find_esptool)"
PORT="$(cyberpi_find_port)"
BACKUP_DIR="$(cyberpi_backup_dir)"

if [[ -n "${CYBERPI_BACKUP:-}" ]]; then
  BACKUP_FILE="${CYBERPI_BACKUP}"
else
  # Newest .bin in the backup directory, portable between BSD and GNU ls.
  BACKUP_FILE="$(ls -t "${BACKUP_DIR}"/*.bin 2>/dev/null | head -n1 || true)"
fi

if [[ -z "${BACKUP_FILE}" || ! -f "${BACKUP_FILE}" ]]; then
  cyberpi_die "No backup found in ${BACKUP_DIR}. Run 'pnpm cyberpi:backup' first - there is \
nothing to restore until a known-good dump exists."
fi

BACKUP_BYTES="$(wc -c < "${BACKUP_FILE}" | tr -d ' ')"
CHECKSUM="$(shasum -a 256 "${BACKUP_FILE}" | cut -d' ' -f1)"

cyberpi_log "esptool: ${ESPTOOL}"
cyberpi_log "port:    ${PORT}"
cyberpi_log "backup:  ${BACKUP_FILE}"
cyberpi_log "         ${BACKUP_BYTES} bytes, sha256 ${CHECKSUM}"
cyberpi_log ""
cyberpi_log "This overwrites the ENTIRE flash on the board at ${PORT} with the file above."
read -r -p "[cyberpi] Type 'restore' to continue: " CONFIRM
if [[ "${CONFIRM}" != "restore" ]]; then
  cyberpi_die "Not confirmed - nothing written."
fi

cyberpi_log "writing ${BACKUP_BYTES} bytes to 0x0 - do not unplug the board"
${ESPTOOL} --port "${PORT}" write_flash 0x0 "${BACKUP_FILE}"

cyberpi_log "PASS: write completed. Power-cycle the CyberPi and confirm it boots into normal"
cyberpi_log "CyberOS - screen shows the home UI, mBlock can reconnect to it - before trusting"
cyberpi_log "this restore path for real."
