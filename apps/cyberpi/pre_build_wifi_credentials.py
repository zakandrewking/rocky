# Generates src/wifi_credentials.h from the repo root .env before every build,
# so the real Wi-Fi password lives in the same gitignored place as every other
# secret in this repo (OPENAI_API_KEY, ROCKY_DEVICE_TOKENS, ...) rather than in
# a committed sdkconfig or platformio.ini.
Import("env")

import os

PROJECT_DIR = env.subst("$PROJECT_DIR")


def find_repo_root(start):
    current = start
    while True:
        if os.path.isdir(os.path.join(current, ".git")):
            return current
        parent = os.path.dirname(current)
        if parent == current:
            return start
        current = parent


def read_dotenv(path):
    values = {}
    if not os.path.exists(path):
        return values
    with open(path, "r", encoding="utf-8") as env_file:
        for line in env_file:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip()
    return values


def c_string_literal(value):
    return value.replace("\\", "\\\\").replace('"', '\\"')


env_values = read_dotenv(os.path.join(find_repo_root(PROJECT_DIR), ".env"))
ssid = env_values.get("CYBERPI_WIFI_SSID", "")
password = env_values.get("CYBERPI_WIFI_PASSWORD", "")

header_path = os.path.join(PROJECT_DIR, "src", "wifi_credentials.h")
with open(header_path, "w", encoding="utf-8") as header_file:
    header_file.write(
        "// Generated at build time from the repo root .env - do not edit, do not commit.\n"
        "#pragma once\n\n"
        '#define CYBERPI_WIFI_SSID "{}"\n'
        '#define CYBERPI_WIFI_PASSWORD "{}"\n'.format(
            c_string_literal(ssid), c_string_literal(password)
        )
    )

if not ssid:
    print(
        "[cyberpi] WARNING: CYBERPI_WIFI_SSID not set in the repo root .env - "
        "Wi-Fi connect will fail until it is. See .env.example."
    )
