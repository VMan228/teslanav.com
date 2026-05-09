# waze-sidecar

Playwright-based Python sidecar that proxies the Waze Live Map `georss` API.
Runs as a Docker container alongside TeslaNav on VIE.

## Why a sidecar?

Waze's `georss` endpoint sits behind Google Cloud Armor + reCAPTCHA v3. Plain
HTTP clients are rejected with a bare 403. The only working approach is to
intercept the Waze Live Map page's own georss request (which carries a valid
reCAPTCHA token) using a stealth Playwright browser.

## Auth approach

Waze login uses email → OTP (magic link), not email + password.

**Primary path — manual cookie bootstrap (required on first deploy):**

1. Log into `waze.com` in Chrome on your local machine
2. Run the export script (requires `pip install browser-cookie3`):
   ```
   python scripts/export_cookies.py --out waze_session.json
   ```
3. Copy the file to the VPS volume:
   ```
   scp waze_session.json user@your-vps:/opt/waze-sidecar/data/waze_session.json
   ```
4. Start the container — it loads the cookies on startup

**Session longevity:** As long as the sidecar hits Waze regularly (every few
minutes), the session stays alive indefinitely. The 30-day expiry applies only
to idle sessions.

**Fallback — automated IMAP OTP (optional):**

If the session ever expires, set the `WAZE_OTP_IMAP_*` env vars (see
`.env.example`). The sidecar will fetch the OTP from your Gmail inbox
automatically. Requires a Gmail App Password (not your account password).

## Setup

```bash
cd services/waze-sidecar
cp .env.example .env
# edit .env with your values

# Bootstrap cookies (first time only)
python scripts/export_cookies.py --out waze_session.json
scp waze_session.json user@your-vps:/opt/waze-sidecar/data/waze_session.json

# On the VPS
docker compose up -d
```

## Wiring into TeslaNav

Set in TeslaNav's `.env.local` (or Docker env):

```
WAZE_SIDECAR_URL=http://waze-sidecar:8000
```

When `WAZE_SIDECAR_URL` is set, the Next.js Waze route calls the sidecar.
When unset, it falls back to the OpenWeb Ninja API (`WAZE_API_KEY`).

## Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /waze?left=&right=&bottom=&top=` | Returns `{ alerts: WazeAlert[] }` |
| `GET /health` | Returns session readiness |

## Cookie file location

The container mounts `/data` as a named volume. The cookie file lives at
`/data/waze_session.json` (configurable via `COOKIE_FILE` env var).
Cookies are automatically re-saved after each successful fetch, keeping the
session warm across container restarts.
