#!/usr/bin/env bash
# Sets up a MatchZy CS2 server on this machine. Run it straight from the repo:
#   curl -fsSL https://raw.githubusercontent.com/timche/cs2-servers/main/matchzy/install.sh | bash
set -euo pipefail

REPO="${REPO:-timche/cs2-servers}"
REF="${REF:-main}"
DIR="${DIR:-cs2-matchzy}"
BASE_URL="${BASE_URL:-https://raw.githubusercontent.com/${REPO}/${REF}/matchzy}"

say() { printf '%s\n' "$*" >&2; }
fail() { printf '\n%s\n' "$*" >&2; exit 1; }

# stdin is the curl pipe, so the questions have to talk to the terminal directly.
[[ -r /dev/tty ]] || fail "No terminal available for the setup questions. Download the script and run it instead:
  curl -fsSL ${BASE_URL}/install.sh -o install.sh && bash install.sh"
exec 3</dev/tty

generate_password() {
	LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 20
}

# saved <key> <fallback>
saved() {
	local value=""
	if [[ -f "${DIR}/.env" ]]; then
		value="$(sed -n "s/^${1}=//p" "${DIR}/.env" | head -1)"
	fi
	printf '%s' "${value:-$2}"
}

ask() {
	local question="$1" default="${2:-}" answer
	if [[ -n "$default" ]]; then
		printf '%s [%s]: ' "$question" "$default" >/dev/tty
	else
		printf '%s: ' "$question" >/dev/tty
	fi
	IFS= read -r answer <&3 || answer=""
	printf '%s' "${answer:-$default}"
}

# The image templates these values into its config files with sed, which a
# slash in the value breaks.
ask_without_slash() {
	local value
	while true; do
		value="$(ask "$1" "${2:-}")"
		if [[ "$value" != */* ]]; then
			break
		fi
		say "A slash is not supported here. Choose a value without one."
	done
	printf '%s' "$value"
}

ask_number() {
	local value
	while true; do
		value="$(ask "$1" "$2")"
		if [[ "$value" =~ ^[0-9]+$ ]]; then
			break
		fi
		say "Enter a number."
	done
	printf '%s' "$value"
}

ask_required() {
	local value
	while true; do
		value="$(ask "$1")"
		if [[ -n "$value" ]]; then
			break
		fi
		say "This one is required."
	done
	printf '%s' "$value"
}

confirm() {
	local answer
	printf '%s [Y/n]: ' "$1" >/dev/tty
	IFS= read -r answer <&3 || answer=""
	[[ ! "$answer" =~ ^[Nn] ]]
}

command -v docker >/dev/null ||
	fail "Docker is not installed. Install it with:
  curl -fsSL https://get.docker.com | sh"
docker compose version >/dev/null 2>&1 ||
	fail "The Docker Compose plugin is missing. Install it with:
  curl -fsSL https://get.docker.com | sh"

say "Setting up a MatchZy CS2 server in ${DIR}"
if [[ -f "${DIR}/.env" ]]; then
	say "Answers from the last run are offered as defaults."
fi
say ""

servername="$(ask_without_slash "Server name" "$(saved CS2_SERVERNAME MatchZy)")"

say ""
say "Every player on this server gets admin, which includes a chat command that runs"
say "arbitrary server commands. A password keeps that to the people you invite."
password="$(ask_without_slash "Server password, or none to run without one" "$(saved CS2_PW "$(generate_password)")")"
if [[ "$password" == "none" ]]; then
	password=""
fi

rconpw="$(ask_without_slash "RCON password" "$(saved CS2_RCONPW "$(generate_password)")")"

say ""
say "A game server login token lists the server publicly. Create one for app ID 730 at"
say "https://steamcommunity.com/dev/managegameservers"
token="$(ask_required "Game server login token")"

say ""
port="$(ask_number "Game port" "$(saved CS2_PORT 27015)")"
maxplayers="$(ask_number "Maximum players" "$(saved CS2_MAXPLAYERS 12)")"

mkdir -p "$DIR"
curl -fsSL "${BASE_URL}/docker-compose.yml" -o "${DIR}/docker-compose.yml"
curl -fsSL "${BASE_URL}/pre.sh" -o "${DIR}/pre.sh"
chmod +x "${DIR}/pre.sh"

umask 077
cat >"${DIR}/.env" <<EOF
SRCDS_TOKEN=${token}

CS2_SERVERNAME=${servername}
CS2_PW=${password}
CS2_RCONPW=${rconpw}

CS2_PORT=${port}
CS2_MAXPLAYERS=${maxplayers}

CS2_GAMEALIAS=competitive
CS2_SERVER_HIBERNATE=0
CS2_LOG=off

TV_ENABLE=0
TV_PORT=27020
TV_AUTORECORD=0
EOF

say ""
say "Wrote ${DIR}/.env, ${DIR}/docker-compose.yml and ${DIR}/pre.sh."
if [[ -z "$password" ]]; then
	say ""
	say "This server has no password, so anyone who finds it gets admin. Set CS2_PW"
	say "in ${DIR}/.env to close it off."
fi
say ""

if ! confirm "Start the server now?"; then
	say ""
	say "Start it later with: cd ${DIR} && docker compose up -d"
	exit 0
fi

(cd "$DIR" && docker compose up -d)

say ""
say "The server is starting. It downloads about 60 GB of game files on the first run,"
say "so give it a while before it shows up."
say ""
say "  Connect       connect <server-ip>:${port}${password:+; password ${password}}"
say "  RCON password ${rconpw}"
say "  Follow along  cd ${DIR} && docker compose logs -f"
