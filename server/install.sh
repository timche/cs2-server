#!/usr/bin/env bash
# Sets up a CS2 server on this machine. Run it straight from the repo:
#   curl -fsSL https://raw.githubusercontent.com/timche/cs2-server/main/server/install.sh | bash
set -euo pipefail

REPO="${REPO:-timche/cs2-server}"
REF="${REF:-main}"
DIR="${DIR:-cs2-server}"
BASE_URL="${BASE_URL:-https://raw.githubusercontent.com/${REPO}/${REF}/server}"

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
		value="$(ask "$1" "${2:-}")"
		if [[ -n "$value" ]]; then
			break
		fi
		say "This one is required."
	done
	printf '%s' "$value"
}

ask_steam_id() {
	local value
	while true; do
		value="$(ask "$1" "${2:-}")"
		if [[ -z "$value" || "$value" =~ ^[0-9]{17}$ ]]; then
			break
		fi
		say "A Steam64 ID is 17 digits. Leave it empty to skip."
	done
	printf '%s' "$value"
}

# The mode file is what the panel shows and pre.sh boots from, so a rerun after
# a switch has to offer that rather than the CS2_MODE in .env, which goes stale
# the first time the panel writes one.
saved_mode() {
	local value=""
	if [[ -f "${DIR}/control/mode" ]]; then
		value="$(tr -d '[:space:]' <"${DIR}/control/mode" || true)"
	fi
	case "$value" in
		matchzy|retakes|chatcontrol) printf '%s' "$value" ;;
		*) saved CS2_MODE chatcontrol ;;
	esac
}

ask_mode() {
	local value
	while true; do
		value="$(ask "$1" "$2")"
		case "$value" in
			matchzy|retakes|chatcontrol) break ;;
		esac
		say "Enter matchzy, retakes or chatcontrol."
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

say "Setting up a CS2 server"
say ""

DIR="$(ask "Folder to create" "$DIR")"
if [[ -f "${DIR}/.env" ]]; then
	say "${DIR} already holds a server. Answers from the last run are offered as defaults."
fi

servername="$(ask_without_slash "Server name" "$(saved CS2_SERVERNAME CS2)")"
say ""
say "Every player on this server gets a chat command that runs arbitrary server"
say "commands, and in matchzy mode the run of MatchZy as well. A password keeps that"
say "to the people you invite."
password="$(ask_without_slash "Server password, or none to run without one" "$(saved CS2_PW "$(generate_password)")")"
if [[ "$password" == "none" ]]; then
	password=""
fi

rconpw="$(ask_without_slash "RCON password" "$(saved CS2_RCONPW "$(generate_password)")")"

say ""
say "A game server login token lists the server publicly. Create one for app ID 730 at"
say "https://steamcommunity.com/dev/managegameservers"
token="$(ask_required "Game server login token" "$(saved SRCDS_TOKEN "")")"

say ""
port="$(ask_number "Game port" "$(saved CS2_PORT 27015)")"
maxplayers="$(ask_number "Maximum players" "$(saved CS2_MAXPLAYERS 12)")"

say ""
say "In retakes mode, your Steam64 ID makes you an admin of the retakes plugins: the"
say "spawn editor, !forcebombsite, !scramble and !setnextround. They ask"
say "CounterStrikeSharp who is an admin, which the everyone-gets-admin setting above"
say "does not answer. Find your ID at https://steamid.io, or leave it empty."
adminid="$(ask_steam_id "Steam64 ID" "$(saved RETAKES_ADMIN_STEAM_IDS "")")"

say ""
say "The server runs one of three modes: matchzy for practice and pug matches,"
say "retakes, or chatcontrol for plain competitive. The panel switches between them"
say "later, so this is only where it starts."
mode="$(ask_mode "Mode to start in" "$(saved_mode)")"

say ""
say "The panel switches the mode and restarts the server, so its password is what"
say "keeps that to the people you trust with it."
panelpw="$(ask "Panel password" "$(saved PANEL_PASSWORD "$(generate_password)")")"
panelsecret="$(saved PANEL_SECRET "$(generate_password)")"

say ""
say "A Cloudflare tunnel reaches the panel from anywhere without opening a port. In"
say "Cloudflare Zero Trust, go to Networks > Tunnels, create a tunnel, route its"
say "public hostname to http://panel:8080 and copy the token it hands you. Leave this"
say "empty to run without a tunnel."
tunnel="$(ask "Cloudflare tunnel token" "$(saved TUNNEL_TOKEN "")")"

# A tunnel reaches the panel over the compose network, so publishing a port as
# well would only be one more thing to collide with something already on 8080.
profiles=""
panelport="$(saved PANEL_PORT 8080)"
if [[ -n "$tunnel" ]]; then
	profiles="tunnel"
else
	say ""
	panelport="$(ask_number "Panel port on 127.0.0.1" "$panelport")"
fi

mkdir -p "${DIR}/data" "${DIR}/control"
# Seeding the mode file here rather than leaving it to the first switch is what
# lets the panel report the mode from the first boot: it has no Docker socket and
# never reads .env, so an absent file leaves it with nothing to show. The server
# container reads this one as uid 1000, hence the permissions.
printf '%s\n' "$mode" >"${DIR}/control/mode"
chmod 755 "${DIR}/control"
chmod 644 "${DIR}/control/mode"
curl -fsSL "${BASE_URL}/docker-compose.yml" -o "${DIR}/docker-compose.yml"
curl -fsSL "${BASE_URL}/pre.sh" -o "${DIR}/pre.sh"
chmod +x "${DIR}/pre.sh"

# Compose picks this up on its own. Removed rather than left behind when a
# tunnel is configured, so a rerun that adds one takes the port away again.
if [[ -n "$tunnel" ]]; then
	rm -f "${DIR}/docker-compose.override.yml"
else
	cat >"${DIR}/docker-compose.override.yml" <<EOF
services:
  panel:
    ports:
      - "127.0.0.1:\${PANEL_PORT:-8080}:8080"
EOF
fi

umask 077
cat >"${DIR}/.env" <<EOF
SRCDS_TOKEN=${token}

CS2_SERVERNAME=${servername}
CS2_PW=${password}
CS2_RCONPW=${rconpw}

CS2_MODE=${mode}
RETAKES_ADMIN_STEAM_IDS=${adminid}

CS2_PORT=${port}
CS2_MAXPLAYERS=${maxplayers}
CS2_STARTMAP=de_dust2

CS2_GAMEALIAS=competitive
CS2_SERVER_HIBERNATE=0
CS2_LOG=off

TV_ENABLE=0
TV_PORT=27020
TV_AUTORECORD=0

PANEL_PORT=${panelport}
PANEL_PASSWORD=${panelpw}
PANEL_SECRET=${panelsecret}

COMPOSE_PROFILES=${profiles}
TUNNEL_TOKEN=${tunnel}
EOF

say ""
say "Wrote ${DIR}/.env, ${DIR}/docker-compose.yml and ${DIR}/pre.sh. The game files go"
say "in ${DIR}/data and the panel's mode file in ${DIR}/control."
if [[ -z "$password" ]]; then
	say ""
	say "This server has no password, so anyone who finds it can run server commands."
	say "Set CS2_PW in ${DIR}/.env to close it off."
fi
if [[ -z "$adminid" ]]; then
	say ""
	say "No admin was set, so in retakes mode nobody can edit spawns or force a"
	say "bombsite. Add Steam64 IDs to RETAKES_ADMIN_STEAM_IDS in ${DIR}/.env,"
	say "comma-separated, and restart."
fi
say ""

# The server runs as uid 1000 and a bind mount keeps the ownership the folder has
# here, so data/ has to belong to 1000 or SteamCMD cannot write the game files.
# control/ is the panel's to write, which it does as root; the server container
# only reads the mode file, as uid 1000, which the permissions above allow.
if [[ "$(id -u)" != 1000 ]]; then
	say "One thing is left, and it needs root. The server runs as uid 1000, which does"
	say "not own ${DIR}/data, so it cannot download the game there. Run:"
	say ""
	say "  sudo chown -R 1000:1000 ${DIR}/data"
	say ""
	say "and then start the server with: cd ${DIR} && docker compose up -d"
	say "It downloads about 60 GB of game files on the first run."
elif confirm "Start the server now?"; then
	(cd "$DIR" && docker compose up -d)
	say ""
	say "The server is starting. It downloads about 60 GB of game files on the first run,"
	say "so give it a while before it shows up."
else
	say ""
	say "Start it later with: cd ${DIR} && docker compose up -d"
fi

say ""
say "  Connect        connect <server-ip>:${port}${password:+; password ${password}}"
say "  RCON password  ${rconpw}"
if [[ -n "$tunnel" ]]; then
	say "  Panel          the hostname you routed to http://panel:8080 in Cloudflare"
else
	say "  Panel          http://127.0.0.1:${panelport}"
fi
say "  Panel password ${panelpw}"
say "  Follow along   cd ${DIR} && docker compose logs -f"
