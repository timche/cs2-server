# cs2-server

A Counter-Strike 2 dedicated server you can put on a VPS with one command. It plays three ways — [MatchZy](https://github.com/shobhit-pathak/MatchZy) for practice and 5v5 pug matches, retakes with [cs2-retakes](https://github.com/B3none/cs2-retakes), [cs2-instadefuse](https://github.com/B3none/cs2-instadefuse) and [RetakesAllocator](https://github.com/Micka2302/cs2-retakes-allocator-2.0), or plain competitive — and switches between them from a small web panel. [ChatControl](https://github.com/timche/cs2-chat-control) and every-player-an-admin are on in all three, on the [joedwards32/CS2](https://github.com/joedwards32/CS2) image under Docker Compose.

```sh
curl -fsSL https://raw.githubusercontent.com/timche/cs2-server/main/server/install.sh | bash
```

[`server/`](server/) is all of it: the compose stack, the boot hook that installs the plugins, the panel and an optional Cloudflare tunnel for reaching the panel from anywhere. Its README covers installing, the three modes, the chat commands and every `.env` key.

[`proxy/`](proxy/) is a separate and optional piece, not part of the server: nftables rules for a VPS that forwards the game port to a machine on your tailnet, so you can host from home without opening a port in your firewall. A server running on the VPS itself does not need it.
