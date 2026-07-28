#!/usr/bin/env bash
# Builds and flashes the Stage 2 native firmware (apps/cyberpi/platformio.ini)
# to the CyberPi over USB. Reuses cyberpi-backup.sh/cyberpi-restore.sh's port
# detection so all three scripts pick the same board the same way.
#
# This overwrites whatever is currently on the board. Run cyberpi-backup.sh
# first if that hasn't already happened - see docs/recovery.md.
#
# Usage:
#   pnpm cyberpi:flash-rocky
#   CYBERPI_PORT=/dev/cu.wchusbserial14120 pnpm cyberpi:flash-rocky

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

PORT="$(cyberpi_find_port)"
PROJECT_DIR="$(cd .. && pwd)"

cyberpi_log "port: ${PORT}"
cyberpi_log "building and flashing ${PROJECT_DIR} to ${PORT}"

cd "${PROJECT_DIR}"
pio run --target upload --upload-port "${PORT}"

cyberpi_log "PASS: flash completed."
