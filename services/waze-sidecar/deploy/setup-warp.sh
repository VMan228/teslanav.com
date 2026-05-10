#!/usr/bin/env bash
# Installs Cloudflare WARP and routes all outbound server traffic through
# Cloudflare's network, giving the VPS a higher trust score on Waze's
# georss endpoint vs a raw data-center IP.
# Run as root.
set -euo pipefail

echo "[warp] Adding Cloudflare WARP apt repository..."
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp.gpg
echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp.gpg] https://pkg.cloudflareclient.com/ any main" \
    > /etc/apt/sources.list.d/cloudflare-warp.list
apt-get update -qq
apt-get install -y cloudflare-warp

echo "[warp] Registering (accepting ToS)..."
warp-cli --accept-tos registration new

echo "[warp] Connecting..."
warp-cli connect

echo "[warp] Status:"
warp-cli status

echo ""
echo "[warp] Exit IP (should be a Cloudflare address, not your VPS IP):"
curl -s https://cloudflare.com/cdn-cgi/trace | grep ip=

echo ""
echo "Done. Restart waze-sidecar to pick up the new outbound route:"
echo "  systemctl restart waze-sidecar"
