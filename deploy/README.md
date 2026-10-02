# Hosting the relay (Proxmox LXC + Cloudflare Tunnel)

No router changes needed: the LXC makes an outbound connection to Cloudflare, which serves
your relay at `https://notes.yourdomain.com` with automatic HTTPS.

## Prerequisite
The domain must use Cloudflare DNS (free plan is fine). Add it at dash.cloudflare.com and switch the
nameservers at your registrar. If you'd rather not move a domain, use a spare one.

## 1. LXC
In Proxmox: create a Debian 12 LXC (1 core, 256-512 MB RAM, 2 GB disk, DHCP). Open its console as root:
```
apt-get update && apt-get install -y git
git clone -b claude/koreader-kindle-messaging-plugin-77owpr https://github.com/ArthurAns/stickyreader.git
cd stickyreader && sh deploy/install.sh
```

## 2. Tunnel
1. Cloudflare dashboard -> Zero Trust -> Networks -> Tunnels -> Create a tunnel (Cloudflared).
2. Copy the install command it shows; in the LXC run only the token part:
   `cloudflared service install <TOKEN>`
3. In the tunnel's *Public hostname* tab add: hostname `notes.yourdomain.com`, service `HTTP`, URL `localhost:8787`.

## 3. Check
`curl -i https://notes.yourdomain.com/messages` should return `401`.
Then on each Kindle set *Relay server URL* to `https://notes.yourdomain.com` and re-pair.

Data lives in `/var/lib/stickyreader/relay.json` inside the LXC; include it in your Proxmox backups.
The relay listens on 127.0.0.1 only, so it is reachable solely through the tunnel.
