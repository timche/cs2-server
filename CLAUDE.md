# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A deployable CS2 dedicated server that runs one of three plugin modes at a time, plus a web panel that switches between them. `server/` is the [joedwards32/CS2](https://github.com/joedwards32/CS2) image under Docker Compose with plugins layered on: `matchzy` mode runs [MatchZy](https://github.com/shobhit-pathak/MatchZy) for practice and pugs, `retakes` mode runs cs2-retakes, cs2-instadefuse and RetakesAllocator, and `chatcontrol` mode runs neither. [ChatControl](https://github.com/timche/cs2-chat-control) is in all three. `proxy/` is unrelated: nftables rules for a VPS that forwards the game port to a machine on a tailnet. Deploy with `curl -fsSL https://raw.githubusercontent.com/timche/cs2-server/main/<folder>/install.sh | bash`.

Everything but the panel is shell scripts and a compose file served raw from GitHub — no dependency manifest, no test suite. `server/panel/` is the one compiled thing: a Go program, standard library only, built by `.github/workflows/panel.yml` and pulled from `ghcr.io/timche/cs2-server/panel:main`, so a change to it reaches a server through a push and a `docker compose pull`, not through the raw-file install. The install URL is hardcoded in each folder's `install.sh` and README, so a repo rename means updating every one of them, and the image name in `docker-compose.yml` and the workflow too.

## Verifying changes

```sh
bash -n server/install.sh server/pre.sh        # no shellcheck in this environment

# pre.sh against a fake server tree: installs for real, ~75 MB
mkdir -p /tmp/fake/game/csgo
printf '"GameInfo"\n{\n\tFileSystem\n\t{\n\t\tSearchPaths\n\t\t{\n\t\t\tGame\tcsgo\n\t\t}\n\t}\n}\n' > /tmp/fake/game/csgo/gameinfo.gi
STEAMAPPDIR=/tmp/fake CS2_MODE=retakes bash server/pre.sh     # rerun: idempotent, no duplicate exec lines
STEAMAPPDIR=/tmp/fake CS2_MODE=matchzy bash server/pre.sh     # the switch: check plugins/ against plugins/disabled/
STEAMAPPDIR=/tmp/fake https_proxy=http://127.0.0.1:1 CS2_MODE=retakes bash server/pre.sh   # keeps what is installed, still switches

cp server/.env.example server/.env && (cd server && docker compose config)

cd server/panel && gofmt -l . && go vet ./... && go test ./...
```

A full run resolves seven releases through the unauthenticated GitHub API, which allows 60 an hour — a few runs in a row hit the limit and every download comes back 403.

`install.sh` reads its answers from `/dev/tty`, so piping answers into it does nothing — drive it through a pty (`python3 -c` with the `pty` module) and point `BASE_URL` at `file:///…/server` so it copies the working tree instead of fetching from GitHub. `REPO`, `REF` and `DIR` are the other overrides.

## Why the design is what it is

The base image re-runs SteamCMD on every container start and its `entry.sh` `source`s `pre.sh` from the server folder afterwards, just before launching the server. That single hook is why everything works the way it does:

- **`pre.sh` must never call `exit` at the top level.** Being sourced, an exit takes the server process with it. The whole body is a subshell whose failure is only logged.
- **The `gameinfo.gi` Metamod search path is re-applied on every boot**, because CS2 updates replace that file. Nothing that runs before SteamCMD — a derived image, an init container — can do this.
- **Plugin convars cannot live in `cfg/server.cfg`**, which the image overwrites each start. They go in a generated `cfg/cs2-server.cfg`, exec'd from `cfg/gamemode_competitive_server.cfg` (every map load) and from `cfg/MatchZy/config.cfg` (MatchZy load time), because CounterStrikeSharp gives no plugin load-order guarantee.
- The image ships `curl`, `wget`, `unzip` and `jq` and runs as uid 1000, so the hook can do the installs itself.

**Every plugin is installed in every mode; only the enabled set differs.** CounterStrikeSharp's loader skips a directory called `disabled` at the plugin root, whatever its case, so a mode switch is a `mv` in and out of `addons/counterstrikesharp/plugins/disabled/`. Parking rather than deleting is what keeps retakes spawns edited in game and the JSON configs CounterStrikeSharp generates on first plugin load and never rewrites.

The order in `pre.sh` carries the whole design: `restore_all` unparks everything *before* the syncs, so an update reaches the modes nobody is playing and a later switch waits on no download; `activate` parks again at the end. Between them, `sync()` records the plugin directories each component brought in a `${STATE}/<name>.plugins` stamp, discovered by walking the unpacked archive rather than written down, because the archives unpack at three different roots and because the allocator turns out to ship a second plugin, `SharpModMenu`. The `chmod -R u+rwX` has to happen before that walk: the allocator's directory entries carry no execute bit and `find` cannot descend into them.

Versions are resolved at boot from GitHub `releases/latest` and the AlliedModders `mmsource-latest-linux` pointer, with a stamp file per component under `$STEAMAPPDIR/.cs2/`. A failed lookup keeps the installed version rather than taking the server down.

**CounterStrikeSharp is installed separately, at latest, and MatchZy comes from its plugin-only asset.** MatchZy's `-with-cssharp` bundle pins CSSharp 1.0.342; ChatControl requires ≥ 1.0.371. MatchZy has not published a release against current CSSharp, which is the one untested seam in the stack — check `docker compose logs` if MatchZy stops loading.

### The panel

`server/panel/` writes the mode and restarts the server, and does it with no privileges at all. There is no Docker socket and there must not be one: it writes `control/mode` and sends `quit` over Source RCON, and because `entry.sh` runs `cs2.sh` rather than `exec`ing it, the container exits and `restart: unless-stopped` starts it again, at which point `pre.sh` reads the new mode. The cost is that a game server too wedged to answer RCON needs a manual `docker compose restart cs2`; the panel says so rather than pretending.

- **The mode file is the source of truth, `CS2_MODE` only the fallback.** `.env` seeds the mode for the first boot because nothing can write into the folder before `docker compose up`; once the panel has written `control/mode`, that wins and the env value is stale. `pre.sh` treats an unrecognised value as absent and warns.
- **`control/` is mounted read-only into the game server and read-write into the panel**, at a path inside `data/`'s mount point, so `pre.sh` reads a plain file under `$STEAMAPPDIR` while the panel is confined to that one directory.
- **The panel's scratch image runs as root** so it can write the mode file whoever owns `control/` on the host, and carries no CA bundle because nothing in it makes an outbound TLS connection.
- **It trusts `X-Forwarded-Proto` for the `Secure` cookie flag**, which is only safe because it publishes on `127.0.0.1` and is reached through the tunnel. Publishing it on a real interface would make that header attacker-controlled.
- The session is a signed cookie with no server-side store, keyed by `PANEL_SECRET` — changing that value logs everyone out.

### Cloudflare tunnel

`cloudflared` runs under a compose profile, started by `COMPOSE_PROFILES=tunnel`, with a dashboard-issued `TUNNEL_TOKEN`; the public hostname is routed to `http://panel:8080` in Cloudflare Zero Trust, not in this repo. **`TUNNEL_TOKEN` is the one exception to the no-slash rule** below — Cloudflare's tokens are base64 — which is safe because the image's `sed` templating only touches the `CS2_*` and `TV_*` values, and why `install.sh` must not put that prompt through `ask_without_slash`.

The GHCR package is private until someone flips it to public once by hand, or `docker compose pull` on a fresh server cannot find the image.

### retakes mode only

- **Admin is two systems that do not overlap.** `chatcontrol_everyone_is_admin` bypasses ChatControl's own check before CounterStrikeSharp is ever consulted. Retakes and the allocator instead ask `AdminManager.PlayerHasPermissions`, which knows only `addons/counterstrikesharp/configs/admins.json` — hence `RETAKES_ADMIN_STEAM_IDS` and the Steam64 ID prompt. There is no wildcard identity, and `.rcon css_addspawn` is no way round it: those handlers bail when no player issued the command.
- **`cfg/cs2-retakes/retakes.cfg` is the plugin's to create.** `ServerHelper.ExecuteRetakesConfiguration` writes it only `if (!File.Exists(...))`, so creating, touching or appending to it from `pre.sh` leaves the server on stock competitive convars.
- **`GameSettings.EnableFallbackAllocation` must be `false`** or retakes and the allocator both hand out weapons. CounterStrikeSharp generates `configs/plugins/RetakesPlugin/RetakesPlugin.json` on first plugin load and never rewrites it, so `pre.sh` owns that one key and every key it leaves out takes the plugin's default. The generated file opens with a `//` comment line, which `jq` will not parse.
- **The allocator's zip was built on Windows.** Its paths use backslash separators, which Info-ZIP translates but exits 1 to warn about, so `sync()` treats only status > 1 as failure.

**The allocator is built against CounterStrikeSharp 1.0.367 on net8.0 and ships its own `RetakesPluginShared.dll` (2.0.0) inside its plugin folder, while retakes 3.1.0 is net10.0 against 1.0.369 and installs the same library to `addons/counterstrikesharp/shared/`.** Current CounterStrikeSharp (1.0.374, .NET 10.0.3) loads both. If that duplicate shared assembly ever stops resolving to one type, the symptom is the allocator logging that it cannot get the `retakes_plugin:event_sender` capability while retakes itself runs fine.

## Conventions

Values in `.env` must not contain a slash: the image templates them into its configs with `sed`. `install.sh` re-prompts when one appears. `TUNNEL_TOKEN` is exempt, as above.

The server's files are bind-mounted from `data/` next to the compose file rather than a named volume, so **`data/` must be owned by uid 1000** or SteamCMD cannot write the game files. `install.sh` creates it and, when the installing user is not uid 1000, prints the `chown` for them to run instead of starting a stack that would fail.

Every mode runs ChatControl with everyone-is-admin on, which hands every player its unfiltered `.rcon`, and the panel's password is the only thing between whoever reaches it and the mode switch. Each installer defaults both the server password and the panel password to a generated one and warns when the server password is cleared — keep that posture in any change to the prompts.
