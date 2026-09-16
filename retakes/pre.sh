#!/usr/bin/env bash
# Installs and updates Metamod:Source, CounterStrikeSharp, cs2-retakes,
# cs2-instadefuse, RetakesAllocator and ChatControl into the CS2 server, then
# applies their configuration.
#
# The image's entry.sh *sources* this file after SteamCMD has updated the game
# and before it launches cs2.sh, so it must never call exit at the top level --
# that would take the server down with it. Everything runs in a subshell whose
# failure is only reported. Running after SteamCMD is also what makes this the
# only viable place for the gameinfo.gi patch, which CS2 updates undo.

(
set -euo pipefail

CSGO="${STEAMAPPDIR}/game/csgo"
STATE="${STEAMAPPDIR}/.retakes"
CSS_CONFIGS="${CSGO}/addons/counterstrikesharp/configs"
MMS_DROP="https://mms.alliedmods.net/mmsdrop/2.0"
CONVAR_CFG="cs2-server.cfg"

log() { echo "[retakes] $*"; }

# sync <name> <version> <url> <destination>
sync() {
	local name="$1" version="$2" url="$3" dest="$4"
	local stamp="${STATE}/${name}.version" tmp status=0

	if [[ -f "$stamp" && "$(cat "$stamp")" == "$version" ]]; then
		log "${name} ${version} is up to date"
		return 0
	fi

	log "installing ${name} ${version}"
	tmp="$(mktemp -d)"
	mkdir -p "$dest"
	if curl -fsSL --retry 3 -o "${tmp}/package" "$url"; then
		case "$url" in
			*.tar.gz) tar -xzf "${tmp}/package" -C "$dest" || status=1 ;;
			# The allocator's zip was built on Windows: its paths use backslash
			# separators, which Info-ZIP translates but exits 1 to warn about --
			# only 2 and up are real errors -- and its directory entries carry no
			# execute bit, which would leave the server unable to enter the
			# plugin's own runtimes/ directory. Hence unpacking aside and
			# repairing before anything lands in the server tree.
			*.zip)
				unzip -q -o "${tmp}/package" -d "${tmp}/unpacked" || status=$?
				(( status > 1 )) || status=0
				if (( status == 0 )); then
					chmod -R u+rwX "${tmp}/unpacked" &&
						cp -a "${tmp}/unpacked/." "$dest/" || status=1
				fi
				;;
			*) log "ERROR: cannot unpack ${url}"; status=1 ;;
		esac
	else
		status=1
	fi
	rm -rf "$tmp"

	if (( status )); then
		return 1
	fi
	mkdir -p "$STATE"
	printf '%s\n' "$version" >"$stamp"
}

sync_metamod() {
	local file
	file="$(curl -fsSL --retry 3 "${MMS_DROP}/mmsource-latest-linux")" || return 1
	[[ -n "$file" ]] || return 1
	sync metamod "$file" "${MMS_DROP}/${file}" "$CSGO"
}

# sync_release <name> <repo> <asset pattern> <destination>
sync_release() {
	local name="$1" repo="$2" pattern="$3" dest="$4" release version url
	release="$(curl -fsSL --retry 3 "https://api.github.com/repos/${repo}/releases/latest")" || return 1
	version="$(jq -re .tag_name <<<"$release")" || return 1
	url="$(jq -re --arg pattern "$pattern" \
		'.assets[] | select(.name | test($pattern)) | .browser_download_url' <<<"$release")" || return 1
	sync "$name" "$version" "$url" "$dest"
}

# Out of date beats absent: a GitHub rate limit or an upstream outage should not
# take a working server offline.
keep_installed() {
	local stamp="${STATE}/${1}.version"
	if [[ ! -f "$stamp" ]]; then
		log "ERROR: could not install ${1}"
		return 1
	fi
	log "WARNING: could not check ${1} for updates, keeping $(cat "$stamp")"
}

register_metamod() {
	local gameinfo="${CSGO}/gameinfo.gi"

	if [[ ! -f "$gameinfo" ]]; then
		log "ERROR: ${gameinfo} not found, Metamod will not load"
		return 1
	fi
	if grep -q 'csgo/addons/metamod' "$gameinfo"; then
		return 0
	fi

	sed -i -E 's|^([[:space:]]*)Game([[:space:]]+)csgo$|\1Game\2csgo/addons/metamod\n\1Game\2csgo|' "$gameinfo"
	if ! grep -q 'csgo/addons/metamod' "$gameinfo"; then
		log "ERROR: could not add Metamod to the search paths in gameinfo.gi"
		return 1
	fi
	log "registered Metamod in gameinfo.gi"
}

exec_convars_from() {
	local config="$1"
	mkdir -p "$(dirname "$config")"
	touch "$config"
	grep -qxF "exec ${CONVAR_CFG}" "$config" ||
		printf '\nexec %s\n' "$CONVAR_CFG" >>"$config"
}

# merge_json <file> <jq filter>
merge_json() {
	local file="$1" filter="$2" base='{}' tmp

	if [[ -s "$file" ]]; then
		# CounterStrikeSharp opens its generated configs with a // comment line,
		# which jq will not parse.
		base="$(sed '/^[[:space:]]*\/\//d' "$file")"
		if ! jq -e . >/dev/null 2>&1 <<<"$base"; then
			log "WARNING: ${file} is not valid JSON, replacing it"
			base='{}'
		fi
	fi

	mkdir -p "$(dirname "$file")"
	tmp="$(mktemp)"
	if ! jq "$filter" <<<"$base" >"$tmp"; then
		rm -f "$tmp"
		log "ERROR: could not write ${file}"
		return 1
	fi
	mv "$tmp" "$file"
	chmod 644 "$file"
}

# The allocator hands out the weapons, so retakes' own allocation has to be off
# or players get both. CounterStrikeSharp generates this config on first plugin
# load and never rewrites it afterwards, so owning the one key is enough; every
# key left out of a seeded file takes the plugin's default.
configure_retakes() {
	merge_json "${CSS_CONFIGS}/plugins/RetakesPlugin/RetakesPlugin.json" \
		'. * {GameSettings: {EnableFallbackAllocation: false}}'
}

# Retakes and the allocator ask CounterStrikeSharp whether a player holds
# @css/root, a question chatcontrol_everyone_is_admin does not answer: that only
# bypasses ChatControl's own check. Merged rather than replaced so entries added
# by hand survive; CounterStrikeSharp ships admins.example.json, never this file.
configure_admins() {
	local ids="${RETAKES_ADMIN_STEAM_IDS:-}" admins='{}' id
	[[ -n "$ids" ]] || return 0

	for id in ${ids//,/ }; do
		if [[ ! "$id" =~ ^[0-9]{17}$ ]]; then
			log "WARNING: ignoring ${id}, which is not a Steam64 ID"
			continue
		fi
		admins="$(jq -c --arg id "$id" \
			'. + {($id): {identity: $id, flags: ["@css/root"]}}' <<<"$admins")"
	done

	merge_json "${CSS_CONFIGS}/admins.json" ". * ${admins}"
}

configure() {
	mkdir -p "${CSGO}/cfg"
	cat >"${CSGO}/cfg/${CONVAR_CFG}" <<-EOF
		chatcontrol_everyone_is_admin 1
	EOF

	# One call site, where matchzy has two: the rest of the game convars are
	# retakes' own cfg/cs2-retakes/retakes.cfg, which it only fills in when the
	# file does not already exist, so nothing here may create or touch it.
	exec_convars_from "${CSGO}/cfg/gamemode_competitive_server.cfg"
}

failed=0
sync_metamod || keep_installed metamod || failed=1
sync_release counterstrikesharp roflmuffin/CounterStrikeSharp \
	'^counterstrikesharp-with-runtime-linux-.*\.zip$' "$CSGO" ||
	keep_installed counterstrikesharp || failed=1
# The plain asset, not RetakesPlugin-*-no-map-configs: the map configs are the
# spawns, so an update replaces spawns edited in game with upstream's.
sync_release retakes B3none/cs2-retakes \
	'^RetakesPlugin-[0-9.]+\.zip$' "$CSGO" ||
	keep_installed retakes || failed=1
sync_release instadefuse B3none/cs2-instadefuse \
	'^cs2-instadefuse-.*\.zip$' "${CSGO}/addons/counterstrikesharp/plugins" ||
	keep_installed instadefuse || failed=1
sync_release allocator Micka2302/cs2-retakes-allocator-2.0 \
	'^RetakesAllocator\.zip$' "${CSGO}/addons/counterstrikesharp" ||
	keep_installed allocator || failed=1
sync_release chatcontrol timche/cs2-chat-control \
	'^ChatControl-.*\.zip$' "${CSGO}/addons/counterstrikesharp/plugins" ||
	keep_installed chatcontrol || failed=1
register_metamod || failed=1
# After the syncs, so a CounterStrikeSharp reinstall cannot undo them.
configure_retakes || failed=1
configure_admins || failed=1
configure

if (( failed )); then
	exit 1
fi
log "ready"
) || echo "[retakes] WARNING: plugin setup did not finish, starting the server anyway"
