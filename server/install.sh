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

# A question .env already answers is not asked again and its value is kept, so a
# rerun updates the server instead of repeating the interview. Presence of the
# key decides, not its value: an empty CS2_PW or TUNNEL_TOKEN is an answer.
# Delete the line to be asked once more.
keep() {
	[[ -f "${DIR}/.env" ]] && grep -q "^${1}=" "${DIR}/.env"
}

# explain <key> [line]... -- the words before a question, and the blank line
# above them, printed only when the question is going to be asked.
explain() {
	local key="$1" line
	shift
	if keep "$key"; then
		return 0
	fi
	say ""
	for line in "$@"; do
		say "$line"
	done
}

# ask_once <key> <asker> <question> <default>
ask_once() {
	local key="$1" asker="$2"
	shift 2
	if keep "$key"; then
		saved "$key" ""
		return 0
	fi
	"$asker" "$@"
}

# .env is rewritten from the answers, so a key this script never asks about --
# one of the image's own variables, say -- would be dropped without this. Only
# real KEY=VALUE lines carry over, which leaves comments behind but keeps the
# file from growing a copy of itself on every rerun.
carry_over() {
	local new="$1" old="${DIR}/.env" line key announced=0

	[[ -f "$old" ]] || return 0
	while IFS= read -r line; do
		key="${line%%=*}"
		if [[ "$line" != *=* || -z "$key" || "$key" == *[!A-Za-z0-9_]* ]]; then
			continue
		fi
		if grep -q "^${key}=" "$new"; then
			continue
		fi
		if (( ! announced )); then
			printf '\n# Kept from the previous .env\n' >>"$new"
			say "Kept the values in ${DIR}/.env this installer does not ask about."
			announced=1
		fi
		printf '%s\n' "$line" >>"$new"
	done <"$old"
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
# The mode control/mode holds, or nothing when it is absent, unreadable or says
# something this version does not know.
mode_file() {
	local value=""
	if [[ -r "${DIR}/control/mode" ]]; then
		value="$(tr -d '[:space:]' <"${DIR}/control/mode" 2>/dev/null || true)"
	fi
	case "$value" in
		matchzy|retakes|chatcontrol) printf '%s' "$value" ;;
	esac
}

saved_mode() {
	local value
	value="$(mode_file)"
	printf '%s' "${value:-$(saved CS2_MODE chatcontrol)}"
}

# Only ever seeded, never rewritten: once the panel has switched a mode the file
# belongs to root, because that is what the panel container runs as, and this
# script does not. It is also the source of truth for the mode, so a rerun has
# nothing to say about it -- the value it carries forward came from here.
seed_mode() {
	local file="${DIR}/control/mode"

	if [[ "$(mode_file)" == "$mode" ]]; then
		return 0
	fi
	if ! printf '%s\n' "$mode" >"$file" 2>/dev/null; then
		say ""
		say "Could not write ${file}, which belongs to the panel. The server keeps the"
		say "mode it is on; switch it in the panel rather than here."
		return 0
	fi
	# The game server container reads this file as uid 1000.
	chmod 644 "$file" 2>/dev/null || true
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

say "Installing or updating a CS2 server"
say ""

DIR="$(ask "Server folder" "$DIR")"
# An existing .env is what makes this an update rather than an install: the
# questions it answers are skipped, so a rerun is how you take a new version of
# docker-compose.yml, pre.sh and the panel image.
updating=0
if [[ -f "${DIR}/.env" ]]; then
	updating=1
	say "${DIR} already holds a server, so this is an update: every question its .env"
	say "answers is skipped and that value kept. Delete a line from the file to be"
	say "asked again."
fi

servername="$(ask_once CS2_SERVERNAME ask_without_slash "Server name" CS2)"

explain CS2_PW \
	"Every player on this server gets a chat command that runs arbitrary server" \
	"commands, and in matchzy mode the run of MatchZy as well. A password keeps that" \
	"to the people you invite."
password="$(ask_once CS2_PW ask_without_slash "Server password, or none to run without one" "$(generate_password)")"
if [[ "$password" == "none" ]]; then
	password=""
fi

rconpw="$(ask_once CS2_RCONPW ask_without_slash "RCON password" "$(generate_password)")"

explain SRCDS_TOKEN \
	"A game server login token lists the server publicly. Create one for app ID 730 at" \
	"https://steamcommunity.com/dev/managegameservers"
token="$(ask_once SRCDS_TOKEN ask_required "Game server login token" "")"

explain CS2_PORT
port="$(ask_once CS2_PORT ask_number "Game port" 27015)"
maxplayers="$(ask_once CS2_MAXPLAYERS ask_number "Maximum players" 12)"

explain RETAKES_ADMIN_STEAM_IDS \
	"In retakes mode, your Steam64 ID makes you an admin of the retakes plugins: the" \
	"spawn editor, !forcebombsite, !scramble and !setnextround. They ask" \
	"CounterStrikeSharp who is an admin, which the everyone-gets-admin setting above" \
	"does not answer. Find your ID at https://steamid.io, or leave it empty."
adminid="$(ask_once RETAKES_ADMIN_STEAM_IDS ask_steam_id "Steam64 ID" "")"

# Not ask_once: the mode file, not .env, is what the server is running, so a
# rerun after a switch has to carry that value forward rather than CS2_MODE.
if keep CS2_MODE; then
	mode="$(saved_mode)"
else
	say ""
	say "The server runs one of three modes: matchzy for practice and pug matches,"
	say "retakes, or chatcontrol for plain competitive. The panel switches between them"
	say "later, so this is only where it starts."
	mode="$(ask_mode "Mode to start in" chatcontrol)"
fi

explain PANEL_PASSWORD \
	"The panel switches the mode and restarts the server, so its password is what" \
	"keeps that to the people you trust with it."
panelpw="$(ask_once PANEL_PASSWORD ask "Panel password" "$(generate_password)")"
panelsecret="$(saved PANEL_SECRET "$(generate_password)")"

explain TUNNEL_TOKEN \
	"A Cloudflare tunnel reaches the panel from anywhere without opening a port. In" \
	"Cloudflare Zero Trust, go to Networks > Tunnels, create a tunnel, route its" \
	"public hostname to http://panel:8080 and copy the token it hands you. Leave this" \
	"empty to run without a tunnel."
tunnel="$(ask_once TUNNEL_TOKEN ask "Cloudflare tunnel token" "")"

# A tunnel reaches the panel over the compose network, so publishing a port as
# well would only be one more thing to collide with something already on 8080.
profiles=""
panelport="$(saved PANEL_PORT 8080)"
if [[ -n "$tunnel" ]]; then
	profiles="tunnel"
else
	explain PANEL_PORT
	panelport="$(ask_once PANEL_PORT ask_number "Panel port on 127.0.0.1" "$panelport")"
fi

mkdir -p "${DIR}/data" "${DIR}/control"
# Seeding the mode file rather than leaving it to the first switch is what lets
# the panel report the mode from the first boot: it has no Docker socket and
# never reads .env, so an absent file leaves it with nothing to show.
chmod 755 "${DIR}/control" 2>/dev/null || true
seed_mode
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
cat >"${DIR}/.env.new" <<EOF
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
carry_over "${DIR}/.env.new"
mv "${DIR}/.env.new" "${DIR}/.env"

say ""
if (( updating )); then
	say "Updated ${DIR}/docker-compose.yml and ${DIR}/pre.sh, and kept ${DIR}/.env."
else
	say "Wrote ${DIR}/.env, ${DIR}/docker-compose.yml and ${DIR}/pre.sh. The game files go"
	say "in ${DIR}/data and the panel's mode file in ${DIR}/control."
fi
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
# The owner is what matters, not who is running this: an update started by
# another user has nothing to fix. control/ is the panel's to write, which it
# does as root; the server container only reads the mode file, as uid 1000.
if [[ "$(stat -c %u "${DIR}/data" 2>/dev/null || echo unknown)" != 1000 ]]; then
	say "One thing is left, and it needs root. The server runs as uid 1000, which does"
	say "not own ${DIR}/data, so it cannot download the game there. Run:"
	say ""
	say "  sudo chown -R 1000:1000 ${DIR}/data"
	say ""
	say "and then start the server with: cd ${DIR} && docker compose up -d"
	if (( ! updating )); then
		say "It downloads about 60 GB of game files on the first run."
	fi
elif (( updating )); then
	if confirm "Restart the server to pick the changes up?"; then
		(cd "$DIR" && docker compose up -d --pull always)
		say ""
		say "The server is restarting. pre.sh updates the plugins on the way up."
	else
		say ""
		say "Pick them up later with: cd ${DIR} && docker compose up -d --pull always"
	fi
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
