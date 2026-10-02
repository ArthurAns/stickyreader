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

## Typing from a phone
On a paired Kindle: Sticky Reader -> *Link phone (QR code)*, then scan the QR code (or open
the URL) with your phone. The page sends notes to the *other* Kindle. The URL contains a secret
token; re-linking revokes the previous link. The relay URL must be reachable from the phone
(same Wi-Fi for a LAN address, or a public HTTPS host).

## Receiving, history, settings
- Notes are fetched automatically: right after waking (if the Kindle is online) and every 5 minutes
  while it is awake and online. A Kindle that is asleep cannot receive anything; notes arrive at the next wake.
- Optional: *Settings -> Turn on Wi-Fi briefly when waking up* switches Wi-Fi on for the fetch, then off again.
- *History* (Sticky Reader menu) lists the last 100 notes received and sent; tap one to read it.
- The sleep screen shows the latest received note as a framed card with the date and time received.

## Relay security
- At most **2 devices** per relay (`--max-devices`); unpair a Kindle to free a slot. If a Kindle is lost
  without unpairing, run `python3 relay.py --reset --data <file>` (stop the service first; it resets and exits) to start over.
- Wrong pairing codes are rate-limited (10 per 10 min per IP), code creation too (10 per hour);
  pairing codes expire after 10 minutes and abandoned ones free their slot.
- Only the newest 500 notes are kept. Run `python3 tests/test_relay.py` for the relay tests.

## Notes / limits
- Untested on hardware: written against KOReader's plugin API from memory; the sleep-screen
  hook wraps `Screensaver.show`, which may need tweaks across KOReader versions.
- Relay is plain HTTP and unencrypted; use HTTPS (reverse proxy) beyond your LAN.
- Notes are text-only, max 2000 chars; only the latest is displayed.
