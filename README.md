# cs2-server

Docker Compose stacks for Counter-Strike 2 dedicated servers, each one a folder you can deploy to a VPS with a single command.

## Servers

| Folder | What it is |
| --- | --- |
| [`server/`](server/) | The server, in three modes a web panel switches between: [MatchZy](https://github.com/shobhit-pathak/MatchZy) for practice and 5v5 pug matches, retakes with [cs2-retakes](https://github.com/B3none/cs2-retakes), [cs2-instadefuse](https://github.com/B3none/cs2-instadefuse) and [RetakesAllocator](https://github.com/Micka2302/cs2-retakes-allocator-2.0), or plain competitive. [ChatControl](https://github.com/timche/cs2-chat-control) and every-player-an-admin in all three, on the [joedwards32/CS2](https://github.com/joedwards32/CS2) image. |
| [`proxy/`](proxy/) | Not a server: nftables rules for a VPS that forwards the game port to a server on your tailnet, so a home machine can host without an open firewall port. |
