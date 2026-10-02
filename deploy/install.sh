#!/bin/sh
# Run as root inside a fresh Debian/Ubuntu LXC, from the repo root:  sh deploy/install.sh
set -e
apt-get update
apt-get install -y python3 curl ca-certificates
mkdir -p /opt/stickyreader
cp server/relay.py /opt/stickyreader/relay.py
cp deploy/stickyreader-relay.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now stickyreader-relay

# cloudflared (Cloudflare Tunnel client)
mkdir -p /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
  > /etc/apt/sources.list.d/cloudflared.list
apt-get update
apt-get install -y cloudflared

echo
echo "Relay is running on 127.0.0.1:8787. Check: curl -i localhost:8787/messages  (expect 401)"
echo "Next: create the tunnel in the Cloudflare dashboard and run:  cloudflared service install <TOKEN>"
