#!/usr/bin/env python3
"""Local HTTP server used by tools/test-downloader.sh.

Serves the same payload under several "mirror" behaviours so the download
engine can be tested without a real network:

    /good/<file>     correct payload, supports Range requests
    /good2/<file>    same payload (a second, healthy mirror)
    /missing/<file>  404
    /html/<file>     200 with a captive-portal style HTML page
    /trunc/<file>    200, but only the first 40% of the payload
    /stall/<file>    200, sends 50% and then stalls forever

Usage: test-server.py <port> <asset-dir>
"""

import http.server
import os
import socketserver
import sys
import time

PORT = int(sys.argv[1])
ASSET_DIR = sys.argv[2]
HTML_PAGE = (b"<!DOCTYPE html><html><head><title>Sign in</title></head><body>"
             b"Please sign in to the Wi-Fi network to continue."
             b"<!-- " + b"x" * 8192 + b" --></body></html>")
STALL_SECONDS = 30


def asset(name):
    with open(os.path.join(ASSET_DIR, name), "rb") as fh:
        return fh.read()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # keep the test output readable
        pass

    def do_GET(self):
        parts = self.path.lstrip("/").split("/", 1)
        variant = parts[0]
        name = parts[1].split("?")[0] if len(parts) > 1 else ""

        if variant in ("good", "good2"):
            self.serve_asset(name, range_support=True)
        elif variant == "missing":
            self.fail(404, "The file you requested could not be found")
        elif variant == "html":
            self.send_payload(HTML_PAGE, name, "text/html")
        elif variant == "trunc":
            data = asset(name)
            self.send_payload(data[: int(len(data) * 0.4)], name, "application/octet-stream")
        elif variant == "stall":
            self.serve_stall(name)
        else:
            self.fail(404, "unknown test variant")

    # -- helpers ---------------------------------------------------------
    def fail(self, code, text):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_payload(self, data, name, ctype, extra_headers=()):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Accept-Ranges", "bytes")
        for key, value in extra_headers:
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def serve_asset(self, name, range_support):
        try:
            data = asset(name)
        except OSError:
            self.fail(404, "no such asset")
            return

        rng = self.headers.get("Range")
        if range_support and rng and rng.startswith("bytes="):
            spec = rng[len("bytes="):].strip()
            start_s, _, end_s = spec.partition("-")
            try:
                start = int(start_s) if start_s else 0
                end = int(end_s) if end_s else len(data) - 1
            except ValueError:
                self.fail(400, "bad range")
                return
            if start >= len(data):
                # exactly what a real server does when the file is complete
                self.send_response(416)
                self.send_header("Content-Range", "bytes */%d" % len(data))
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            chunk = data[start:end + 1]
            self.send_response(206)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(chunk)))
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, len(data)))
            self.send_header("Accept-Ranges", "bytes")
            self.end_headers()
            self.wfile.write(chunk)
            return

        self.send_payload(data, name, "application/octet-stream")

    def serve_stall(self, name):
        """Send half of the payload, then keep the connection open doing
        nothing - the way a dead mobile connection behaves."""
        try:
            data = asset(name)
        except OSError:
            self.fail(404, "no such asset")
            return
        half = data[: len(data) // 2]
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        try:
            self.wfile.write(half)
            self.wfile.flush()
            time.sleep(STALL_SECONDS)
        except (BrokenPipeError, ConnectionResetError):
            pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def handle_error(self, request, client_address):
        # clients abort stalled/truncated transfers on purpose in the tests,
        # so a reset connection is expected and must not print a traceback
        exc = sys.exc_info()[1]
        if isinstance(exc, (BrokenPipeError, ConnectionResetError)):
            return
        super().handle_error(request, client_address)


if __name__ == "__main__":
    Server(("127.0.0.1", PORT), Handler).serve_forever()
