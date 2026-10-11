"""Fetch the public comparison widget using a separate proxied browser."""

import json
from pathlib import Path

from playwright.sync_api import sync_playwright


BASE = Path(__file__).resolve().parent
API = "https://www.dpreview.com/wp-json/wayfinder-image-compare/v1/widgets/541497/frontend"
PAGE = "https://www.dpreview.com/image-comparison/?attr13_0=sony_a7rv&attr15_0=raw&attr16_0=100&attr18=daylight"
RAW = "https://www.dpreview.com/wp-content/uploads/image-compare/519596/526411/19990c35cf194481a0093de2b02ed818.arw"

with sync_playwright() as p:
    browser = p.chromium.launch(
        executable_path="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        headless=False,
        proxy={"server": "http://127.0.0.1:7897"},
    )
    try:
        context = browser.new_context(viewport={"width": 1440, "height": 1000})
        page = context.new_page()
        requests = []

        def record_response(r):
            if "dpreview.com" in r.url:
                requests.append({"url": r.url, "status": r.status})
            if "wayfinder-image-compare" in r.url and r.status == 200:
                try:
                    value = r.json()
                    (BASE / "sources" / "dpreview-widget.json").write_text(
                        json.dumps(value, ensure_ascii=True), encoding="utf-8"
                    )
                    print(json.dumps({"loaded_api": r.url, "keys": list(value)}), flush=True)
                except Exception as exc:
                    print(str(exc), flush=True)

        page.on("response", record_response)
        page.goto(PAGE, wait_until="domcontentloaded", timeout=45000)
        try:
            page.wait_for_function(
                "!document.title.includes('moment')", timeout=20000
            )
        except Exception:
            pass
        try:
            page.wait_for_load_state("networkidle", timeout=20000)
        except Exception:
            pass
        (BASE / "sources" / "dpreview-page.html").write_text(
            page.content(), encoding="utf-8"
        )
        (BASE / "sources" / "dpreview-network.json").write_text(
            json.dumps(requests, indent=2), encoding="utf-8"
        )
        print(json.dumps({"title": page.title(), "url": page.url}), flush=True)
        response = page.evaluate(
            """async (url) => {
                const r = await fetch(url);
                return {status: r.status, text: await r.text()};
            }""",
            API,
        )
        print(json.dumps({"api_status": response["status"], "bytes": len(response["text"])}), flush=True)
        if response["status"] == 200:
            value = json.loads(response["text"])
            (BASE / "sources" / "dpreview-widget.json").write_text(
                json.dumps(value, ensure_ascii=True), encoding="utf-8"
            )
            print(json.dumps({"keys": list(value)}), flush=True)
        else:
            page.screenshot(path=str(BASE / "dpreview-access.png"))
            (BASE / "sources" / "dpreview-access.html").write_text(
                response["text"], encoding="utf-8"
            )
        raw_status = page.evaluate(
            """async (url) => {
                const r = await fetch(url, {credentials: 'include'});
                return {status: r.status, type: r.headers.get('content-type'), length: r.headers.get('content-length')};
            }""",
            RAW,
        )
        print(json.dumps({"raw": raw_status}), flush=True)
    finally:
        browser.close()
