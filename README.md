# cs2-server

Docker Compose stacks for Counter-Strike 2 dedicated servers, each one a folder you can deploy to a VPS with a single command.

## Servers

| Folder | What it is |
| --- | --- |
| [`matchzy/`](matchzy/) | Practice server that also runs 5v5 pug matches: [MatchZy](https://github.com/shobhit-pathak/MatchZy) plus [ChatControl](https://github.com/timche/cs2-chat-control) on top of the [joedwards32/CS2](https://github.com/joedwards32/CS2) image, with every player an admin. |
| [`proxy/`](proxy/) | Not a server: nftables rules for a VPS that forwards the game port to a server on your tailnet, so a home machine can host without an open firewall port. |
