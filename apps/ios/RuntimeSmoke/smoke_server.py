#!/usr/bin/env python3
"""Fixture server for the iOS simulator runtime smoke test.

It serves apps/scripts/mock_consumer_server.py unchanged and adds, for the smoke test only:

* asset transfer grants, so the app's background URLSession path runs: a grant is
  minted with the bearer and then authorizes GET/HEAD of one asset with no bearer;
* a control port that takes the API offline (listener closed and live connections
  dropped) and back online, so the app can be relaunched without a connection;
* counters that let the test prove downloads used grants and never sent the bearer
  with them;
* a record of progress writes per publication (count, and the latest body's
  `observed_at`, `resolve_conflict` and place, with the asset and page of a PDF or
  comic place), so the test can check activity times and that reopening a saved place
  writes nothing;
* `POST /place` on the control port, which saves a page place as another device would
  (`{"publication", "asset", "page"}`), including a page the file doesn't have.

Development only: no real security, in memory, bound to 127.0.0.1.

    python3 apps/ios/RuntimeSmoke/smoke_server.py --port 8765 --control-port 8766
"""

import argparse
import json
import os
import re
import secrets
import socket
import socketserver
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scripts"))
import mock_consumer_server as mock  # noqa: E402

GRANT_SECONDS = 3600


class Stats:
    def __init__(self):
        self.lock = threading.Lock()
        self.values = {
            "grants_minted": 0,
            "grant_requests": 0,
            "grant_requests_with_bearer": 0,
            "grant_rejections": 0,
            "bearer_content_requests": 0,
        }

    def bump(self, key):
        with self.lock:
            self.values[key] += 1

    def snapshot(self):
        with self.lock:
            return dict(self.values)


class ProgressLog:
    """Progress PUT bodies as the app sent them, before the mock applies them."""

    def __init__(self):
        self.lock = threading.Lock()
        self.writes = {}

    def record(self, publication_id, body):
        locator = body.get("locator") if isinstance(body.get("locator"), dict) else {}
        locations = locator.get("locations") if isinstance(locator.get("locations"), dict) else {}
        entry = {
            "observed_at": body.get("observed_at"),
            "resolve_conflict": body.get("resolve_conflict"),
            "position_seconds": body.get("position_seconds"),
            "has_locator": body.get("locator") is not None,
            "client_mutation_id": body.get("client_mutation_id"),
            "asset_id": body.get("asset_id"),
            "page": locations.get("position"),
            "href": locator.get("href"),
        }
        with self.lock:
            log = self.writes.setdefault(publication_id, {"count": 0, "last": None, "resolving": 0, "without_observed_at": 0})
            log["count"] += 1
            log["last"] = entry
            if entry["resolve_conflict"] is True:
                log["resolving"] += 1
            if not entry["observed_at"]:
                log["without_observed_at"] += 1

    def snapshot(self):
        with self.lock:
            return json.loads(json.dumps(self.writes))


STATS = Stats()
PROGRESS_LOG = ProgressLog()
PROGRESS = re.compile(mock.PREFIX + r"/library/([^/]+)/progress")
GRANTS = {}
GRANTS_LOCK = threading.Lock()
CONTENT = re.compile(mock.PREFIX + r"/assets/([^/]+)/content")


class QuickServer(ThreadingHTTPServer):
    """Binds without HTTPServer.server_bind's socket.getfqdn() reverse DNS lookup.

    That lookup only fills in a name the handlers never read, and on CI Macs it can take
    longer than the test's 15-second request timeout. It ran at startup (the iPad server
    once took more than 10 seconds to print its first line) and on every return online:
    on the iOS 26 iPhone lane the control port answered POST /online only after the test
    had given up, so the test failed with "timeout" and the server's late reply hit a
    reset connection.
    """

    daemon_threads = True

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port


class Switch:
    def __init__(self, host, port):
        self.host = host
        self.port = port
        self.server = None
        self.offline = False
        self.lock = threading.Lock()
        self.connections = set()

    def opened(self, connection):
        with self.lock:
            self.connections.add(connection)

    def closed(self, connection):
        with self.lock:
            self.connections.discard(connection)

    def up(self):
        with self.lock:
            if self.server is not None:
                return
            self.offline = False
            server = QuickServer((self.host, self.port), SmokeHandler)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            self.server = server

    def down(self):
        with self.lock:
            self.offline = True
            server, self.server = self.server, None
            live, self.connections = self.connections, set()
        for connection in live:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        if server is not None:
            server.shutdown()
            server.server_close()


SWITCH = None


class SmokeHandler(mock.Handler):
    def setup(self):
        super().setup()
        SWITCH.opened(self.connection)

    def finish(self):
        SWITCH.closed(self.connection)
        super().finish()

    def parse_request(self):
        # Keep-alive connections opened before going offline must fail too.
        if SWITCH.offline:
            self.close_connection = True
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            return False
        return super().parse_request()

    def body(self):
        data = super().body()
        match = PROGRESS.fullmatch(self.route()) if self.command == "PUT" else None
        if match and isinstance(data, dict):
            PROGRESS_LOG.record(match[1], data)
        return data

    def authorized(self, scope=None):
        grant = parse_qs(urlparse(self.path).query).get("grant", [None])[0]
        path = self.route()
        if grant is None:
            if CONTENT.fullmatch(path) and self.command == "GET":
                STATS.bump("bearer_content_requests")
            return super().authorized(scope)
        STATS.bump("grant_requests")
        if "Authorization" in self.headers:
            STATS.bump("grant_requests_with_bearer")
        match = CONTENT.fullmatch(path)
        with GRANTS_LOCK:
            entry = GRANTS.get(grant)
        if match and entry and entry["asset"] == match[1] and entry["expires"] > time.time() \
                and self.command in ("GET", "HEAD"):
            return True
        STATS.bump("grant_rejections")
        self.respond(401, {"error": "invalid_grant"})
        return False

    def do_POST(self):
        match = re.fullmatch(mock.PREFIX + r"/library/([^/]+)/assets/([^/]+)/transfer_grant", self.route())
        if not match:
            return super().do_POST()
        self.body()
        if not super().authorized():
            return None
        book = self.state.books.get(match[1])
        if book is None or match[2] not in book[3]:
            return self.respond(404, {"error": "not_found"})
        grant = secrets.token_urlsafe(24)
        expires = time.time() + GRANT_SECONDS
        with GRANTS_LOCK:
            GRANTS[grant] = {"asset": match[2], "expires": expires}
        STATS.bump("grants_minted")
        return self.respond(201, {
            "url": f"{self.base}{mock.PREFIX}/assets/{match[2]}/content?grant={grant}",
            "expires_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(expires)),
        })


def save_place(request):
    """Another device's page place, observed a minute ago. Not validated against the page
    count: a PDF place past the end is exactly what the reader must keep."""
    state = mock.Handler.state
    publication, asset, page = request["publication"], request["asset"], int(request["page"])
    if state.files[asset][2] == "pdf":
        locator = {"href": "document.pdf", "type": "application/pdf",
                   "locations": {"position": page, "fragments": [f"page={page}"]}}
    else:
        item = state.orders[asset][page - 1]
        locator = {"href": item["href"], "type": item["media_type"], "locations": {"position": page}}
    observed = time.time() - 60
    with state.lock:
        current = state.progress.get(publication)
        saved = {"asset_id": asset, "locator": locator, "position_seconds": None,
                 "observed_at": mock.format_time(observed), "version": (current["version"] if current else 0) + 1,
                 "updated_at": mock.format_time(time.time()), "client_mutation_id": str(uuid.uuid4())}
        state.progress[publication] = saved
        state.touch(publication, observed)
    return {"progress": saved}


class ControlHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print(f"control {self.command} {self.path}", flush=True)

    def reply(self, payload):
        data = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        if self.path == "/place":
            self.reply(save_place(json.loads(body or b"{}")))
            return
        if self.path == "/offline":
            SWITCH.down()
        elif self.path == "/online":
            SWITCH.up()
        else:
            self.send_error(404)
            return
        self.reply({"offline": SWITCH.offline})

    def do_GET(self):
        if self.path != "/stats":
            self.send_error(404)
            return
        self.reply(dict(STATS.snapshot(), offline=SWITCH.offline, progress_writes=PROGRESS_LOG.snapshot()))


def main():
    global SWITCH
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--control-port", type=int, default=8766)
    parser.add_argument("--extra-books", type=int, default=34, help="Enough to need a second library page")
    args = parser.parse_args()

    mock.Handler.state = mock.State(True, 0, False, args.extra_books)
    mock.Handler.base = ""
    SWITCH = Switch("127.0.0.1", args.port)
    SWITCH.up()
    control = QuickServer(("127.0.0.1", args.control_port), ControlHandler)
    print(f"Smoke API on http://127.0.0.1:{args.port}, control on http://127.0.0.1:{args.control_port}", flush=True)
    control.serve_forever()


if __name__ == "__main__":
    main()
