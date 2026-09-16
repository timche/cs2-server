#!/usr/bin/env bash
# Forwards a CS2 server's ports from this machine's public address to a
# server on the tailnet, so the game server itself never opens a firewall port.
#
#   proxy.sh configure   ask the questions, write proxy.env and enable
#   proxy.sh enable      load the rules now and at every boot
#   proxy.sh disable     unload the rules and stop loading them at boot
#   proxy.sh status      show what is active
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${HERE}/proxy.env"
TABLE="cs2proxy"
UNIT="/etc/systemd/system/cs2-proxy.service"
SYSCTL="/etc/sysctl.d/99-cs2-proxy.conf"

say() { printf '%s\n' "$*" >&2; }
fail() { printf '\n%s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || exec sudo -E bash "${BASH_SOURCE[0]}" "$@"

for tool in nft tailscale systemctl; do
	command -v "$tool" >/dev/null || fail "${tool} is not installed."
done

load_config() {
	[[ -f "$CONFIG" ]] || fail "No ${CONFIG}. Run: $0 configure"
	# shellcheck disable=SC1090
	source "$CONFIG"
	: "${TARGET:?}" "${WAN_IF:?}" "${TS_IF:?}" "${GAME_PORT:?}" "${TARGET_PORT:?}"
}

ruleset() {
	local ports="${GAME_PORT}" tv=""
	if [[ -n "${TV_PORT:-}" ]]; then
		tv="iifname \"${WAN_IF}\" udp dport ${TV_PORT} dnat ip to ${TARGET}:${TV_PORT}"
		ports="{ ${GAME_PORT}, ${TV_PORT} }"
	fi
	cat <<EOF
table inet ${TABLE} {
	chain prerouting {
		type nat hook prerouting priority dstnat; policy accept;
		iifname "${WAN_IF}" udp dport ${GAME_PORT} dnat ip to ${TARGET}:${TARGET_PORT}
		iifname "${WAN_IF}" tcp dport ${GAME_PORT} dnat ip to ${TARGET}:${TARGET_PORT}
		${tv}
	}
	chain postrouting {
		type nat hook postrouting priority srcnat; policy accept;
		oifname "${TS_IF}" ip daddr ${TARGET} masquerade
	}
	chain forward {
		type filter hook forward priority filter; policy accept;
		iifname "${WAN_IF}" oifname "${TS_IF}" ip daddr ${TARGET} udp dport ${ports} accept
		iifname "${WAN_IF}" oifname "${TS_IF}" ip daddr ${TARGET} tcp dport ${TARGET_PORT} accept
		iifname "${TS_IF}" oifname "${WAN_IF}" ip saddr ${TARGET} ct state established,related accept
	}
}
EOF
}

# Docker sets the iptables FORWARD policy to DROP, which discards forwarded
# packets before nftables' own verdict counts. DOCKER-USER is its hook for
# rules that should survive that.
docker_user() {
	command -v iptables >/dev/null || return 0
	iptables -S DOCKER-USER >/dev/null 2>&1 || return 0
	local action="$1"
	iptables "$action" DOCKER-USER -i "$WAN_IF" -o "$TS_IF" -d "$TARGET" -j ACCEPT 2>/dev/null || true
	iptables "$action" DOCKER-USER -i "$TS_IF" -o "$WAN_IF" -s "$TARGET" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
}

cmd_up() {
	load_config
	sysctl -q -w net.ipv4.ip_forward=1
	nft delete table inet "$TABLE" 2>/dev/null || true
	ruleset | nft -f -
	docker_user -I
}

cmd_down() {
	load_config
	nft delete table inet "$TABLE" 2>/dev/null || true
	docker_user -D
}

cmd_enable() {
	load_config
	printf 'net.ipv4.ip_forward = 1\n' >"$SYSCTL"
	cat >"$UNIT" <<EOF
[Unit]
Description=Forward CS2 ports to ${TARGET} over Tailscale
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/env bash ${HERE}/proxy.sh up
ExecStop=/usr/bin/env bash ${HERE}/proxy.sh down

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable --now cs2-proxy.service >/dev/null 2>&1
	say "Forwarding ${WAN_IF}:${GAME_PORT} to ${TARGET}:${TARGET_PORT}${TV_PORT:+ and GOTV on ${TV_PORT}}."
}

cmd_disable() {
	if [[ -f "$UNIT" ]]; then
		systemctl disable --now cs2-proxy.service >/dev/null 2>&1 || true
		rm -f "$UNIT"
		systemctl daemon-reload
	fi
	rm -f "$SYSCTL"
	if [[ -f "$CONFIG" ]]; then
		cmd_down
	else
		nft delete table inet "$TABLE" 2>/dev/null || true
	fi
	say "Forwarding is off. ${CONFIG} is kept, so 'enable' brings it back."
	say "IP forwarding stays on until the next reboot, in case something else relies on it."
}

cmd_status() {
	if [[ -f "$UNIT" ]]; then
		say "At boot: enabled ($(systemctl is-active cs2-proxy.service 2>/dev/null || true))"
	else
		say "At boot: not enabled"
	fi
	if nft list table inet "$TABLE" >/dev/null 2>&1; then
		load_config
		say "Now:     forwarding ${WAN_IF}:${GAME_PORT} to ${TARGET}:${TARGET_PORT}${TV_PORT:+, GOTV on ${TV_PORT}}"
		say "Reach:   $(tailscale ping -c 1 --timeout 2s "$TARGET" 2>&1 | tail -1)"
	else
		say "Now:     no rules loaded"
	fi
}

# --- configure -------------------------------------------------------------

saved() {
	local value=""
	if [[ -f "$CONFIG" ]]; then
		value="$(sed -n "s/^${1}=//p" "$CONFIG" | head -1)"
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

ask_number() {
	local value
	while true; do
		value="$(ask "$1" "${2:-}")"
		if [[ "$value" =~ ^[0-9]+$ ]]; then
			break
		fi
		say "Enter a number."
	done
	printf '%s' "$value"
}

ask_ip() {
	local value
	while true; do
		value="$(ask "$1" "${2:-}")"
		if [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
			break
		fi
		say "Enter an IPv4 address."
	done
	printf '%s' "$value"
}

confirm() {
	local answer
	printf '%s [Y/n]: ' "$1" >/dev/tty
	IFS= read -r answer <&3 || answer=""
	[[ ! "$answer" =~ ^[Nn] ]]
}

cmd_configure() {
	[[ -r /dev/tty ]] || fail "No terminal available for the setup questions."
	exec 3</dev/tty

	tailscale status >/dev/null 2>&1 || fail "Tailscale is not up on this machine. Run: tailscale up"

	say "Forwarding a CS2 server through this machine"
	say ""
	say "Peers on the tailnet:"
	tailscale status 2>/dev/null | awk 'NR>1 && $1 ~ /^100\./ { printf "  %-16s %s\n", $1, $2 }' >&2
	say ""

	local target port target_port tv wan_if
	target="$(ask_ip "Tailscale IP of the machine running the server" "$(saved TARGET "")")"
	if ! tailscale ping -c 1 --timeout 3s "$target" >/dev/null 2>&1; then
		say "No answer from ${target} over Tailscale. Continuing anyway; check 'status' afterwards."
	fi
	port="$(ask_number "Port players connect to on this machine" "$(saved GAME_PORT 27015)")"
	target_port="$(ask_number "Game port on the server" "$(saved TARGET_PORT "$port")")"
	tv="$(ask "GOTV port to forward too, or none" "$(saved TV_PORT none)")"
	if [[ "$tv" == "none" ]]; then
		tv=""
	elif [[ ! "$tv" =~ ^[0-9]+$ ]]; then
		fail "The GOTV port has to be a number or 'none'."
	fi
	wan_if="$(ask "Public network interface" "$(saved WAN_IF "$(ip -o route show default | awk '{ print $5; exit }')")")"

	cat >"$CONFIG" <<EOF
TARGET=${target}
TARGET_PORT=${target_port}
GAME_PORT=${port}
TV_PORT=${tv}
WAN_IF=${wan_if}
TS_IF=tailscale0
EOF
	say ""
	say "Wrote ${CONFIG}."

	if ! confirm "Enable the forwarding now?"; then
		say "Enable it later with: $0 enable"
		return
	fi
	cmd_enable
	say ""
	say "Players connect to $(curl -fsS -4 --max-time 3 https://api.ipify.org 2>/dev/null || echo '<this-ip>'):${port}."
	say "The server sees every player as this machine's Tailscale IP, so IP bans"
	say "and the server browser's ping estimate no longer mean much."
}

command="${1:-configure}"
case "$command" in
configure | enable | disable | status | up | down) "cmd_${command}" ;;
*) fail "Usage: $0 {configure|enable|disable|status}" ;;
esac
