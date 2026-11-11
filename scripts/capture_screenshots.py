#!/usr/bin/env python3
"""Capture the three Grafana dashboards as PNGs into docs/screenshots/.

Needs: pip install playwright && playwright install chromium
Reads GRAFANA_URL (default http://localhost:3000), GRAFANA_ADMIN_USER and
GRAFANA_ADMIN_PASSWORD from the environment.

Why the viewport is sized from the dashboard JSON: Grafana scrolls inside its
own container, so a full-page screenshot only captures one viewport and cuts
off the lower panels (the logs and alerts panels on the Application
dashboard). Sizing the viewport to the dashboard's grid height captures all of
it, and also makes every panel visible so none is skipped by lazy loading.

Run it a minute or two after `scripts/demo_traffic.sh` has started, so the
rate and error panels have data. The script exits non-zero if a dashboard
looks unrendered rather than silently writing a blank image.
"""

import os
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

DASHBOARDS = {
    "application": "app-overview",
    "host": "host-overview",
    "containers": "containers-overview",
}

WIDTH = 1600
ROW_PX = 38  # Grafana grid: 30 px row height + 8 px margin
CHROME_PX = 140  # variable bar and padding above the grid
PANEL_SELECTOR = '[data-testid^="data-testid Panel header"]'


def panel_info(page, base: str, uid: str) -> tuple[int, int]:
    """Return (panel count, grid rows) for a provisioned dashboard.

    Uses the logged-in browser session, so no credentials are sent separately.
    """
    resp = page.request.get(f"{base}/api/dashboards/uid/{uid}")
    if not resp.ok:
        raise RuntimeError(f"GET dashboard {uid} failed: HTTP {resp.status}")
    panels = resp.json()["dashboard"]["panels"]
    rows = max(p["gridPos"]["y"] + p["gridPos"]["h"] for p in panels)
    return len(panels), rows


def main() -> int:
    base = os.getenv("GRAFANA_URL", "http://localhost:3000").rstrip("/")
    user = os.getenv("GRAFANA_ADMIN_USER")
    password = os.getenv("GRAFANA_ADMIN_PASSWORD")
    if not user or not password:
        print("set GRAFANA_ADMIN_USER and GRAFANA_ADMIN_PASSWORD", file=sys.stderr)
        return 2

    out = Path(__file__).resolve().parent.parent / "docs" / "screenshots"
    out.mkdir(parents=True, exist_ok=True)
    failed = False

    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(viewport={"width": WIDTH, "height": 1200}, device_scale_factor=2)
        page.goto(f"{base}/login")
        page.fill("input[name=user]", user)
        page.fill("input[name=password]", password)
        page.click("button[type=submit]")
        page.wait_for_url(lambda url: "/login" not in url, timeout=15000)

        for name, uid in DASHBOARDS.items():
            expected, rows = panel_info(page, base, uid)
            page.set_viewport_size({"width": WIDTH, "height": rows * ROW_PX + CHROME_PX})
            page.goto(f"{base}/d/{uid}?kiosk&from=now-15m&to=now")
            try:
                page.wait_for_function(
                    f"document.querySelectorAll('{PANEL_SELECTOR}').length >= {expected}",
                    timeout=30000,
                )
            except Exception:
                print(f"warning: {name}: fewer than {expected} panels rendered", file=sys.stderr)
                failed = True
            page.wait_for_load_state("networkidle")
            page.wait_for_timeout(5000)  # let queries finish and charts draw
            path = out / f"{name}.png"
            page.screenshot(path=str(path))
            print(f"wrote {path} ({expected} panels expected)")
        browser.close()

    if failed:
        print(
            "a dashboard did not fully render; check the images before committing", file=sys.stderr
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
