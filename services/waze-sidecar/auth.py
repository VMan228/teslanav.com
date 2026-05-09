"""
Waze session management.

Primary path: load cookies exported manually via scripts/export_cookies.py.
Fallback path: if IMAP env vars are set, attempt automated OTP retrieval.

Waze login is email → 5-digit OTP (magic link sent to inbox) — there is no
password field on the web login form. Full automation requires inbox access.
"""

import asyncio
import imaplib
import logging
import os
import re
import time

from playwright.async_api import BrowserContext, Page

log = logging.getLogger(__name__)

WAZE_LOGIN_URL = "https://www.waze.com/en-US/login"
WAZE_EMAIL = os.getenv("WAZE_EMAIL", "")

# IMAP settings — optional, enables automated OTP retrieval
IMAP_HOST = os.getenv("WAZE_OTP_IMAP_HOST", "")       # e.g. imap.gmail.com
IMAP_PORT = int(os.getenv("WAZE_OTP_IMAP_PORT", "993"))
IMAP_USER = os.getenv("WAZE_OTP_IMAP_USER", "")        # Gmail address
IMAP_PASS = os.getenv("WAZE_OTP_IMAP_PASS", "")        # Gmail App Password


async def login(context: BrowserContext, page: Page) -> None:
    """
    Attempt to re-authenticate. Tries IMAP-assisted OTP if configured,
    otherwise raises so the health endpoint can signal manual intervention.
    """
    if _imap_configured():
        log.info("IMAP configured — attempting automated OTP login")
        await _login_with_imap(context, page)
    else:
        raise RuntimeError(
            "Waze session expired and IMAP re-auth is not configured. "
            "Run scripts/export_cookies.py to inject fresh cookies manually."
        )


def _imap_configured() -> bool:
    return bool(IMAP_HOST and IMAP_USER and IMAP_PASS and WAZE_EMAIL)


async def _login_with_imap(context: BrowserContext, page: Page) -> None:
    await page.goto(WAZE_LOGIN_URL, wait_until="networkidle", timeout=30_000)

    # Enter email
    await page.fill('input[type="email"], input[name="email"]', WAZE_EMAIL)
    await page.click('button[type="submit"]')

    # Wait for OTP input to appear
    await page.wait_for_selector('input[type="number"], input[name="code"]', timeout=15_000)

    # Fetch OTP from inbox (poll for up to 60 seconds)
    otp = await asyncio.to_thread(_fetch_otp_from_imap, timeout=60)
    if not otp:
        raise RuntimeError("Timed out waiting for Waze OTP email")

    log.info("Got OTP from inbox")
    await page.fill('input[type="number"], input[name="code"]', otp)
    await page.click('button[type="submit"]')
    await page.wait_for_url("**/live-map**", timeout=20_000)
    log.info("IMAP-assisted login succeeded")


def _fetch_otp_from_imap(timeout: int = 60) -> str | None:
    """Poll the IMAP inbox for a Waze OTP email, return the 5-digit code."""
    deadline = time.time() + timeout
    seen_ids: set[bytes] = set()

    while time.time() < deadline:
        try:
            with imaplib.IMAP4_SSL(IMAP_HOST, IMAP_PORT) as mail:
                mail.login(IMAP_USER, IMAP_PASS)
                mail.select("INBOX")
                _, data = mail.search(None, 'FROM "waze.com" UNSEEN')
                ids = set(data[0].split())
                new_ids = ids - seen_ids

                for uid in new_ids:
                    _, msg_data = mail.fetch(uid, "(BODY[TEXT])")
                    body = msg_data[0][1].decode("utf-8", errors="ignore")
                    match = re.search(r"\b(\d{5})\b", body)
                    if match:
                        # Mark as read so we don't re-process it
                        mail.store(uid, "+FLAGS", "\\Seen")
                        return match.group(1)

                seen_ids = ids
        except Exception as exc:
            log.warning("IMAP poll error: %s", exc)

        time.sleep(5)

    return None
