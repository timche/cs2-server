#!/usr/bin/env bash
# Installs and updates Metamod:Source, CounterStrikeSharp, MatchZy, cs2-retakes,
# cs2-instadefuse, RetakesAllocator and ChatControl into the CS2 server, enables
# the plugins the current mode wants, then applies their configuration.
#
# The image's entry.sh *sources* this file after SteamCMD has updated the game
# and before it launches cs2.sh, so it must never call exit at the top level --
# that would take the server down with it. Everything runs in a subshell whose
# failure is only reported. Running after SteamCMD is also what makes this the
# only viable place for the gameinfo.gi patch, which CS2 updates undo.

(
set -euo pipefail

CSGO="${STEAMAPPDIR}/game/csgo"
STATE="${STEAMAPPDIR}/.cs2"
CSS_CONFIGS="${CSGO}/addons/counterstrikesharp/configs"
PLUGINS="${CSGO}/addons/counterstrikesharp/plugins"
DISABLED="${PLUGINS}/disabled"
MMS_DROP="https://mms.alliedmods.net/mmsdrop/2.0"
CONVAR_CFG="cs2-server.cfg"

log() { echo "[cs2] $*"; }

# The panel owns .control/mode, mounted read-only here; the environment only
# says which mode to come up in before the panel has ever written one.
resolve_mode() {
	local file="${STEAMAPPDIR}/.control/mode"

	MODE=""
	if [[ -f "$file" ]]; then
		MODE="$(tr -d '[:space:]' <"$file" || true)"
	fi
	case "$MODE" in
		matchzy|retakes|chatcontrol) return 0 ;;
		"") ;;
		*) log "WARNING: ${file} holds \"${MODE}\", which is not a mode" ;;
	esac

	MODE="${CS2_MODE:-chatcontrol}"
	case "$MODE" in
		matchzy|retakes|chatcontrol) ;;
		*)
			log "WARNING: CS2_MODE is \"${MODE}\", which is not a mode"
			MODE="chatcontrol"
			;;
	esac
}

# Which plugin directories a component brought with it, so activate can park
# exactly those. An archive may unpack at the game root, at the
# CounterStrikeSharp root or at the plugin root, so the names come from the
# archive rather than being written down here.
record_plugins() {
	local name="$1" root="$2" dest="$3" dir rel

	mkdir -p "$STATE"
	: >"${STATE}/${name}.plugins"
	while IFS= read -r dir; do
		rel="${dir#"${root}/"}"
		[[ "$(dirname "${dest}/${rel}")" == "$PLUGINS" ]] || continue
		basename "$rel" >>"${STATE}/${name}.plugins"
	done < <(find "$root" -mindepth 1 -type d)
}

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
	mkdir -p "$dest" "${tmp}/unpacked"
	if curl -fsSL --retry 3 -o "${tmp}/package" "$url"; then
		case "$url" in
			*.tar.gz) tar -xzf "${tmp}/package" -C "${tmp}/unpacked" || status=1 ;;
			# The allocator's zip was built on Windows: its paths use backslash
			# separators, which Info-ZIP translates but exits 1 to warn about --
			# only 2 and up are real errors -- and its directory entries carry no
			# execute bit, which stops the walk below descending into them and
			# would leave the server unable to enter the plugin's own runtimes/
			# directory. Hence unpacking aside and repairing first.
			*.zip)
				unzip -q -o "${tmp}/package" -d "${tmp}/unpacked" || status=$?
				(( status > 1 )) || status=0
				;;
			*) log "ERROR: cannot unpack ${url}"; status=1 ;;
		esac
		if (( status == 0 )); then
			chmod -R u+rwX "${tmp}/unpacked" &&
				record_plugins "$name" "${tmp}/unpacked" "$dest" &&
				cp -a "${tmp}/unpacked/." "$dest/" || status=1
		fi
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

# Everything parked comes back before the syncs run, so an update reaches the
# plugins of the modes nobody is playing and a later switch waits on no
# download. A name in both places means the live copy is the one that counts.
restore_all() {
	local dir plugin

	[[ -d "$DISABLED" ]] || return 0
	for dir in "$DISABLED"/*/; do
		[[ -d "$dir" ]] || continue
		plugin="$(basename "$dir")"
		if [[ -e "${PLUGINS}/${plugin}" ]]; then
			rm -rf "$dir"
			continue
		fi
		mv "$dir" "${PLUGINS}/${plugin}"
	done
}

# CounterStrikeSharp's loader skips a directory called "disabled" at the plugin
# root, whatever its case. Parking a plugin there rather than deleting it is
# what keeps the spawns edited in game and the configs CounterStrikeSharp
# generates on first load and never rewrites.
park() {
	local name="$1" plugin

	[[ -f "${STATE}/${name}.plugins" ]] || return 0
	while IFS= read -r plugin; do
		[[ -n "$plugin" && -d "${PLUGINS}/${plugin}" ]] || continue
		mkdir -p "$DISABLED"
		rm -rf "${DISABLED:?}/${plugin}"
		mv "${PLUGINS}/${plugin}" "${DISABLED}/${plugin}"
		log "disabled ${plugin}"
	done <"${STATE}/${name}.plugins"
}

# ChatControl is in no mode's list, so it is never parked.
activate() {
	local component

	log "mode: ${MODE}"
	for component in matchzy retakes instadefuse allocator; do
		case "${MODE}:${component}" in
			matchzy:matchzy|retakes:retakes|retakes:instadefuse|retakes:allocator) continue ;;
		esac
		park "$component"
	done
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
	local label servername="${CS2_SERVERNAME:-CS2}"

	case "$MODE" in
		matchzy) label="MatchZy" ;;
		retakes) label="Retakes" ;;
		*) label="ChatControl" ;;
	esac

	mkdir -p "${CSGO}/cfg"
	{
		# The image templates CS2_SERVERNAME into cfg/server.cfg, which runs
		# before gamemode_competitive_server.cfg execs this file, so this
		# hostname wins -- which is what puts the mode in the server browser
		# without recreating the container.
		printf 'hostname "%s | %s"\n' "${servername//\"/}" "$label"
		printf 'chatcontrol_everyone_is_admin 1\n'
		if [[ "$MODE" == "matchzy" ]]; then
			printf 'matchzy_everyone_is_admin true\n'
		fi
	} >"${CSGO}/cfg/${CONVAR_CFG}"

	# Two call sites on purpose: CounterStrikeSharp gives no load-order guarantee,
	# so the convars are applied both when MatchZy loads and on every map load.
	# MatchZy's archive overwrites its own config.cfg, hence re-applying here.
	# The rest of the game convars in retakes mode are retakes' own
	# cfg/cs2-retakes/retakes.cfg, which it fills in only when the file does not
	# already exist, so nothing here may create or touch it.
	exec_convars_from "${CSGO}/cfg/MatchZy/config.cfg"
	exec_convars_from "${CSGO}/cfg/gamemode_competitive_server.cfg"
}

failed=0
resolve_mode
restore_all || failed=1
sync_metamod || keep_installed metamod || failed=1
sync_release counterstrikesharp roflmuffin/CounterStrikeSharp \
	'^counterstrikesharp-with-runtime-linux-.*\.zip$' "$CSGO" ||
	keep_installed counterstrikesharp || failed=1
# The plugin-only asset, not MatchZy-*-with-cssharp-*: that bundle pins an older
# CounterStrikeSharp than ChatControl requires.
sync_release matchzy shobhit-pathak/MatchZy \
	'^MatchZy-[0-9.]+\.zip$' "$CSGO" ||
	keep_installed matchzy || failed=1
# The plain asset, not RetakesPlugin-*-no-map-configs: the map configs are the
# spawns, so an update replaces spawns edited in game with upstream's.
sync_release retakes B3none/cs2-retakes \
	'^RetakesPlugin-[0-9.]+\.zip$' "$CSGO" ||
	keep_installed retakes || failed=1
sync_release instadefuse B3none/cs2-instadefuse \
	'^cs2-instadefuse-.*\.zip$' "$PLUGINS" ||
	keep_installed instadefuse || failed=1
sync_release allocator Micka2302/cs2-retakes-allocator-2.0 \
	'^RetakesAllocator\.zip$' "${CSGO}/addons/counterstrikesharp" ||
	keep_installed allocator || failed=1
sync_release chatcontrol timche/cs2-chat-control \
	'^ChatControl-.*\.zip$' "$PLUGINS" ||
	keep_installed chatcontrol || failed=1
register_metamod || failed=1
# After the syncs, so a CounterStrikeSharp reinstall cannot undo them.
configure_retakes || failed=1
configure_admins || failed=1
activate || failed=1
configure || failed=1

if (( failed )); then
	exit 1
fi
log "ready"
) || echo "[cs2] WARNING: plugin setup did not finish, starting the server anyway"
