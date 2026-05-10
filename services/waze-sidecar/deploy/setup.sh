#!/usr/bin/env bash
# Waze sidecar setup for Ubuntu 22.04+ (bare-metal / VM, not Docker)
# Run as root:  sudo bash setup.sh
# The sidecar will listen on 127.0.0.1:8001 with a headed Chromium via Xvfb.
set -euo pipefail

INSTALL_DIR=/opt/waze-sidecar
SERVICE_USER=waze-sidecar
SIDECAR_PORT=8001

# ── 1. System deps ─────────────────────────────────────────────────────────────
echo "[setup] Installing system packages…"
apt-get update -qq
# Chromium system deps (Playwright downloads its own Chromium build)
apt-get install -y --no-install-recommends \
    python3 python3-venv python3-pip \
    xvfb \
    libglib2.0-0 libnss3 libnspr4 libdbus-1-3 libatk1.0-0 libatk-bridge2.0-0 \
    libcups2 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 \
    libxrandr2 libgbm1 libasound2t64 libpango-1.0-0 libcairo2 libatspi2.0-0

# ── 2. Service user ────────────────────────────────────────────────────────────
if ! id "$SERVICE_USER" &>/dev/null; then
    echo "[setup] Creating service user $SERVICE_USER…"
    useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
fi

# ── 3. Install directory ───────────────────────────────────────────────────────
echo "[setup] Deploying sidecar to $INSTALL_DIR…"
mkdir -p "$INSTALL_DIR/data"
# Copy sidecar source (run this script from services/waze-sidecar/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp -r "$SCRIPT_DIR/../"*.py "$INSTALL_DIR/"
cp "$SCRIPT_DIR/../requirements.txt" "$INSTALL_DIR/"

# ── 4. Python venv + deps ──────────────────────────────────────────────────────
echo "[setup] Creating Python venv…"
python3 -m venv "$INSTALL_DIR/.venv"
"$INSTALL_DIR/.venv/bin/pip" install --quiet --upgrade pip
"$INSTALL_DIR/.venv/bin/pip" install --quiet -r "$INSTALL_DIR/requirements.txt"

# ── 5. Playwright browsers ────────────────────────────────────────────────────
echo "[setup] Installing Playwright Chromium…"
"$INSTALL_DIR/.venv/bin/playwright" install chromium
"$INSTALL_DIR/.venv/bin/playwright" install-deps chromium

# ── 6. Env file ───────────────────────────────────────────────────────────────
if [[ ! -f "$INSTALL_DIR/.env" ]]; then
    echo "[setup] Creating env file template at $INSTALL_DIR/.env — fill in values before starting."
    cat > "$INSTALL_DIR/.env" <<'ENV'
WAZE_EMAIL=your@email.com
LOG_LEVEL=INFO
# WAZE_OTP_IMAP_HOST=imap.gmail.com
# WAZE_OTP_IMAP_PORT=993
# WAZE_OTP_IMAP_USER=your@gmail.com
# WAZE_OTP_IMAP_PASS=your-app-password
ENV
fi

# ── 7. Permissions ────────────────────────────────────────────────────────────
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"

# ── 8. Systemd units ──────────────────────────────────────────────────────────
echo "[setup] Installing systemd units…"
cp "$SCRIPT_DIR/xvfb.service" /etc/systemd/system/
cp "$SCRIPT_DIR/waze-sidecar.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable xvfb.service waze-sidecar.service

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Setup complete."
echo ""
echo "  Next steps:"
echo "  1. Copy your Waze session cookie file:"
echo "     scp waze_session.json root@VPS:$INSTALL_DIR/data/waze_session.json"
echo "     chown $SERVICE_USER:$SERVICE_USER $INSTALL_DIR/data/waze_session.json"
echo ""
echo "  2. Start services:"
echo "     systemctl start xvfb waze-sidecar"
echo ""
echo "  3. Check status:"
echo "     systemctl status waze-sidecar"
echo "     journalctl -u waze-sidecar -f"
echo ""
echo "  4. Set WAZE_SIDECAR_URL in your TeslaNav .env:"
echo "     WAZE_SIDECAR_URL=http://host.docker.internal:$SIDECAR_PORT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
