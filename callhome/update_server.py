#!/usr/bin/env python3

import json
import os
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer


HOST = "0.0.0.0"
PORT = int(os.environ.get("INGRESS_PORT", "8099"))
SUPERVISOR_URL = os.environ.get("SUPERVISOR_URL", "http://supervisor")
SUPERVISOR_TOKEN = os.environ.get("SUPERVISOR_TOKEN", "")


def call_supervisor_update():
    if not SUPERVISOR_TOKEN:
        return False, "SUPERVISOR_TOKEN is not available"

    request = urllib.request.Request(
        f"{SUPERVISOR_URL}/addons/self/update",
        data=b"{}",
        method="POST",
        headers={
            "Authorization": f"Bearer {SUPERVISOR_TOKEN}",
            "Content-Type": "application/json",
        },
    )

    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = response.read().decode("utf-8")
            body = json.loads(payload) if payload else {}
            result = body.get("result")
            if result == "ok":
                return True, "Update started. The add-on will restart after completion."
            return False, body.get("message", "Supervisor returned a non-ok response")
    except urllib.error.HTTPError as error:
        details = error.read().decode("utf-8", errors="ignore")
        return False, f"HTTP {error.code}: {details or error.reason}"
    except Exception as error:
        return False, str(error)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self._render_page()

    def do_POST(self):
        if self.path != "/update":
            self.send_error(404)
            return

        success, message = call_supervisor_update()
        self._render_page(success=success, message=message)

    def _render_page(self, success=None, message=""):
        status = ""
        if message:
            status_class = "ok" if success else "err"
            status = f'<p class="{status_class}">{message}</p>'

        html = f"""<!doctype html>
<html lang=\"en\">
<head>
  <meta charset=\"utf-8\" />
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />
  <title>SSH Call Home</title>
</head>
<body>
    <main>
        <h2>SSH Call Home</h2>
        <p>Use this control to update the add-on to the latest available version.</p>
        <form method=\"post\" action=\"/update\">
            <button type=\"submit\">Update to latest version</button>
    </form>
    {status}
    </main>
</body>
</html>
"""

        payload = html.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_args):
        return


def main():
    server = HTTPServer((HOST, PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
