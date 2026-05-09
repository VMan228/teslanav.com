"""
Manual cookie bootstrap script.

Run this ONCE on your local machine after logging into Waze in Chrome.
It reads your real Chrome cookies for waze.com and writes them to a JSON
file that the sidecar mounts at /data/waze_session.json.

Usage:
    pip install browser-cookie3
    python scripts/export_cookies.py --out ./waze_session.json
    # Then copy waze_session.json to the Docker volume on the VPS.
"""

import argparse
import json
import sys
import time


def get_waze_cookies(browser: str) -> list[dict]:
    try:
        import browser_cookie3
    except ImportError:
        sys.exit("Run: pip install browser-cookie3")

    loader = getattr(browser_cookie3, browser, None)
    if loader is None:
        sys.exit(f"Unsupported browser: {browser}")

    cookies = loader(domain_name=".waze.com")
    result = []
    for c in cookies:
        result.append({
            "name": c.name,
            "value": c.value,
            "domain": c.domain,
            "path": c.path,
            "expires": int(c.expires) if c.expires else int(time.time()) + 86400 * 30,
            "httpOnly": bool(getattr(c, "has_nonstandard_attr", lambda _: False)("HttpOnly")),
            "secure": bool(c.secure),
            "sameSite": "None",
        })

    # Keep only the cookies the Waze WAF cares about
    keep = {"_web_session", "_csrf_token", "_web_users", "_ga", "_gid"}
    result = [c for c in result if c["name"] in keep]
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--browser", default="chrome", choices=["chrome", "firefox", "safari"])
    parser.add_argument("--out", default="waze_session.json")
    args = parser.parse_args()

    print(f"Reading Waze cookies from {args.browser}…")
    cookies = get_waze_cookies(args.browser)
    if not cookies:
        sys.exit("No Waze cookies found — make sure you are logged into waze.com in that browser.")

    with open(args.out, "w") as f:
        json.dump(cookies, f, indent=2)

    names = [c["name"] for c in cookies]
    print(f"Wrote {len(cookies)} cookies to {args.out}: {names}")
    print(f"\nNext step: copy {args.out} to your VPS Docker volume.")
    print("  scp waze_session.json user@your-vps:/opt/waze-sidecar/data/waze_session.json")


if __name__ == "__main__":
    main()
