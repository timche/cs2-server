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
- **The `gameinfo.gi` Metamod search path is re-applied on every boot**, because CS2 updates replace that file. Valve ships it with CRLF endings, so the `sed` has to match and carry the carriage return: anchoring on `csgo$` matches nothing, and the only symptom is that no plugin loads at all. Nothing that runs before SteamCMD — a derived image, an init container — can do this.
- **Plugin convars cannot live in `cfg/server.cfg`**, which the image overwrites each start. They go in a generated `cfg/cs2-server.cfg`, exec'd from `cfg/gamemode_competitive_server.cfg` (every map load) and from `cfg/MatchZy/config.cfg` (MatchZy load time), because CounterStrikeSharp gives no plugin load-order guarantee.
- The image ships `curl`, `wget`, `unzip` and `jq` and runs as uid 1000, so the hook can do the installs itself.

**MatchZy and ChatControl both register `css_map` and `css_rcon`**, and CounterStrikeSharp dispatches a shared command name to every plugin that registered it, so running both stock makes `.rcon` execute the server command twice. `configure_chatcontrol` owns `MapCommandName` and `RconCommandName` for that reason: `wmap` and `""` in matchzy mode, the defaults in the other two, written every boot because a switch away has to put the names back. Seeding those two keys before the plugin's first load is safe — CounterStrikeSharp deserializes whatever file exists and only generates one when none does, so every key left out keeps the plugin's default.

**Every plugin is installed in every mode; only the enabled set differs.** CounterStrikeSharp's loader skips a directory called `disabled` at the plugin root, whatever its case, so a mode switch is a `mv` in and out of `addons/counterstrikesharp/plugins/disabled/`. Parking rather than deleting is what keeps retakes spawns edited in game and the JSON configs CounterStrikeSharp generates on first plugin load and never rewrites.

The order in `pre.sh` carries the whole design: `restore_all` unparks everything *before* the syncs, so an update reaches the modes nobody is playing and a later switch waits on no download; `activate` parks again at the end. Between them, `sync()` records the plugin directories each component brought in a `${STATE}/<name>.plugins` stamp, discovered by walking the unpacked archive rather than written down, because the archives unpack at three different roots and because the allocator turns out to ship a second plugin, `SharpModMenu`. The `chmod -R u+rwX` has to happen before that walk: the allocator's directory entries carry no execute bit and `find` cannot descend into them.

Versions are resolved at boot from GitHub `releases/latest`, with a stamp file per component under `$STEAMAPPDIR/.cs2/`. A failed lookup keeps the installed version rather than taking the server down.

**Metamod is the exception: it is pinned to build 1411, not `mmsource-latest-linux`.** Build 1461 raised the SourceHook interface to 18 and CounterStrikeSharp 1.0.374 is built against 17, so a newer Metamod refuses to load it and the server comes up with `[META] Loaded 0 plugins` — which reads like every plugin failing rather than Metamod turning CounterStrikeSharp away, and leaves no `addons/counterstrikesharp/logs/` at all. Older is no escape either: below 1411 the game segfaults on current CS2. `METAMOD_BUILD` overrides the pin and `latest` goes back to the pointer, which is what to do once CounterStrikeSharp ships against 18 — [CounterStrikeSharp#1415](https://github.com/roflmuffin/CounterStrikeSharp/issues/1415) is where that is tracked.

**CounterStrikeSharp is installed separately, at latest, and MatchZy comes from its plugin-only asset.** MatchZy's `-with-cssharp` bundle pins CSSharp 1.0.342; ChatControl requires ≥ 1.0.371. MatchZy has not published a release against current CSSharp, which is the one untested seam in the stack — check `docker compose logs` if MatchZy stops loading.

### The panel

`server/panel/` writes the mode and restarts the server, and does it with no privileges at all. There is no Docker socket and there must not be one: it writes `control/mode` and sends `quit` over Source RCON, and because `entry.sh` runs `cs2.sh` rather than `exec`ing it, the container exits and `restart: unless-stopped` starts it again, at which point `pre.sh` reads the new mode. The cost is that a game server too wedged to answer RCON needs a manual `docker compose restart cs2`; the panel says so rather than pretending.

- **The mode file is the source of truth, `CS2_MODE` only the fallback.** `install.sh` seeds `control/mode` with the mode it asked for, because the panel has no Docker socket and never reads `.env`: without that file it reports "Mode unknown" against a perfectly healthy server until someone switches. `CS2_MODE` stays as the fallback for a hand-built install. A rerun of the installer carries the mode file's value forward, not `.env`'s, which goes stale the moment the panel writes one. `pre.sh` treats an unrecognised value as absent and warns.
- **`control/` is mounted read-only into the game server and read-write into the panel**, at a path inside `data/`'s mount point, so `pre.sh` reads a plain file under `$STEAMAPPDIR` while the panel is confined to that one directory.
- **The panel's scratch image runs as root** so it can write the mode file whoever owns `control/` on the host, and carries no CA bundle because nothing in it makes an outbound TLS connection.
- **The panel publishes no port when a tunnel is configured**, `cloudflared` reaching it at `panel:8080` on the compose network; `install.sh` writes a `docker-compose.override.yml` publishing `127.0.0.1:${PANEL_PORT}` only when there is no tunnel, and removes it when a rerun adds one. Keeping the publish out of `docker-compose.yml` is what stops it colliding with whatever else holds 8080 on the host, and what keeps a hand-edit from being overwritten on the next install.
- **It trusts `X-Forwarded-Proto` for the `Secure` cookie flag**, which is only safe because it is never published on a real interface — on 127.0.0.1 or not at all. Publishing it outward would make that header attacker-controlled.
- The session is a signed cookie with no server-side store, keyed by `PANEL_SECRET` — changing that value logs everyone out.
- **The command list in `commands.go` is written by hand, from the plugins' own docs**, and shown for whichever mode the radio has selected rather than the one running — the panel is where someone decides what to switch to. `page.html` reveals one mode's block with a `main:has(#mode-<name>:checked)` rule generated per mode, so the list needs no JavaScript and no round trip. A plugin that renames or drops a command does not announce it; `server/README.md` carries the same commands and the two are updated together.

### Cloudflare tunnel

`cloudflared` runs under a compose profile, started by `COMPOSE_PROFILES=tunnel`, with a dashboard-issued `TUNNEL_TOKEN`; the public hostname is routed to `http://panel:8080` in Cloudflare Zero Trust, not in this repo. **`TUNNEL_TOKEN` is the one exception to the no-slash rule** below — Cloudflare's tokens are base64 — which is safe because the image's `sed` templating only touches the `CS2_*` and `TV_*` values, and why `install.sh` must not put that prompt through `ask_without_slash`.

The GHCR package followed this repository and came out public, so an unauthenticated `docker compose pull` finds it. In a private fork it has to be flipped by hand under Packages → Package settings.

### retakes mode only

- **Admin is two systems that do not overlap.** `chatcontrol_everyone_is_admin` bypasses ChatControl's own check before CounterStrikeSharp is ever consulted. Retakes and the allocator instead ask `AdminManager.PlayerHasPermissions`, which knows only `addons/counterstrikesharp/configs/admins.json` — hence `RETAKES_ADMIN_STEAM_IDS` and the Steam64 ID prompt. There is no wildcard identity, and `.rcon css_addspawn` is no way round it: those handlers bail when no player issued the command.
- **`cfg/cs2-retakes/retakes.cfg` is the plugin's to create.** `ServerHelper.ExecuteRetakesConfiguration` writes it only `if (!File.Exists(...))`, so creating, touching or appending to it from `pre.sh` leaves the server on stock competitive convars.
- **`GameSettings.EnableFallbackAllocation` must be `false`** or retakes and the allocator both hand out weapons. CounterStrikeSharp generates `configs/plugins/RetakesPlugin/RetakesPlugin.json` on first plugin load and never rewrites it, so `pre.sh` owns that one key and every key it leaves out takes the plugin's default. The generated file opens with a `//` comment line, which `jq` will not parse.
- **The allocator's zip was built on Windows.** Its paths use backslash separators, which Info-ZIP translates but exits 1 to warn about, so `sync()` treats only status > 1 as failure.

**The allocator is built against CounterStrikeSharp 1.0.367 on net8.0 and ships its own `RetakesPluginShared.dll` (2.0.0) inside its plugin folder, while retakes 3.1.0 is net10.0 against 1.0.369 and installs the same library to `addons/counterstrikesharp/shared/`.** Current CounterStrikeSharp (1.0.374, .NET 10.0.3) loads both. If that duplicate shared assembly ever stops resolving to one type, the symptom is the allocator logging that it cannot get the `retakes_plugin:event_sender` capability while retakes itself runs fine.

## Conventions

**`install.sh` is the update path too**, which is why it asks nothing it has already been told. A key present in `.env` — present, not non-empty, so a cleared `CS2_PW` and an empty `TUNNEL_TOKEN` both count as answers — keeps its value and its question is skipped, which makes a rerun an update rather than an interview; deleting the line is how you are asked again. An update therefore asks only which folder, and ends by offering `docker compose up -d --pull always` rather than the first run's start. The one answer that is not a container's is `AUTO_UPDATE`, which records whether a crontab entry restarts the game container at 06:00 — the schedule lives in the installing user's crontab, tagged with the folder so a rerun rewrites one line and leaves other servers' alone, and it is the user's rather than root's because a system timer would want a password this script has no business asking for. `control/mode` is seeded but never rewritten: the panel writes it as root, so on a rerun it is not the installer's to touch, and it is the source of truth for the mode anyway. `.env` is rewritten from the answers, so `carry_over` appends the keys the script does not ask about, and only real `KEY=VALUE` lines, or the file would grow a copy of its own comments on every run.

Values in `.env` must not contain a slash: the image templates them into its configs with `sed`. `install.sh` re-prompts when one appears. `TUNNEL_TOKEN` is exempt, as above.

The server's files are bind-mounted from `data/` next to the compose file rather than a named volume, so **`data/` must be owned by uid 1000** or SteamCMD cannot write the game files. `install.sh` creates it and, when the installing user is not uid 1000, prints the `chown` for them to run instead of starting a stack that would fail.

Every mode runs ChatControl with everyone-is-admin on, which hands every player its unfiltered `.rcon`, and the panel's password is the only thing between whoever reaches it and the mode switch. Each installer defaults both the server password and the panel password to a generated one and warns when the server password is cleared — keep that posture in any change to the prompts.
