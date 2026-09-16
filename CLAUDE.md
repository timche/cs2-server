# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Deployable CS2 dedicated servers, one folder per flavour. `matchzy/` is currently the only one: the [joedwards32/CS2](https://github.com/joedwards32/CS2) image under Docker Compose with MatchZy and [ChatControl](https://github.com/timche/cs2-chat-control) layered on, deployed by `curl -fsSL https://raw.githubusercontent.com/timche/cs2-server/main/matchzy/install.sh | bash`.

There is no build, no dependency manifest and no test suite — just shell scripts and a compose file served raw from GitHub. The install URL is hardcoded in `matchzy/install.sh` and both READMEs, so a repo rename means updating all three.

## Verifying changes

```sh
bash -n matchzy/install.sh matchzy/pre.sh        # no shellcheck in this environment

# pre.sh against a fake server tree: installs for real, ~75 MB
mkdir -p /tmp/fake/game/csgo
printf '"GameInfo"\n{\n\tFileSystem\n\t{\n\t\tSearchPaths\n\t\t{\n\t\t\tGame\tcsgo\n\t\t}\n\t}\n}\n' > /tmp/fake/game/csgo/gameinfo.gi
STEAMAPPDIR=/tmp/fake bash matchzy/pre.sh        # rerun: idempotent, no duplicate exec lines
STEAMAPPDIR=/tmp/fake https_proxy=http://127.0.0.1:1 bash matchzy/pre.sh   # keeps what is installed

cp matchzy/.env.example matchzy/.env && (cd matchzy && docker compose config)
```

`install.sh` reads its answers from `/dev/tty`, so piping answers into it does nothing — drive it through a pty (`python3 -c` with the `pty` module) and point `BASE_URL` at `file:///…/matchzy` so it copies the working tree instead of fetching from GitHub. `REPO`, `REF` and `DIR` are the other overrides.

## Why the design is what it is

The base image re-runs SteamCMD on every container start and its `entry.sh` `source`s `pre.sh` from the data volume afterwards, just before launching the server. That single hook is why everything works the way it does:

- **`pre.sh` must never call `exit` at the top level.** Being sourced, an exit takes the server process with it. The whole body is a subshell whose failure is only logged.
- **The `gameinfo.gi` Metamod search path is re-applied on every boot**, because CS2 updates replace that file. Nothing that runs before SteamCMD — a derived image, an init container — can do this.
- **Plugin convars cannot live in `cfg/server.cfg`**, which the image overwrites each start. They go in a generated `cfg/cs2-server.cfg`, exec'd from both `cfg/MatchZy/config.cfg` (MatchZy load time) and `cfg/gamemode_competitive_server.cfg` (every map load), because CounterStrikeSharp gives no plugin load-order guarantee.
- The image ships `curl`, `wget`, `unzip` and `jq` and runs as uid 1000, so the hook can do the installs itself.

**CounterStrikeSharp is installed separately, at latest, and MatchZy comes from its plugin-only asset.** MatchZy's `-with-cssharp` bundle pins CSSharp 1.0.342; ChatControl requires ≥ 1.0.371. MatchZy has not published a release against current CSSharp, which is the one untested seam in the stack — check `docker compose logs` if MatchZy stops loading.

Versions are resolved at boot from GitHub `releases/latest` and the AlliedModders `mmsource-latest-linux` pointer, with a stamp file per component under `$STEAMAPPDIR/.matchzy/`. A failed lookup keeps the installed version rather than taking the server down.

## Conventions

Values in `.env` must not contain a slash: the image templates them into its configs with `sed`. `install.sh` re-prompts when one appears.

Both plugins run with everyone-is-admin on, which hands every player ChatControl's unfiltered `.rcon`. The installer defaults the server password to a generated one and warns when it is cleared — keep that posture in any change to the prompts.
