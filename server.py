#!/usr/bin/env python3
"""StockGrid: serves the page and proxies Yahoo Finance chart data (no dependencies)."""
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", sys.argv[1] if len(sys.argv) > 1 else 8765))
ROOT = os.path.dirname(os.path.abspath(__file__))
SYMBOL_RE = re.compile(r"^[A-Z0-9.\-^=]{1,15}$")
RANGES = {
    "1d": "5m",
    "5d": "15m",
    "1mo": "1d",
    "6mo": "1d",
    "ytd": "1d",
    "1y": "1d",
    "2y": "1d",
    "5y": "1wk",
}


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s\n" % (fmt % args))

    def send_json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        if url.path != "/api/chart":
            if url.path not in ("/", "/index.html"):
                self.send_error(404)
                return
            return super().do_GET()

        qs = urllib.parse.parse_qs(url.query)
        symbol = qs.get("symbol", [""])[0].upper()
        rng = qs.get("range", ["6mo"])[0]
        if not SYMBOL_RE.match(symbol):
            return self.send_json(400, {"error": "Invalid symbol"})
        if rng not in RANGES:
            return self.send_json(400, {"error": "Invalid range"})

        upstream = (
            "https://query1.finance.yahoo.com/v8/finance/chart/"
            + urllib.parse.quote(symbol)
            + "?"
            + urllib.parse.urlencode({"range": rng, "interval": RANGES[rng], "includePrePost": "false"})
        )
        req = urllib.request.Request(upstream, headers={"User-Agent": "Mozilla/5.0"})
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.load(resp)
        except urllib.error.HTTPError as e:
            try:
                data = json.load(e)
            except Exception:
                return self.send_json(502, {"error": f"Data provider returned {e.code}"})
        except Exception as e:
            return self.send_json(502, {"error": f"Could not reach data provider: {e}"})

        chart = data.get("chart") or {}
        if chart.get("error") or not chart.get("result"):
            msg = (chart.get("error") or {}).get("description") or "No data for this symbol"
            return self.send_json(404, {"error": msg})
        self.send_json(200, data)

if __name__ == "__main__":
    try:
        server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    except OSError as e:
        if e.errno == 48:
            sys.exit(
                f"Port {PORT} is already in use, so StockGrid is probably already running.\n"
                f"Open http://localhost:{PORT} in your browser.\n"
                f"To use a different port instead: python3 {os.path.abspath(__file__)} 8766"
            )
        raise
    print(f"StockGrid running at http://localhost:{PORT}  (Ctrl-C to stop)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
