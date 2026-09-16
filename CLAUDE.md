# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Deployable CS2 dedicated servers, one folder per flavour, each the [joedwards32/CS2](https://github.com/joedwards32/CS2) image under Docker Compose with plugins layered on and [ChatControl](https://github.com/timche/cs2-chat-control) in both. `matchzy/` runs MatchZy for practice and pugs; `retakes/` runs cs2-retakes, cs2-instadefuse and RetakesAllocator. Each is deployed by `curl -fsSL https://raw.githubusercontent.com/timche/cs2-server/main/<flavour>/install.sh | bash`.

There is no build, no dependency manifest and no test suite — just shell scripts and a compose file served raw from GitHub. The install URL is hardcoded in each folder's `install.sh` and README, so a repo rename means updating every one of them.

## Verifying changes

Substitute the flavour being changed for `matchzy` below.

```sh
bash -n matchzy/install.sh matchzy/pre.sh        # no shellcheck in this environment

# pre.sh against a fake server tree: installs for real, ~75 MB
mkdir -p /tmp/fake/game/csgo
printf '"GameInfo"\n{\n\tFileSystem\n\t{\n\t\tSearchPaths\n\t\t{\n\t\t\tGame\tcsgo\n\t\t}\n\t}\n}\n' > /tmp/fake/game/csgo/gameinfo.gi
STEAMAPPDIR=/tmp/fake bash matchzy/pre.sh        # rerun: idempotent, no duplicate exec lines
STEAMAPPDIR=/tmp/fake https_proxy=http://127.0.0.1:1 bash matchzy/pre.sh   # keeps what is installed

cp matchzy/.env.example matchzy/.env && (cd matchzy && docker compose config)
```

A full run resolves six releases through the unauthenticated GitHub API, which allows 60 an hour — a few runs in a row hit the limit and every download comes back 403.

`install.sh` reads its answers from `/dev/tty`, so piping answers into it does nothing — drive it through a pty (`python3 -c` with the `pty` module) and point `BASE_URL` at `file:///…/matchzy` so it copies the working tree instead of fetching from GitHub. `REPO`, `REF` and `DIR` are the other overrides.

## Why the design is what it is

The base image re-runs SteamCMD on every container start and its `entry.sh` `source`s `pre.sh` from the data volume afterwards, just before launching the server. That single hook is why everything works the way it does:

- **`pre.sh` must never call `exit` at the top level.** Being sourced, an exit takes the server process with it. The whole body is a subshell whose failure is only logged.
- **The `gameinfo.gi` Metamod search path is re-applied on every boot**, because CS2 updates replace that file. Nothing that runs before SteamCMD — a derived image, an init container — can do this.
- **Plugin convars cannot live in `cfg/server.cfg`**, which the image overwrites each start. They go in a generated `cfg/cs2-server.cfg`, exec'd from `cfg/gamemode_competitive_server.cfg` (every map load) and, in matchzy, also from `cfg/MatchZy/config.cfg` (MatchZy load time), because CounterStrikeSharp gives no plugin load-order guarantee.
- The image ships `curl`, `wget`, `unzip` and `jq` and runs as uid 1000, so the hook can do the installs itself.

**CounterStrikeSharp is installed separately, at latest, and MatchZy comes from its plugin-only asset.** MatchZy's `-with-cssharp` bundle pins CSSharp 1.0.342; ChatControl requires ≥ 1.0.371. MatchZy has not published a release against current CSSharp, which is the one untested seam in the stack — check `docker compose logs` if MatchZy stops loading.

Versions are resolved at boot from GitHub `releases/latest` and the AlliedModders `mmsource-latest-linux` pointer, with a stamp file per component under `$STEAMAPPDIR/.matchzy/` or `$STEAMAPPDIR/.retakes/`. A failed lookup keeps the installed version rather than taking the server down.

### retakes only

- **Admin is two systems that do not overlap.** `chatcontrol_everyone_is_admin` bypasses ChatControl's own check before CounterStrikeSharp is ever consulted. Retakes and the allocator instead ask `AdminManager.PlayerHasPermissions`, which knows only `addons/counterstrikesharp/configs/admins.json` — hence `RETAKES_ADMIN_STEAM_IDS` and the Steam64 ID prompt. There is no wildcard identity, and `.rcon css_addspawn` is no way round it: those handlers bail when no player issued the command.
- **`cfg/cs2-retakes/retakes.cfg` is the plugin's to create.** `ServerHelper.ExecuteRetakesConfiguration` writes it only `if (!File.Exists(...))`, so creating, touching or appending to it from `pre.sh` leaves the server on stock competitive convars.
- **`GameSettings.EnableFallbackAllocation` must be `false`** or retakes and the allocator both hand out weapons. CounterStrikeSharp generates `configs/plugins/RetakesPlugin/RetakesPlugin.json` on first plugin load and never rewrites it, so `pre.sh` owns that one key and every key it leaves out takes the plugin's default. The generated file opens with a `//` comment line, which `jq` will not parse.
- **The allocator's zip was built on Windows.** Its paths use backslash separators, which Info-ZIP translates but exits 1 to warn about, and its directory entries carry no execute bit, which would leave the server unable to enter `plugins/RetakesAllocator/runtimes/`. `sync()` unpacks zips aside, treats only status > 1 as failure, `chmod -R u+rwX`s the tree and copies it into place.

**The allocator is built against CounterStrikeSharp 1.0.367 on net8.0 and ships its own `RetakesPluginShared.dll` (2.0.0) inside its plugin folder, while retakes 3.1.0 is net10.0 against 1.0.369 and installs the same library to `addons/counterstrikesharp/shared/`.** Current CounterStrikeSharp (1.0.374, .NET 10.0.3) loads both. If that duplicate shared assembly ever stops resolving to one type, the symptom is the allocator logging that it cannot get the `retakes_plugin:event_sender` capability while retakes itself runs fine.

## Conventions

Values in `.env` must not contain a slash: the image templates them into its configs with `sed`. `install.sh` re-prompts when one appears.

Every flavour runs ChatControl with everyone-is-admin on, which hands every player its unfiltered `.rcon`. Each installer defaults the server password to a generated one and warns when it is cleared — keep that posture in any change to the prompts.
