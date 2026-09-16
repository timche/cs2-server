#!/usr/bin/env bash
# Puts proxy.sh on this machine and walks through its questions. Run it straight from the repo:
#   curl -fsSL https://raw.githubusercontent.com/timche/cs2-server/main/proxy/install.sh | bash
set -euo pipefail

REPO="${REPO:-timche/cs2-server}"
REF="${REF:-main}"
DIR="${DIR:-cs2-proxy}"
BASE_URL="${BASE_URL:-https://raw.githubusercontent.com/${REPO}/${REF}/proxy}"

fail() { printf '\n%s\n' "$*" >&2; exit 1; }

[[ -r /dev/tty ]] || fail "No terminal available for the setup questions. Download the script and run it instead:
  curl -fsSL ${BASE_URL}/install.sh -o install.sh && bash install.sh"

for tool in nft tailscale systemctl; do
	command -v "$tool" >/dev/null || fail "${tool} is not installed."
done

mkdir -p "$DIR"
curl -fsSL "${BASE_URL}/proxy.sh" -o "${DIR}/proxy.sh"
chmod +x "${DIR}/proxy.sh"

exec bash "${DIR}/proxy.sh" configure
