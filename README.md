# StickyReader

A KOReader plugin in the spirit of the "Note it" iOS app: pair two e-readers
and send short notes that show up on the other one's sleep (lock) screen.

## How it works
Sleeping Kindles can't receive connections, so a tiny **relay** (`server/relay.py`,
Python stdlib only) holds a mailbox per device. Each device pushes notes to the
relay and fetches notes addressed to it (manually, or automatically on wake).
The newest received note is drawn as the sleep screen.

## Setup
1. Run the relay on any always-on machine reachable by both Kindles
   (home server, Raspberry Pi, VPS behind HTTPS): `python3 server/relay.py --port 8787`
2. Copy `stickyreader.koplugin/` to `koreader/plugins/` on **both** Kindles, restart KOReader.
3. On both: Tools menu → Sticky Reader → *Relay server URL*.
4. Device A: *Pair: create code*. Device B: *Pair: enter code*.
5. *Write a note* sends; *Check for new notes* (or enable *Sync when waking up*) receives.

## Notes / limits
- Untested on hardware: written against KOReader's plugin API from memory; the sleep-screen
  hook wraps `Screensaver.show`, which may need tweaks across KOReader versions.
- Relay is plain HTTP and unencrypted; use HTTPS (reverse proxy) beyond your LAN.
- Notes are text-only, max 2000 chars; only the latest is displayed.
