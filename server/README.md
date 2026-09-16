# CS2 server

A Counter-Strike 2 dedicated server that plays three ways and switches between them from a web panel: the [joedwards32/CS2](https://github.com/joedwards32/CS2) image under Docker Compose, with [MatchZy](https://github.com/shobhit-pathak/MatchZy), [cs2-retakes](https://github.com/B3none/cs2-retakes), [cs2-instadefuse](https://github.com/B3none/cs2-instadefuse), [RetakesAllocator](https://github.com/Micka2302/cs2-retakes-allocator-2.0) and [ChatControl](https://github.com/timche/cs2-chat-control) installed on top. Every plugin is installed at all times; the mode decides which of them run.

## Install

On a VPS with Docker:

```sh
curl -fsSL https://raw.githubusercontent.com/timche/cs2-server/main/server/install.sh | bash
```

It asks for a server name, a server password, an RCON password, a [game server login token](https://steamcommunity.com/dev/managegameservers) (app ID 730), a game port, a player limit, your Steam64 ID, the mode to start in, a panel password and port and an optional Cloudflare tunnel token, writes `cs2-server/.env` and starts the server. Set `DIR` to install somewhere else.

Requirements: 2 CPUs, 2 GiB RAM and 60 GB of free disk. The first start downloads the whole game, which takes a while.

The server's files live next to `docker-compose.yml`: the game and the plugins in `data/`, the mode file the panel writes in `control/`. The server runs as uid 1000 inside the container and a bind-mounted folder keeps the ownership it has on the host, so `data/` must belong to uid 1000 or SteamCMD cannot write to it. The installer says so and prints the `chown` when you are not uid 1000 yourself. Removing a server is deleting its folder.

To do it by hand instead, copy `docker-compose.yml`, `pre.sh` and `.env.example` into a directory, fill in `.env`, create `data/` and `control/` and run `docker compose up -d`.

## Modes

| Mode | What runs |
| --- | --- |
| `matchzy` | MatchZy: practice, and 5v5 pug matches when everyone readies up |
| `retakes` | cs2-retakes, cs2-instadefuse and RetakesAllocator: Ts hold a planted bomb, CTs retake the site, everyone picks their own loadout |
| `chatcontrol` | Neither, so plain competitive |

ChatControl, Metamod:Source and CounterStrikeSharp run in every mode.

The mode shows in the server name, as `<your server name> | MatchZy`, `| Retakes` or `| ChatControl`, so the server browser says which one is on.

## Switching modes

The panel writes the mode into `control/mode` and restarts the server, which takes about a minute: every container start runs SteamCMD, and even a no-op update check is not instant. Players are disconnected for that minute, and the plugins of the other modes are only parked, never removed — retakes keeps the spawns you edited in game, MatchZy keeps its configuration.

`CS2_MODE` in `.env` is the mode to come up in before the panel has ever been used. Once `control/mode` exists, that file wins and `CS2_MODE` is ignored.

## The panel

The panel is published on `127.0.0.1:8080` and nowhere else, and asks for `PANEL_PASSWORD` before it does anything. That password is what stands between whoever reaches it and the mode switch, so treat it as you would the RCON password. `PANEL_SECRET` signs the login sessions: change it and everyone is logged out.

To reach it from the machine you are sitting at, tunnel SSH to it:

```sh
ssh -N -L 8080:127.0.0.1:8080 <server-ip>
```

### Over a Cloudflare tunnel

`docker compose --profile tunnel up -d`, or `COMPOSE_PROFILES=tunnel` in `.env`, starts a `cloudflared` container that connects out to Cloudflare, so the panel gets a hostname you own without an open port. In Cloudflare Zero Trust, go to Networks → Tunnels, create a tunnel, route its public hostname to `http://panel:8080` — that is the panel's address on the compose network — and put the token it gives you in `TUNNEL_TOKEN`.

`TUNNEL_TOKEN` is the one value in `.env` allowed to contain a slash: Cloudflare's tokens are base64, and the image's config templating only touches the `CS2_*` and `TV_*` values.

Cloudflare Access can be layered in front of that hostname to demand a Google or GitHub login before the panel is reachable at all. The panel password stays the backstop either way.

## Who is an admin

There are two separate admin systems here, and they do not overlap.

`chatcontrol_everyone_is_admin` is on in every mode, and `matchzy_everyone_is_admin` in matchzy mode, so any player can start matches, change the map and run server commands from chat. ChatControl's `.rcon` command has no filter, which means an unpassworded server hands its console to whoever joins. Keep a server password set.

The retakes plugins ask CounterStrikeSharp instead, which knows only the Steam64 IDs in `RETAKES_ADMIN_STEAM_IDS`. Those get `@css/root`, and nothing else does: without an entry there, nobody can edit spawns, force a bombsite or scramble the teams — not even through `.rcon`, since those commands need a player to have issued them. Add IDs comma-separated and restart.

## Using it

ChatControl is always there: `.map de_dust2` changes map, `.rcon <command>` runs a server command, and `.aim` and `.aimpistol` load the aim presets.

In matchzy mode the server starts in normal competitive play. `.prac` opens practice mode, with grenade spawns, bot placement and noclip; `.exit` leaves it again. For a match, everyone types `.ready` and MatchZy runs the knife round and the map itself.

| Command | What it does |
| --- | --- |
| `.ready` / `.unready` | Ready up for a match |
| `.start` | Start a match once both teams are ready |
| `.stop` | Restore the current round |
| `.pause` / `.unpause` | Pause and resume |
| `.prac` | Practice mode |
| `.exit` | Leave practice or match mode |

The [MatchZy docs](https://shobhit-pathak.github.io/MatchZy/) cover match configs, knife rounds and demo uploads.

In retakes mode the server starts a round with the bomb already planted, Ts defending and CTs retaking, teams and sites picked for you. Type `guns` to open the loadout menu.

| Command | What it does |
| --- | --- |
| `guns` | Loadout menu: primary, secondary, sniper, Zeus |
| `!awp` / `!ssg` | Sniper preference, applied next round |
| `!gun <weapon>` | Set one weapon without the menu |
| `!nextround` | Vote on the next round type |
| `!voices` | Mute the bombsite announcements |

Admin commands, for the Steam64 IDs in `RETAKES_ADMIN_STEAM_IDS`:

| Command | What it does |
| --- | --- |
| `!showspawns <A/B>` | Open the spawn editor on a site |
| `!addspawn <CT/T> <Y/N>` | Add a spawn where you stand, `Y` if it can plant |
| `!removespawn` | Remove the nearest spawn |
| `!hidespawns` | Leave the spawn editor |
| `!forcebombsite <A/B>` | Play one site only, `!forcebombsitestop` to undo |
| `!scramble` | Scramble the teams next round |
| `!setnextround <P/H/F>` | Pistol, half-buy or full-buy next round |

Spawns live in `data/game/csgo/addons/counterstrikesharp/plugins/RetakesPlugin/map_config/`, one file per map, and a cs2-retakes update replaces them with upstream's. Copy anything you edited in game out of there first.

## Operating it

```sh
docker compose logs -f                  # watch the server
docker compose restart                  # restart it
docker compose up -d --force-recreate   # restart and update the plugins
docker compose down                     # stop it
```

## Match demos

GOTV is on, so MatchZy records each pug match to `data/game/csgo/MatchZy/`. Set `TV_ENABLE=0` in `.env` to turn it off; `TV_AUTORECORD` stays off either way, since MatchZy starts recording itself.

## How the plugins get installed

`pre.sh` is mounted into the container and run by the image on every start, after SteamCMD has updated the game and before the server launches. It installs the latest Metamod:Source, CounterStrikeSharp, MatchZy, cs2-retakes, cs2-instadefuse, RetakesAllocator and ChatControl, skipping anything already at that version, adds Metamod to the search paths in `gameinfo.gi`, writes the admin list, moves the plugins the mode does not want into `plugins/disabled/` — where CounterStrikeSharp's loader ignores them — and writes `cfg/cs2-server.cfg` with the mode's convars and the server name.

Running after SteamCMD is what makes this work: CS2 updates replace `gameinfo.gi`, so Metamod has to be registered again on every boot. If a download fails, the server starts with the plugins it already has. Everything parked is brought back before the updates run, so a mode you have not played in a month is still up to date when you switch to it.

CounterStrikeSharp is installed separately and at latest, rather than taking MatchZy's `-with-cssharp` bundle, because that bundle pins an older version than ChatControl and cs2-retakes need.

## Configuration

Everything in `.env` is passed to the image; its [README](https://github.com/joedwards32/CS2) lists the full set of variables. Values must not contain a slash, which the image's config templating cannot handle — `TUNNEL_TOKEN` excepted, since the templating never touches it.

| Key | What it is |
| --- | --- |
| `SRCDS_TOKEN` | [Game server login token](https://steamcommunity.com/dev/managegameservers) for app ID 730. Without one the server stays out of the server browser. |
| `CS2_SERVERNAME` | Server name; the mode is appended to it. |
| `CS2_PW`, `CS2_RCONPW` | Server and RCON passwords. |
| `CS2_MODE` | Mode to start in before the panel has written one. |
| `RETAKES_ADMIN_STEAM_IDS` | Steam64 IDs that get `@css/root`, comma-separated. |
| `CS2_PORT`, `CS2_MAXPLAYERS` | Game port, and server slots. How many of the slots play in retakes mode is cs2-retakes' own `MaxPlayers` (9 by default, 10 at most), with the rest waiting in the queue. |
| `TV_ENABLE`, `TV_PORT` | GOTV, which is how MatchZy records demos. |
| `CS2_LOG` | Server logging, off unless you are chasing a problem. |
| `PANEL_PORT`, `PANEL_PASSWORD`, `PANEL_SECRET` | The panel's port on `127.0.0.1`, its password and its session key. |
| `COMPOSE_PROFILES`, `TUNNEL_TOKEN` | `tunnel` starts `cloudflared` with the token. |

The plugins keep their configuration in `data/game/csgo/addons/counterstrikesharp/configs/plugins/`, each file generated on first load. Two exceptions are written by `pre.sh` on every start and will lose hand edits to those keys:

- `RetakesPlugin/RetakesPlugin.json` gets `GameSettings.EnableFallbackAllocation` set to `false`, because otherwise cs2-retakes and RetakesAllocator both hand out weapons. Everything else in that file is yours. CounterStrikeSharp writes the file whole on first load, so the [cs2-retakes README](https://github.com/B3none/cs2-retakes) is the list of what the other keys do.
- `configs/admins.json` gets an `@css/root` entry per ID in `RETAKES_ADMIN_STEAM_IDS`. Entries added by hand are kept.

Game convars in retakes mode are cs2-retakes': it writes `cfg/cs2-retakes/retakes.cfg` on first load and execs it on every map start. Edit that file to change round time, freeze time or the round limit. Do not use `cfg/server.cfg`, which the image overwrites on every start; `cfg/cs2-server.cfg` is `pre.sh`'s and is overwritten too.
