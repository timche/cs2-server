# Tailscale proxy

Runs a CS2 server at home without opening a port there. A VPS with a public IP forwards the game port to the home machine over Tailscale, so players connect to the VPS and the home firewall stays shut. It is kernel NAT through nftables, no relay process: the VPS rewrites each packet's destination to the server's Tailscale IP and its source to its own, and the replies come back the same way.

## Install

On the VPS, which needs `nftables`, `tailscale` and systemd and has to be on the same tailnet as the server:

```sh
curl -fsSL https://raw.githubusercontent.com/timche/cs2-server/main/proxy/install.sh | bash
```

It asks for the server's Tailscale IP, the port players connect to, the game port on the server, an optional GOTV port and the public interface, writes `cs2-proxy/proxy.env` and turns the forwarding on. Set `DIR` to install somewhere else. The script uses `sudo` for the parts that need root.

## Operating it

```sh
cs2-proxy/proxy.sh status      # what is loaded, and whether the server answers over Tailscale
cs2-proxy/proxy.sh disable     # unload the rules and stop loading them at boot
cs2-proxy/proxy.sh enable      # load them again
cs2-proxy/proxy.sh configure   # change the answers
```

`enable` writes `/etc/systemd/system/cs2-proxy.service`, which loads the rules after Tailscale is up on every boot, and `/etc/sysctl.d/99-cs2-proxy.conf`, which keeps IP forwarding on. `disable` removes both and the nftables table. Nothing else on the machine is touched: the rules live in their own table, `inet cs2proxy`, so they never collide with an existing firewall.

## What to expect

- **Every player has the VPS's Tailscale IP** as far as the server can tell. IP bans, per-IP connection limits and IP whitelists in MatchZy no longer separate players. Keep the server password on.
- **Latency** is the player's path to the VPS plus the WireGuard hop to home. Pick a VPS near the players.
- **The server browser shows the VPS**, because that is where the packets come from. Steam's game server login token works as before.
- **Docker on the VPS** sets the iptables forward policy to drop. The script adds accept rules to Docker's `DOCKER-USER` chain when that chain exists, and removes them on `disable`.
- **Tailscale ACLs** have to allow the VPS to reach the server on the game port. The default policy does.

## Home side

The server binds as usual; nothing has to change in the `matchzy/` setup. Make sure the home firewall allows the game port on `tailscale0`, which it does by default, since Tailscale traffic is not the internet.
