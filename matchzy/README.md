# MatchZy CS2 server

A Counter-Strike 2 dedicated server for practice, ready to run 5v5 pug matches when you want one: the [joedwards32/CS2](https://github.com/joedwards32/CS2) image under Docker Compose, with [MatchZy](https://github.com/shobhit-pathak/MatchZy) and [ChatControl](https://github.com/timche/cs2-chat-control) installed on top and every player made an admin.

## Install

On a VPS with Docker:

```sh
curl -fsSL https://raw.githubusercontent.com/timche/cs2-servers/main/matchzy/install.sh | bash
```

It asks for a server name, a server password, an RCON password, a [game server login token](https://steamcommunity.com/dev/managegameservers) (app ID 730), a game port and a player limit, writes `cs2-matchzy/.env` and starts the server. Set `DIR` to install somewhere else.

Requirements: 2 CPUs, 2 GiB RAM and 60 GB of free disk. The first start downloads the whole game, which takes a while.

To do it by hand instead, copy `docker-compose.yml`, `pre.sh` and `.env.example` into a directory, fill in `.env` and run `docker compose up -d`.

## Everyone is an admin

`matchzy_everyone_is_admin` and `chatcontrol_everyone_is_admin` are both on, so any player can start matches, change the map and run server commands from chat. ChatControl's `.rcon` command has no filter, which means an unpassworded server hands its console to whoever joins. Keep a server password set.

## Using it

The server starts in normal competitive play. `.prac` opens practice mode, with grenade spawns, bot placement and noclip; `.exit` leaves it again. For a match, everyone types `.ready` and MatchZy runs the knife round and the map itself.

MatchZy commands in chat, all available to everyone:

| Command | What it does |
| --- | --- |
| `.ready` / `.unready` | Ready up for a match |
| `.start` | Start a match once both teams are ready |
| `.stop` | Restore the current round |
| `.pause` / `.unpause` | Pause and resume |
| `.prac` | Practice mode |
| `.exit` | Leave practice or match mode |

ChatControl adds `.map de_dust2` to change map, `.rcon <command>` to run a server command, and the `.aim` and `.aimpistol` presets. The [MatchZy docs](https://shobhit-pathak.github.io/MatchZy/) cover match configs, knife rounds and demo uploads.

## Operating it

```sh
docker compose logs -f                  # watch the server
docker compose restart                  # restart it
docker compose up -d --force-recreate   # restart and update the plugins
docker compose down                     # stop it
```

## Match demos

GOTV is off, so no demos are recorded. To keep demos of pug matches, set `TV_ENABLE=1` in `.env` and restart. MatchZy then records each match to `game/csgo/MatchZy/` in the volume:

```sh
docker compose cp cs2:/home/steam/cs2-dedicated/game/csgo/MatchZy ./demos
```

## How the plugins get installed

`pre.sh` is mounted into the container and run by the image on every start, after SteamCMD has updated the game and before the server launches. It installs the latest Metamod:Source, CounterStrikeSharp, MatchZy and ChatControl, skipping anything already at that version, then adds Metamod to the search paths in `gameinfo.gi` and writes `cfg/cs2-servers.cfg` with the two admin convars.

Running after SteamCMD is what makes this work: CS2 updates replace `gameinfo.gi`, so Metamod has to be registered again on every boot. If a download fails, the server starts with the plugins it already has.

CounterStrikeSharp is installed separately rather than taking MatchZy's `-with-cssharp` bundle, because that bundle pins an older version than ChatControl needs.

## Configuration

Everything in `.env` is passed to the image; its [README](https://github.com/joedwards32/CS2) lists the full set of variables. Values must not contain a slash, which the image's config templating cannot handle.

GOTV (`TV_ENABLE`) and server logging (`CS2_LOG`) are both off, since practice needs neither. Turn `TV_ENABLE` on for match demos and `CS2_LOG` on when you are chasing a problem.

Server convars go in `cfg/gamemode_competitive_server.cfg` inside the volume. Do not use `cfg/server.cfg`: the image overwrites it on every start.
