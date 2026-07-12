#!/usr/bin/env bash
set -euo pipefail

REPO="${ROCKY_REPO:-zakandrewking/rocky}"
RAW_BASE="${ROCKY_RAW_BASE:-https://raw.githubusercontent.com/${REPO}/main}"
APP_SUPPORT="${ROCKY_APP_SUPPORT:-${HOME}/Library/Application Support/Rocky}"
LOCAL_DATA="${APP_SUPPORT}/local-data"
CONFIG_FILE="${APP_SUPPORT}/config.env"
BRIDGE_FILE="${LOCAL_DATA}/onlyoffice-bridge.json"
ONLYOFFICE_APP="/Applications/ONLYOFFICE.app"
ONLYOFFICE_PLUGIN_DIR="${HOME}/Library/Application Support/asc.onlyoffice.ONLYOFFICE/data/sdkjs-plugins/rocky-live-spreadsheet-bridge"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

need_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

read_secret() {
  local prompt="$1"
  local value=""
  if [[ ! -r /dev/tty ]]; then
    echo "Cannot prompt for ${prompt}; run this installer from an interactive terminal." >&2
    exit 1
  fi
  read -r -s -p "${prompt}: " value < /dev/tty
  echo > /dev/tty
  printf '%s' "${value}"
}

json_get_asset_url() {
  awk -F'"' '/browser_download_url/ && /\.dmg"/ { print $4; exit }' "$1"
}

json_get_token() {
  sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -n 1
}

ensure_bridge_config() {
  mkdir -p "${LOCAL_DATA}"
  if [[ -f "${BRIDGE_FILE}" ]]; then
    return
  fi
  local token
  token="$(openssl rand -hex 32)"
  {
    echo "{"
    echo "  \"token\": \"${token}\","
    echo "  \"port\": 17421"
    echo "}"
  } > "${BRIDGE_FILE}"
}

write_config_if_needed() {
  mkdir -p "${APP_SUPPORT}"
  if [[ -f "${CONFIG_FILE}" ]]; then
    echo "Rocky config already exists: ${CONFIG_FILE}"
    return
  fi

  echo "Creating Rocky config: ${CONFIG_FILE}"
  local openai_key
  openai_key="$(read_secret "OpenAI API key")"
  if [[ -z "${openai_key}" ]]; then
    echo "OPENAI_API_KEY is required." >&2
    exit 1
  fi

  {
    echo "OPENAI_API_KEY=${openai_key}"
    echo "ROCKY_REALTIME_MODEL=${ROCKY_REALTIME_MODEL:-gpt-realtime-2.1}"
    echo "ROCKY_VOICE=${ROCKY_VOICE:-cedar}"
    echo "ROCKY_RESEARCH_MODEL=${ROCKY_RESEARCH_MODEL:-gpt-5.5}"
    echo "ROCKY_RESEARCH_TIMEOUT_MS=${ROCKY_RESEARCH_TIMEOUT_MS:-20000}"
    echo "ROCKY_RESEARCH_REASONING_EFFORT=${ROCKY_RESEARCH_REASONING_EFFORT:-low}"
    echo "ROCKY_RESEARCH_MAX_OUTPUT_TOKENS=${ROCKY_RESEARCH_MAX_OUTPUT_TOKENS:-900}"
    echo "ROCKY_ALIEN_VOICE=1"
    echo "ROCKY_ALIEN_VOICE_VOLUME=${ROCKY_ALIEN_VOICE_VOLUME:-0.045}"
    echo "ROCKY_ALIEN_VOICE_TIME_SCALE=${ROCKY_ALIEN_VOICE_TIME_SCALE:-0.68}"
  } > "${CONFIG_FILE}"
  chmod 600 "${CONFIG_FILE}"

  if [[ -n "${HUME_API_KEY:-}" ]]; then
    {
      echo "HUME_API_KEY=${HUME_API_KEY}"
      [[ -n "${HUME_VOICE_ID:-}" ]] && echo "HUME_VOICE_ID=${HUME_VOICE_ID}"
    } >> "${CONFIG_FILE}"
  fi
}

ensure_onlyoffice() {
  if [[ -d "${ONLYOFFICE_APP}" ]]; then
    echo "ONLYOFFICE already installed."
    return
  fi
  if command -v brew >/dev/null 2>&1; then
    echo "Installing ONLYOFFICE with Homebrew..."
    brew install --cask onlyoffice
    return
  fi
  cat >&2 <<EOF
ONLYOFFICE is required for Rocky's spreadsheet control.
Install Homebrew from https://brew.sh, then rerun this script, or install ONLYOFFICE Desktop Editors manually.
EOF
  exit 1
}

install_onlyoffice_plugin() {
  ensure_bridge_config
  mkdir -p "${ONLYOFFICE_PLUGIN_DIR}"
  curl -fsSL "${RAW_BASE}/integrations/onlyoffice-rocky/config.json" -o "${ONLYOFFICE_PLUGIN_DIR}/config.json"
  curl -fsSL "${RAW_BASE}/integrations/onlyoffice-rocky/index.html" -o "${ONLYOFFICE_PLUGIN_DIR}/index.html"
  curl -fsSL "${RAW_BASE}/integrations/onlyoffice-rocky/code.js" -o "${ONLYOFFICE_PLUGIN_DIR}/code.js"
  local token
  token="$(json_get_token "${BRIDGE_FILE}")"
  printf 'window.ROCKY_ONLYOFFICE_BRIDGE = {"port":17421,"token":"%s"};\n' "${token}" \
    > "${ONLYOFFICE_PLUGIN_DIR}/bridge-config.js"
  chmod 600 "${ONLYOFFICE_PLUGIN_DIR}/bridge-config.js"
  echo "Installed Rocky ONLYOFFICE plugin."
}

install_rocky_app() {
  need_command curl
  curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" -o "${TMP_DIR}/release.json"
  local dmg_url
  dmg_url="$(json_get_asset_url "${TMP_DIR}/release.json")"
  if [[ -z "${dmg_url}" ]]; then
    echo "No .dmg asset found on the latest GitHub release for ${REPO}." >&2
    exit 1
  fi
  echo "Downloading Rocky DMG..."
  curl -fL "${dmg_url}" -o "${TMP_DIR}/Rocky.dmg"
  echo "Opening Rocky DMG. Drag Rocky.app to Applications if Finder asks."
  open "${TMP_DIR}/Rocky.dmg"
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer is for macOS only." >&2
  exit 1
fi

need_command openssl
need_command open

write_config_if_needed
ensure_onlyoffice
install_onlyoffice_plugin
install_rocky_app

cat <<EOF

Rocky install steps complete.

Config: ${CONFIG_FILE}
Local data: ${LOCAL_DATA}

After copying Rocky.app into Applications, launch it once.
If ONLYOFFICE was already open, quit and reopen ONLYOFFICE before testing live spreadsheet updates.
EOF
