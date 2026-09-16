#!/usr/bin/env bash
# Installs and updates Metamod:Source, CounterStrikeSharp, MatchZy and
# ChatControl into the CS2 server, then applies their configuration.
#
# The image's entry.sh *sources* this file after SteamCMD has updated the game
# and before it launches cs2.sh, so it must never call exit at the top level --
# that would take the server down with it. Everything runs in a subshell whose
# failure is only reported. Running after SteamCMD is also what makes this the
# only viable place for the gameinfo.gi patch, which CS2 updates undo.

(
set -euo pipefail

CSGO="${STEAMAPPDIR}/game/csgo"
STATE="${STEAMAPPDIR}/.matchzy"
MMS_DROP="https://mms.alliedmods.net/mmsdrop/2.0"
CONVAR_CFG="cs2-servers.cfg"

log() { echo "[matchzy] $*"; }

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
			*.zip) unzip -q -o "${tmp}/package" -d "$dest" || status=1 ;;
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

configure() {
	mkdir -p "${CSGO}/cfg"
	cat >"${CSGO}/cfg/${CONVAR_CFG}" <<-EOF
		matchzy_everyone_is_admin true
		chatcontrol_everyone_is_admin 1
	EOF

	# Two call sites on purpose: CounterStrikeSharp gives no load-order guarantee,
	# so the convars are applied both when MatchZy loads and on every map load.
	# MatchZy's archive overwrites its own config.cfg, hence re-applying here.
	exec_convars_from "${CSGO}/cfg/MatchZy/config.cfg"
	exec_convars_from "${CSGO}/cfg/gamemode_competitive_server.cfg"
}

failed=0
sync_metamod || keep_installed metamod || failed=1
sync_release counterstrikesharp roflmuffin/CounterStrikeSharp \
	'^counterstrikesharp-with-runtime-linux-.*\.zip$' "$CSGO" ||
	keep_installed counterstrikesharp || failed=1
# The plugin-only asset, not MatchZy-*-with-cssharp-*: that bundle pins an older
# CounterStrikeSharp than ChatControl requires.
sync_release matchzy shobhit-pathak/MatchZy \
	'^MatchZy-[0-9.]+\.zip$' "$CSGO" ||
	keep_installed matchzy || failed=1
sync_release chatcontrol timche/cs2-chat-control \
	'^ChatControl-.*\.zip$' "${CSGO}/addons/counterstrikesharp/plugins" ||
	keep_installed chatcontrol || failed=1
register_metamod || failed=1
configure

if (( failed )); then
	exit 1
fi
log "ready"
) || echo "[matchzy] WARNING: plugin setup did not finish, starting the server anyway"
