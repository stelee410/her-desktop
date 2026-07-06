#!/usr/bin/env python3
"""Her Desktop browser sidecar.

Drives the user's real Chrome (stable channel) through a patched Playwright
(patchright) so automation is hard to detect: a persistent profile reuses the
user's logins, and the launch flags remove the classic automation tells
(navigator.webdriver, --enable-automation).

One long-lived process holds a single browser context and serves a small
loopback HTTP API. Requests are handled serially on the main thread, which is
required by the Playwright sync API and matches how a browser is used anyway
(one action at a time). Every request must carry the shared token.

Environment:
  HER_BROWSER_PORT     loopback port to bind (required)
  HER_BROWSER_TOKEN    shared secret required on every request (required)
  HER_BROWSER_PROFILE  persistent user-data-dir for the real Chrome profile
  HER_BROWSER_CHANNEL  Chrome channel (default: chrome)
"""

import base64
import json
import os
import random
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

from patchright.sync_api import sync_playwright

PORT = int(os.environ.get("HER_BROWSER_PORT", "0"))
TOKEN = os.environ.get("HER_BROWSER_TOKEN", "")
PROFILE = os.environ.get("HER_BROWSER_PROFILE") or os.path.abspath("her-browser-profile")
CHANNEL = os.environ.get("HER_BROWSER_CHANNEL", "chrome")

# Anti-detection launch config validated against a real Chrome stable build:
# real channel + persistent profile + no automation flags → navigator.webdriver
# is false and the UA is a normal (non-headless) Chrome.
LAUNCH_ARGS = [
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-blink-features=AutomationControlled",
]


class Browser:
    def __init__(self):
        self._pw = sync_playwright().start()
        self.context = self._pw.chromium.launch_persistent_context(
            user_data_dir=PROFILE,
            channel=CHANNEL,
            headless=False,
            no_viewport=True,
            ignore_default_args=["--enable-automation"],
            args=LAUNCH_ARGS,
        )
        self.context.on("page", lambda page: None)

    @property
    def page(self):
        pages = [p for p in self.context.pages if not p.is_closed()]
        if not pages:
            return self.context.new_page()
        # The most recently active page is the last opened one.
        return pages[-1]

    def status(self):
        try:
            page = self.page
            return {"running": True, "url": page.url, "title": page.title(),
                    "pages": len(self.context.pages)}
        except Exception as exc:  # noqa: BLE001
            return {"running": True, "url": "", "title": "", "error": str(exc)}

    def navigate(self, url, timeout=30000):
        # Add https:// only when the URL has no scheme at all; leave data:,
        # file:, about:, chrome: and friends untouched.
        if not re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", url):
            url = "https://" + url
        page = self.page
        page.goto(url, wait_until="domcontentloaded", timeout=timeout)
        return self.snapshot(page)

    def _human_move(self, page, x, y):
        # Approach the target in a few jittered steps instead of teleporting,
        # so the pointer path and timing resemble a hand, not a script.
        steps = random.randint(6, 12)
        page.mouse.move(x, y, steps=steps)
        time.sleep(random.uniform(0.03, 0.12))

    def _target_point(self, page, selector, timeout):
        locator = page.locator(selector).first
        locator.wait_for(state="visible", timeout=timeout)
        box = locator.bounding_box()
        if not box:
            return None
        # Aim for a random point inside the element, not dead center.
        x = box["x"] + box["width"] * random.uniform(0.3, 0.7)
        y = box["y"] + box["height"] * random.uniform(0.3, 0.7)
        return x, y

    def click(self, selector=None, x=None, y=None, timeout=15000):
        page = self.page
        if selector:
            point = self._target_point(page, selector, timeout)
            if point:
                self._human_move(page, point[0], point[1])
                page.mouse.click(point[0], point[1], delay=random.uniform(40, 110))
            else:
                page.click(selector, timeout=timeout)
        elif x is not None and y is not None:
            self._human_move(page, float(x), float(y))
            page.mouse.click(float(x), float(y), delay=random.uniform(40, 110))
        else:
            raise ValueError("click requires selector or x/y")
        page.wait_for_timeout(random.randint(300, 600))
        return self.snapshot(page)

    def _human_type(self, page, text):
        for ch in text:
            page.keyboard.type(ch)
            time.sleep(random.uniform(0.03, 0.14))
            if ch == " " and random.random() < 0.15:
                time.sleep(random.uniform(0.1, 0.25))  # occasional word pause

    def type_text(self, text, selector=None, enter=False, timeout=15000):
        page = self.page
        if selector:
            point = self._target_point(page, selector, timeout)
            if point:
                self._human_move(page, point[0], point[1])
                page.mouse.click(point[0], point[1], delay=random.uniform(40, 110))
            else:
                page.click(selector, timeout=timeout)
            time.sleep(random.uniform(0.1, 0.25))
        if text:
            self._human_type(page, text)
        if enter:
            time.sleep(random.uniform(0.15, 0.35))
            page.keyboard.press("Enter")
            page.wait_for_timeout(random.randint(400, 700))
        return self.snapshot(page)

    def detect(self):
        # Report the fingerprint vectors bot checks look at, so Her can
        # confirm the browser presents as a normal human Chrome.
        page = self.page
        return page.evaluate(
            """() => ({
                webdriver: navigator.webdriver,
                webdriver_present: 'webdriver' in navigator,
                languages: navigator.languages,
                plugins: navigator.plugins.length,
                has_chrome: !!window.chrome,
                has_chrome_runtime: !!(window.chrome && window.chrome.runtime),
                platform: navigator.platform,
                hardwareConcurrency: navigator.hardwareConcurrency,
                headless_ua: /Headless/.test(navigator.userAgent),
                webgl_vendor: (() => { try {
                    const gl = document.createElement('canvas').getContext('webgl');
                    const e = gl.getExtension('WEBGL_debug_renderer_info');
                    return gl.getParameter(e.UNMASKED_VENDOR_WEBGL);
                } catch (e) { return 'n/a'; } })(),
                permissions_ok: typeof navigator.permissions !== 'undefined'
            })"""
        )

    def press(self, key):
        page = self.page
        page.keyboard.press(key)
        page.wait_for_timeout(250)
        return self.snapshot(page)

    def read(self, max_chars=8000):
        page = self.page
        text = page.evaluate("() => document.body ? document.body.innerText : ''")
        links = page.evaluate(
            "() => Array.from(document.querySelectorAll('a[href]')).slice(0,40)"
            ".map(a => ({t: (a.innerText||'').trim().slice(0,60), href: a.href}))"
            ".filter(l => l.t)"
        )
        return {"url": page.url, "title": page.title(),
                "text": (text or "")[:max_chars], "links": links}

    def screenshot(self):
        page = self.page
        png = page.screenshot(type="png")
        return base64.b64encode(png).decode("ascii")

    def snapshot(self, page):
        return {"url": page.url, "title": page.title(),
                "screenshot": self.screenshot()}

    def close(self):
        try:
            self.context.close()
        finally:
            self._pw.stop()


BROWSER = None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authed(self):
        provided = self.headers.get("X-Browser-Token", "")
        if not TOKEN or provided != TOKEN:
            self._send(401, {"ok": False, "error": "invalid token"})
            return False
        return True

    def _body(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        if not length:
            return {}
        try:
            return json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception:  # noqa: BLE001
            return {}

    def log_message(self, *args):  # silence default stderr logging
        pass

    def do_GET(self):
        if not self._authed():
            return
        try:
            if self.path.startswith("/status"):
                self._send(200, {"ok": True, **BROWSER.status()})
            elif self.path.startswith("/screenshot"):
                self._send(200, {"ok": True, "screenshot": BROWSER.screenshot()})
            elif self.path.startswith("/read"):
                self._send(200, {"ok": True, **BROWSER.read()})
            elif self.path.startswith("/detect"):
                self._send(200, {"ok": True, "signals": BROWSER.detect()})
            else:
                self._send(404, {"ok": False, "error": "unknown path"})
        except Exception as exc:  # noqa: BLE001
            self._send(500, {"ok": False, "error": str(exc)})

    def do_POST(self):
        if not self._authed():
            return
        body = self._body()
        try:
            if self.path.startswith("/navigate"):
                self._send(200, {"ok": True, **BROWSER.navigate(body.get("url", ""))})
            elif self.path.startswith("/click"):
                self._send(200, {"ok": True, **BROWSER.click(
                    body.get("selector"), body.get("x"), body.get("y"))})
            elif self.path.startswith("/type"):
                self._send(200, {"ok": True, **BROWSER.type_text(
                    body.get("text", ""), body.get("selector"), bool(body.get("enter")))})
            elif self.path.startswith("/key"):
                self._send(200, {"ok": True, **BROWSER.press(body.get("key", "Enter"))})
            elif self.path.startswith("/shutdown"):
                self._send(200, {"ok": True})
                threading.Thread(target=self.server.shutdown, daemon=True).start()
            else:
                self._send(404, {"ok": False, "error": "unknown path"})
        except Exception as exc:  # noqa: BLE001
            self._send(500, {"ok": False, "error": str(exc)})


def main():
    global BROWSER
    if not PORT or not TOKEN:
        print("HER_BROWSER_PORT and HER_BROWSER_TOKEN are required", file=sys.stderr)
        sys.exit(2)
    os.makedirs(PROFILE, exist_ok=True)
    BROWSER = Browser()
    server = HTTPServer(("127.0.0.1", PORT), Handler)
    print(f"her-browser-sidecar listening on 127.0.0.1:{PORT}", flush=True)
    try:
        server.serve_forever()
    finally:
        BROWSER.close()


if __name__ == "__main__":
    main()
