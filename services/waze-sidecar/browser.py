"""
Singleton async Playwright browser manager.

Maintains one persistent browser context so the Waze session stays warm.
Each fetch request gets a fresh page (so Waze JS always fires a georss
request on load), while the underlying context — and its cookies — is
shared and kept alive across requests.
"""

import asyncio
import json
import logging
import os
from pathlib import Path
from typing import Any

from playwright.async_api import async_playwright, Browser, BrowserContext, Playwright

log = logging.getLogger(__name__)

COOKIE_FILE = Path(os.getenv("COOKIE_FILE", "/data/waze_session.json"))
WAZE_LIVEMAP = "https://www.waze.com/live-map"
# Set PLAYWRIGHT_HEADLESS=0 (with Xvfb + DISPLAY=:99) to run headed — better reCAPTCHA scores
HEADLESS = os.getenv("PLAYWRIGHT_HEADLESS", "1") != "0"

STEALTH_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)
STEALTH_HEADERS = {
    "accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8",
    "accept-language": "en-US,en;q=0.9",
    "accept-encoding": "gzip, deflate, br",
    "sec-ch-ua": '"Chromium";v="124", "Google Chrome";v="124", "Not-A.Brand";v="99"',
    "sec-ch-ua-mobile": "?0",
    "sec-ch-ua-platform": '"Windows"',
    "sec-fetch-dest": "document",
    "sec-fetch-mode": "navigate",
    "sec-fetch-site": "none",
    "upgrade-insecure-requests": "1",
}


class BrowserManager:
    def __init__(self) -> None:
        self._lock = asyncio.Lock()
        self._pw: Playwright | None = None
        self._browser: Browser | None = None
        self._context: BrowserContext | None = None
        self._ready = False

    async def start(self) -> None:
        async with self._lock:
            if self._ready:
                return
            await self._launch()

    async def _launch(self) -> None:
        log.info("Launching Playwright browser (headless=%s)", HEADLESS)
        self._pw = await async_playwright().start()
        self._browser = await self._pw.chromium.launch(
            headless=HEADLESS,
            args=[
                "--disable-blink-features=AutomationControlled",
                "--no-sandbox",
                "--disable-dev-shm-usage",
                "--disable-setuid-sandbox",
                "--disable-infobars",
                "--window-size=1920,1080",
                "--disable-extensions",
                "--disable-crash-reporter",
            ],
        )
        self._context = await self._browser.new_context(
            user_agent=STEALTH_UA,
            extra_http_headers=STEALTH_HEADERS,
            viewport={"width": 1920, "height": 1080},
            locale="en-US",
            timezone_id="America/New_York",
        )
        # Comprehensive anti-detection script
        await self._context.add_init_script("""
            // Hide automation flag
            Object.defineProperty(navigator, 'webdriver', {get: () => undefined});
            // Fake plugins (empty in headless)
            Object.defineProperty(navigator, 'plugins', {get: () => [1, 2, 3, 4, 5]});
            // Fake languages
            Object.defineProperty(navigator, 'languages', {get: () => ['en-US', 'en']});
            // Add chrome runtime object that headless Chrome lacks
            window.chrome = {runtime: {}, loadTimes: function(){}, csi: function(){}, app: {}};
            // Prevent iframe detection via permissions
            const originalQuery = window.navigator.permissions.query;
            window.navigator.permissions.query = (parameters) => (
                parameters.name === 'notifications' ?
                    Promise.resolve({state: Notification.permission}) :
                    originalQuery(parameters)
            );
        """)

        if COOKIE_FILE.exists():
            log.info("Loading saved cookies from %s", COOKIE_FILE)
            cookies = json.loads(COOKIE_FILE.read_text())
            await self._context.add_cookies(cookies)
            log.info("Cookies loaded — session assumed valid (confirmed on first real request)")
        else:
            log.warning("No cookie file found — service will return 503 until cookies are provided")

        self._ready = True
        log.info("Browser ready")

    async def _login(self) -> None:
        from auth import login  # avoid circular import at module load

        page = await self._context.new_page()
        try:
            await login(self._context, page)  # raises RuntimeError if IMAP not configured
        finally:
            await page.close()
        await self._save_cookies()

    async def _save_cookies(self) -> None:
        cookies = await self._context.cookies()
        COOKIE_FILE.parent.mkdir(parents=True, exist_ok=True)
        COOKIE_FILE.write_text(json.dumps(cookies, indent=2))
        log.info("Saved %d cookies to %s", len(cookies), COOKIE_FILE)

    async def fetch_alerts(
        self, left: float, right: float, bottom: float, top: float
    ) -> dict[str, Any]:
        async with self._lock:
            return await self._fetch(left, right, bottom, top, attempt=1)

    async def _fetch(
        self, left: float, right: float, bottom: float, top: float, attempt: int
    ) -> dict[str, Any]:
        center_lon = (left + right) / 2
        env = "na" if -170 <= center_lon <= -30 else "row"
        target_params = (
            f"env={env}&types=alerts&top={top}&bottom={bottom}"
            f"&left={left}&right={right}&ma=50&mj=0&mu=0"
        )

        async def handle_route(route, _request):
            await route.continue_(
                url=f"https://www.waze.com/live-map/api/georss?{target_params}"
            )

        # Fresh page per request — guarantees Waze JS fires a new georss on load
        page = await self._context.new_page()
        try:
            await page.route("**/georss**", handle_route)

            async with page.expect_response(
                lambda r: "georss" in r.url, timeout=20_000
            ) as resp_info:
                await page.goto(WAZE_LIVEMAP, wait_until="domcontentloaded", timeout=30_000)

            response = await resp_info.value

            if response.status != 200:
                log.warning("georss returned HTTP %s (attempt %s)", response.status, attempt)
                if attempt == 1:
                    log.info("Re-authenticating after non-200 response")
                    await self._login()
                    return await self._fetch(left, right, bottom, top, attempt=2)
                raise RuntimeError(f"Waze returned HTTP {response.status} after re-auth")

            data = await response.json()
            log.info(
                "Fetched %d alerts (attempt %s)", len(data.get("alerts", [])), attempt
            )
            await self._save_cookies()
            return data

        finally:
            await page.close()


manager = BrowserManager()
