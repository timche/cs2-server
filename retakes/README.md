# Retakes CS2 server

A Counter-Strike 2 retakes server: the [joedwards32/CS2](https://github.com/joedwards32/CS2) image under Docker Compose, with [cs2-retakes](https://github.com/B3none/cs2-retakes), [cs2-instadefuse](https://github.com/B3none/cs2-instadefuse), [RetakesAllocator](https://github.com/Micka2302/cs2-retakes-allocator-2.0) and [ChatControl](https://github.com/timche/cs2-chat-control) installed on top. Ts hold a planted bomb, CTs retake the site, everyone picks their own loadout.

## Install

On a VPS with Docker:

```sh
curl -fsSL https://raw.githubusercontent.com/timche/cs2-server/main/retakes/install.sh | bash
```

It asks for a server name, a server password, an RCON password, your Steam64 ID, a [game server login token](https://steamcommunity.com/dev/managegameservers) (app ID 730), a game port and a player limit, writes `cs2-retakes/.env` and starts the server. Set `DIR` to install somewhere else.

Requirements: 2 CPUs, 2 GiB RAM and 60 GB of free disk. The first start downloads the whole game, which takes a while.

To do it by hand instead, copy `docker-compose.yml`, `pre.sh` and `.env.example` into a directory, fill in `.env` and run `docker compose up -d`.

## Who is an admin

There are two separate admin systems here, and they do not overlap.

`chatcontrol_everyone_is_admin` is on, so any player can change the map and run server commands from chat. ChatControl's `.rcon` command has no filter, which means an unpassworded server hands its console to whoever joins. Keep a server password set.

The retakes plugins ask CounterStrikeSharp instead, which knows only the Steam64 IDs in `RETAKES_ADMIN_STEAM_IDS`. Those get `@css/root`, and nothing else does: without an entry there, nobody can edit spawns, force a bombsite or scramble the teams — not even through `.rcon`, since those commands need a player to have issued them. Add IDs comma-separated and restart.

## Using it

The server starts a round with the bomb already planted, Ts defending and CTs retaking, teams and sites picked for you. Type `guns` to open the loadout menu.

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

ChatControl adds `.map de_dust2` to change map, `.rcon <command>` to run a server command, and the `.aim` and `.aimpistol` presets.

Spawns live in `game/csgo/addons/counterstrikesharp/plugins/RetakesPlugin/map_config/` inside the volume, one file per map, and a cs2-retakes update replaces them with upstream's. Copy anything you edited in game out of there first.

## Operating it

```sh
docker compose logs -f                  # watch the server
docker compose restart                  # restart it
docker compose up -d --force-recreate   # restart and update the plugins
docker compose down                     # stop it
```

## How the plugins get installed

`pre.sh` is mounted into the container and run by the image on every start, after SteamCMD has updated the game and before the server launches. It installs the latest Metamod:Source, CounterStrikeSharp, cs2-retakes, cs2-instadefuse, RetakesAllocator and ChatControl, skipping anything already at that version, then adds Metamod to the search paths in `gameinfo.gi`, writes the admin list and `cfg/cs2-server.cfg`.

Running after SteamCMD is what makes this work: CS2 updates replace `gameinfo.gi`, so Metamod has to be registered again on every boot. If a download fails, the server starts with the plugins it already has.

CounterStrikeSharp is installed separately and at latest, because cs2-retakes and ChatControl both need a newer one than any bundle ships.

## Configuration

Everything in `.env` is passed to the image; its [README](https://github.com/joedwards32/CS2) lists the full set of variables. Values must not contain a slash, which the image's config templating cannot handle. `CS2_MAXPLAYERS` is how many slots the server has; how many of them play is cs2-retakes' own `MaxPlayers` (9 by default, 10 at most), with the rest waiting in the queue.

The plugins keep their configuration in `game/csgo/addons/counterstrikesharp/configs/plugins/` inside the volume, each one generated on first load. Two exceptions are written by `pre.sh` on every start and will lose hand edits to those keys:

- `RetakesPlugin/RetakesPlugin.json` gets `GameSettings.EnableFallbackAllocation` set to `false`, because otherwise cs2-retakes and RetakesAllocator both hand out weapons. Everything else in that file is yours. CounterStrikeSharp writes the file whole on first load, so the [cs2-retakes README](https://github.com/B3none/cs2-retakes) is the list of what the other keys do.
- `configs/admins.json` gets an `@css/root` entry per ID in `RETAKES_ADMIN_STEAM_IDS`. Entries added by hand are kept.

Game convars are cs2-retakes': it writes `cfg/cs2-retakes/retakes.cfg` on first load and execs it on every map start. Edit that file to change round time, freeze time or the round limit. Do not use `cfg/server.cfg`, which the image overwrites on every start; `cfg/cs2-server.cfg` is `pre.sh`'s and is overwritten too.

GOTV (`TV_ENABLE`) and server logging (`CS2_LOG`) are both off. Turn `CS2_LOG` on when you are chasing a problem.
