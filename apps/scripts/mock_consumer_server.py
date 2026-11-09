#!/usr/bin/env python3
"""A development stand-in for the Shelfarr consumer API.

It follows the contract in docs/native-consumer.md closely enough to exercise a
native client end to end: device authorization, a tiny library, byte ranges,
ETags and versioned progress. It keeps everything in memory, has no real
security and must never be exposed beyond a development machine.

    python3 apps/scripts/mock_consumer_server.py --port 8099 --base /shelfarr

Approve a pending device by opening its verification URL, or start with
--auto-approve. Use --conflict-after N to answer the Nth progress write with a
conflict, to see how a client handles another device moving on; that place's
activity time is unknown unless --conflict-observed older|newer sets it a minute
either side of the conflicting write's observed_at. Progress follows the
observed_at/resolve_conflict rules in docs/consumer-api.md. Use
--extra-books N to add N more small mock books, enough to page the library and
to see Continue find a book beyond the first page.

Requesting: tokens get the read/listen pair unless the app asks for the
requesting bundle (an already connected app asks with its bearer and keeps its
account). /discover searches a small fixture catalogue and /requests follows a
request one stage per poll until a new fixture book appears in the library.
--grant-requesting gives every new token the requesting bundle,
--old-server behaves like a server without requesting (no consumer_features,
scope ignored), and --request-outcome not_found|failed ends new requests there.
Nothing is acquired or bought.
"""

import argparse
import hashlib
import io
import json
import math
import re
import struct
import threading
import time
import uuid
import wave
import zipfile
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PREFIX = "/api/consumer/v1"
BASE_SCOPES = ["library:read", "progress:write"]
REQUEST_SCOPES = ["search:read", "requests:read", "requests:write"]
# Fixture catalogue: (work_id, title, author, year, series). "work-in-library"
# matches book-1, and "work-elsewhere" has an audiobook someone else requested.
CATALOGUE = [
    ("mock:work-lighthouse", "The Lighthouse Keeper", "Mara Quill", 2019, "Coastline"),
    ("mock:work-in-library", "A Test Book", "Mock Author", 2021, None),
    ("mock:work-elsewhere", "Rivers Remember", "Tomas Vey", 2016, None),
    ("mock:work-orchard", "Orchard Hours", "Ines Calder", 2023, None),
]
# One step per poll: (stage, download percent).
STEPS = [("queued", None), ("searching", None), ("downloading", 30), ("downloading", 70), ("processing", None), ("available", None)]
OBSERVED_AT = re.compile(
    r"(\d{4})-(\d{2})-(\d{2})T([01]\d|2[0-3]):([0-5]\d):([0-5]\d)(\.\d{1,9})?(Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)")


def parse_observed_at(value):
    """Return epoch seconds (millisecond precision) or None when unknown."""
    if value is None:
        return None
    match = OBSERVED_AT.fullmatch(value) if isinstance(value, str) else None
    if not match:
        raise ValueError("observed_at must be an ISO-8601 time with a time zone")
    fraction = (match[7] or ".0")[:4].ljust(4, "0")
    zone = "+00:00" if match[8] == "Z" else match[8]
    try:
        parsed = datetime.fromisoformat(f"{match[1]}-{match[2]}-{match[3]}T{match[4]}:{match[5]}:{match[6]}{fraction}{zone}")
    except ValueError as error:
        raise ValueError("observed_at must be an ISO-8601 time with a time zone") from error
    seconds = math.floor(parsed.timestamp() * 1000) / 1000
    if seconds > time.time() + 300:
        raise ValueError("observed_at is too far in the future; check this device's clock")
    return seconds


def format_time(seconds):
    if seconds is None:
        return None
    moment = datetime.fromtimestamp(seconds, timezone.utc)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.") + f"{moment.microsecond // 1000:03d}Z"


def chronological(current, place, observed):
    """A known later stored activity cannot be replaced by an earlier one."""
    stored = parse_stored(current.get("observed_at"))
    if stored is None or observed is None or observed > stored:
        return True
    same_place = all(current.get(key) == place[key] for key in ("asset_id", "locator", "position_seconds"))
    return observed == stored and same_place


def parse_stored(value):
    if value is None:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def build_epub():
    chapters = [
        ("Winter", "The rain had stopped by the time she reached the harbour. " * 90),
        ("The Long Road", "Nothing in the valley was quite where the old maps put it. " * 120),
        ("Home", "By the third evening the house had begun to feel familiar. " * 100),
    ]
    manifest = "".join(
        f'<item id="c{n}" href="c{n}.xhtml" media-type="application/xhtml+xml"/>'
        for n in range(len(chapters))
    )
    spine = "".join(f'<itemref idref="c{n}"/>' for n in range(len(chapters)))
    toc = "".join(
        f'<li><a href="c{n}.xhtml">{title}</a></li>' for n, (title, _) in enumerate(chapters)
    )
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as book:
        book.writestr(
            zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED
        )
        book.writestr(
            "META-INF/container.xml",
            '<?xml version="1.0"?><container version="1.0" '
            'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
            '<rootfile full-path="OEBPS/content.opf" '
            'media-type="application/oebps-package+xml"/></rootfiles></container>',
        )
        book.writestr(
            "OEBPS/content.opf",
            '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
            'unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
            '<dc:identifier id="id">urn:shelfarr:mock</dc:identifier>'
            "<dc:title>A Test Book</dc:title><dc:language>en</dc:language></metadata><manifest>"
            '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
            f"{manifest}</manifest><spine>{spine}</spine></package>",
        )
        book.writestr(
            "OEBPS/nav.xhtml",
            '<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml" '
            'xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head>'
            '<body><nav epub:type="toc"><ol>'
            f"{toc}</ol></nav></body></html>",
        )
        for n, (title, text) in enumerate(chapters):
            book.writestr(
                f"OEBPS/c{n}.xhtml",
                '<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml">'
                f"<head><title>{title}</title></head><body><h1>{title}</h1><p>{text}</p></body></html>",
            )
    return buffer.getvalue()


def build_tone(seconds, hertz):
    rate = 16000
    frames = bytearray()
    for n in range(rate * seconds):
        frames += struct.pack("<h", int(6000 * math.sin(2 * math.pi * hertz * n / rate)))
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(rate)
        audio.writeframes(bytes(frames))
    return buffer.getvalue()


class State:
    def __init__(self, auto_approve, conflict_after, slow_down, extra_books=0, conflict_observed="unknown",
                 grant_requesting=False, old_server=False, request_outcome="available"):
        self.lock = threading.Lock()
        self.grant_requesting = grant_requesting
        self.old_server = old_server
        self.request_outcome = request_outcome
        self.requests = {}
        self.request_counter = 0
        self.auto_approve = auto_approve
        self.conflict_after = conflict_after
        self.conflict_observed = conflict_observed
        self.slow_down = slow_down
        self.devices = {}
        self.tokens = {}
        self.progress = {}
        self.statuses = {}
        self.activity = {}
        self.writes = 0
        self.files = {
            "epub-1": ("a-test-book.epub", "application/epub+zip", "epub", build_epub()),
            "track-1": ("Part 1.wav", "audio/wav", "wav", build_tone(45, 330)),
            "track-2": ("Part 2.wav", "audio/wav", "wav", build_tone(45, 440)),
        }
        self.books = {
            "book-1": ("A Test Book", "Mock Author", "ebook", ["epub-1"]),
            "audio-1": ("A Test Audiobook", "Mock Narrator", "audiobook", ["track-1", "track-2"]),
        }
        epub = self.files["epub-1"]
        for n in range(1, extra_books + 1):
            self.files[f"epub-x{n}"] = (f"mock-{n}.epub",) + epub[1:]
            self.books[f"book-x{n}"] = (f"Mock Book {n:03d}", "Mock Author", "ebook", [f"epub-x{n}"])

    def request_view(self, request_id):
        r = self.requests[request_id]
        stage = r["stage"]
        return {
            "id": request_id, "status": {"queued": "pending", "available": "completed"}.get(stage, stage),
            "stage": stage, "attention_needed": False, "title": r["title"], "author": r["author"],
            "book_type": r["book_type"], "cover_url": None,
            "download_percent": r.get("percent") if stage == "downloading" else None,
            "can_cancel": stage not in ("available", "failed"), "next_retry_at": None,
            "publication_id": r.get("publication_id") if stage == "available" else None,
            "created_at": r["created_at"], "updated_at": r["updated_at"],
        }

    def advance(self, request_id):
        """Moves an open request one stage on, as polling would observe it."""
        r = self.requests[request_id]
        if r["stage"] in ("available", "failed", "not_found"):
            return
        if r["stage"] == "searching" and self.request_outcome in ("not_found", "failed"):
            r["stage"] = self.request_outcome
        else:
            r["step"] = r.get("step", 0) + 1
            r["stage"], r["percent"] = STEPS[r["step"]]
        r["updated_at"] = format_time(time.time())
        if r["stage"] == "available" and not r.get("publication_id"):
            publication_id = f"req-{request_id}"
            assets = ["epub-1"] if r["book_type"] == "ebook" else ["track-1", "track-2"]
            self.books[publication_id] = (r["title"], r["author"], r["book_type"], assets)
            r["publication_id"] = publication_id

    def format_state(self, work_id, book_type):
        if work_id == "mock:work-in-library" and book_type == "ebook":
            return {"book_type": book_type, "state": "in_library", "publication_id": "book-1", "request": None}
        if work_id == "mock:work-elsewhere" and book_type == "audiobook":
            return {"book_type": book_type, "state": "requested_by_someone", "publication_id": None, "request": None}
        for request_id, r in self.requests.items():
            if r["work_id"] == work_id and r["book_type"] == book_type:
                if r["stage"] == "available":
                    return {"book_type": book_type, "state": "in_library", "publication_id": r["publication_id"], "request": None}
                if r["stage"] not in ("failed", "not_found"):
                    return {"book_type": book_type, "state": "requested", "publication_id": None, "request": self.request_view(request_id)}
        return {"book_type": book_type, "state": "requestable", "publication_id": None, "request": None}

    def touch(self, publication_id, at=None):
        self.activity[publication_id] = time.time() if at is None else at

    def status(self, publication_id):
        if publication_id in self.statuses:
            return self.statuses[publication_id]
        return "in_progress" if self.progress.get(publication_id) else "unread"

    def asset(self, base, asset_id, position):
        name, media_type, fmt, data = self.files[asset_id]
        return {
            "id": asset_id,
            "filename": name,
            "media_type": media_type,
            "format": fmt,
            "size_bytes": len(data),
            "content_url": f"{base}{PREFIX}/assets/{asset_id}/content",
            "position": position,
        }

    def publication(self, base, publication_id):
        title, author, kind, assets = self.books[publication_id]
        return {
            "id": publication_id,
            "title": title,
            "author": author,
            "description": "Development fixture served by mock_consumer_server.py.",
            "book_type": kind,
            "cover_url": None,
            "assets": [self.asset(base, a, n) for n, a in enumerate(assets)],
            "progress": self.progress.get(publication_id),
            "reading_status": self.status(publication_id),
        }

    def listing(self, base, query):
        kind = query.get("type", [None])[0]
        status = query.get("status", [None])[0]
        text = (query.get("q", [""])[0] or "").lower()
        items = [self.publication(base, p) for p in self.books]
        items = [i for i in items if kind in (None, i["book_type"])]
        items = [i for i in items if status in (None, i["reading_status"])]
        items = [i for i in items if text in i["title"].lower() or text in (i["author"] or "").lower()]
        if query.get("sort", ["recent"])[0] == "title":
            items.sort(key=lambda i: i["title"].lower())
        else:
            items.sort(key=lambda i: (-self.activity.get(i["id"], 0), i["title"].lower()))
        return items


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    state = None
    base = ""

    def log_message(self, fmt, *args):
        print(f"{self.command} {self.path.split('?')[0]} -> {args[1] if len(args) > 1 else ''}", flush=True)

    def parse_request(self):
        self._raw_body = None
        return super().parse_request()

    def raw_body(self):
        if self._raw_body is None:
            length = int(self.headers.get("Content-Length") or 0)
            self._raw_body = self.rfile.read(length) if length else b""
        return self._raw_body

    def body(self):
        return json.loads(self.raw_body() or b"{}")

    def respond(self, code, payload=None):
        # Every request body is read before answering, also when a handler doesn't need
        # it (auth/revoke, refusals): on a keep-alive connection an unread body would be
        # parsed as the start of the next request ("{}GET ...", 501).
        self.raw_body()
        data = b"" if payload is None else json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def route(self):
        path = urlparse(self.path).path
        if self.base and path.startswith(self.base + "/"):
            path = path[len(self.base):]
        return path

    def bearer(self):
        header = self.headers.get("Authorization", "")
        return header[7:] if header.startswith("Bearer ") else None

    def authorized(self, scope=None):
        token = self.bearer()
        if token not in self.state.tokens:
            self.respond(401, {"error": "invalid_token"})
            return False
        if scope and scope not in self.state.tokens[token]:
            self.respond(403, {"error": "insufficient_scope", "required_scope": scope})
            return False
        return True

    def do_POST(self):
        path = self.route()
        if path == f"{PREFIX}/auth/device":
            body = self.body()
            scopes = BASE_SCOPES + (REQUEST_SCOPES if self.state.grant_requesting else [])
            if not self.state.old_server and "scope" in body:
                asked = str(body["scope"]).split()
                extra = [x for x in asked if x not in BASE_SCOPES]
                if sorted(extra) not in ([], sorted(REQUEST_SCOPES)):
                    return self.respond(400, {"error": "invalid_scope"})
                if extra:
                    scopes = BASE_SCOPES + REQUEST_SCOPES
            replaces = None
            if self.bearer() is not None and not self.state.old_server:
                if self.bearer() not in self.state.tokens:
                    return self.respond(401, {"error": "invalid_token"})
                replaces = self.bearer()
            device_code = uuid.uuid4().hex
            user_code = uuid.uuid4().hex[:8].upper()
            user_code = f"{user_code[:4]}-{user_code[4:]}"
            host = f"http://{self.headers['Host']}{self.base}"
            with self.state.lock:
                self.state.devices[device_code] = {
                    "user_code": user_code,
                    "approved": self.state.auto_approve,
                    "polls": 0,
                    "expires": time.time() + 600,
                    "scopes": scopes,
                    "replaces": replaces,
                }
            self.respond(200, {
                "device_code": device_code,
                "user_code": user_code,
                "verification_uri": f"{host}/device",
                "verification_uri_complete": f"{host}/device?user_code={user_code}",
                "expires_in": 600,
                "interval": 5,
            })
        elif path == f"{PREFIX}/auth/token":
            with self.state.lock:
                self.body_device_code = self.body().get("device_code")
                device = self.state.devices.get(self.body_device_code)
                if device is None or device["expires"] < time.time():
                    return self.respond(400, {"error": "expired_token"})
                device["polls"] += 1
                if self.state.slow_down and device["polls"] == 1:
                    return self.respond(400, {"error": "slow_down"})
                if not device["approved"]:
                    return self.respond(400, {"error": "authorization_pending"})
                token = uuid.uuid4().hex
                self.state.tokens[token] = device["scopes"]
                # The replaced token stays valid; the real server retires it on first use.
                self.state.devices.pop(self.body_device_code, None)
            self.respond(200, {
                "access_token": token,
                "token_type": "Bearer",
                "scope": " ".join(device["scopes"]),
                "expires_in": 2592000,
            })
        elif path == f"{PREFIX}/auth/revoke":
            if self.authorized():
                self.state.tokens.pop(self.bearer(), None)
                self.respond(204)
        elif path == f"{PREFIX}/requests" and not self.state.old_server:
            if not self.authorized("requests:write"):
                return None
            body = self.body()
            work = next((w for w in CATALOGUE if w[0] == body.get("work_id")), None)
            if work is None or body.get("book_type") not in ("ebook", "audiobook") or not body.get("title"):
                return self.respond(422, {"error": "invalid_request"})
            with self.state.lock:
                current = self.state.format_state(work[0], body["book_type"])
                if current["state"] == "in_library":
                    return self.respond(409, {"error": "already_in_library", "message": "Already in the library.",
                                              "publication_id": current["publication_id"]})
                if current["state"] == "requested_by_someone":
                    return self.respond(409, {"error": "already_requested", "message":
                                              "Someone on this server has already requested this. It will appear in the library when it arrives."})
                if current["state"] == "requested":
                    return self.respond(200, {"request": current["request"], "existing": True})
                self.state.request_counter += 1
                request_id = f"r{self.state.request_counter}"
                now = format_time(time.time())
                self.state.requests[request_id] = {"work_id": work[0], "title": work[1], "author": work[2],
                                                   "book_type": body["book_type"], "stage": "queued",
                                                   "created_at": now, "updated_at": now}
                return self.respond(201, {"request": self.state.request_view(request_id), "warnings": []})
        else:
            self.respond(404, {"error": "not_found"})

    def do_DELETE(self):
        match = re.fullmatch(PREFIX + r"/requests/([^/]+)", self.route())
        if not match or self.state.old_server:
            return self.respond(404, {"error": "not_found"})
        if not self.authorized("requests:write"):
            return None
        with self.state.lock:
            r = self.state.requests.get(match[1])
            if r is None:
                return self.respond(404, {"error": "not_found"})
            if r["stage"] in ("available", "processing"):
                return self.respond(422, {"error": "cannot_cancel", "message": "This request is being finished and can't be cancelled now."})
            r["stage"] = "failed"
            r["updated_at"] = format_time(time.time())
            return self.respond(200, {"request": self.state.request_view(match[1])})

    def do_GET(self):
        path = self.route()
        if path == "/device":
            return self.approve()
        if path == f"{PREFIX}/server.json":
            payload = {"schema_version": 1, "server_version": "mock", "consumer_api_versions": [1], "android": {}}
            if not self.state.old_server:
                payload["consumer_features"] = ["requests"]
            return self.respond(200, payload)
        if not self.authorized():
            return
        with self.state.lock:
            if path == f"{PREFIX}/me":
                me = {"id": "user-1", "name": "Mock Reader", "username": "mock"}
                if not self.state.old_server:
                    me["scopes"] = self.state.tokens[self.bearer()]
                return self.respond(200, me)
            query = parse_qs(urlparse(self.path).query)
            if path == f"{PREFIX}/discover" and not self.state.old_server:
                if "search:read" not in self.state.tokens[self.bearer()]:
                    return self.respond(403, {"error": "insufficient_scope", "required_scope": "search:read"})
                text = (query.get("q", [""])[0] or "").strip().lower()
                if not text:
                    return self.respond(422, {"error": "invalid_query"})
                hits = [w for w in CATALOGUE if text in w[1].lower() or text in w[2].lower()]
                return self.respond(200, {"items": [{
                    "id": w[0], "work_id": w[0], "source_work_ids": [], "title": w[1], "author": w[2], "year": w[3],
                    "description": f"Fixture catalogue entry for {w[1]}.", "cover_url": None, "series_name": w[4],
                    "series_position": "1" if w[4] else None, "source_name": "Mock catalogue",
                    "formats": [self.state.format_state(w[0], t) for t in ("ebook", "audiobook")],
                } for w in hits]})
            request_match = re.fullmatch(PREFIX + r"/requests(?:/([^/]+))?", path)
            if request_match and not self.state.old_server:
                if "requests:read" not in self.state.tokens[self.bearer()]:
                    return self.respond(403, {"error": "insufficient_scope", "required_scope": "requests:read"})
                if request_match[1]:
                    if request_match[1] not in self.state.requests:
                        return self.respond(404, {"error": "not_found"})
                    self.state.advance(request_match[1])
                    return self.respond(200, {"request": self.state.request_view(request_match[1])})
                for request_id in self.state.requests:
                    self.state.advance(request_id)
                ordered = sorted(self.state.requests, key=lambda i: self.state.requests[i]["updated_at"], reverse=True)
                return self.respond(200, {"items": [self.state.request_view(i) for i in ordered]})
            if path == f"{PREFIX}/library":
                # The cursor binds every filter and the sort, as the real API's does.
                bound = json.dumps({k: query.get(k) for k in ("type", "status", "sort", "q")}, sort_keys=True)
                start = 0
                if "cursor" in query:
                    offset, _, key = query["cursor"][0].partition(":")
                    if key != hashlib.sha256(bound.encode()).hexdigest()[:12]:
                        return self.respond(400, {"error": "invalid_cursor"})
                    start = int(offset)
                limit = max(1, min(int(query.get("limit", ["30"])[0]), 100))
                items = self.state.listing(self.base, query)
                page = items[start:start + limit]
                more = start + limit < len(items)
                cursor = f"{start + limit}:{hashlib.sha256(bound.encode()).hexdigest()[:12]}" if more else None
                return self.respond(200, {"items": page, "next_cursor": cursor})
            if path == f"{PREFIX}/continue":
                limit = max(1, min(int(query.get("limit", ["10"])[0]), 50))
                items = [self.state.publication(self.base, p) for p in self.state.books]
                items = [i for i in items if i["id"] in self.state.activity]
                items.sort(key=lambda i: -self.state.activity[i["id"]])
                return self.respond(200, {"items": items[:limit]})
            match = re.fullmatch(PREFIX + r"/library/([^/]+)(/progress)?", path)
            if match and match[1] in self.state.books:
                publication = self.state.publication(self.base, match[1])
                if match[2]:
                    return self.respond(200, {"progress": publication["progress"]})
                return self.respond(200, publication)
        match = re.fullmatch(PREFIX + r"/assets/([^/]+)/content", path)
        if match and match[1] in self.state.files:
            return self.serve(self.state.files[match[1]])
        self.respond(404, {"error": "not_found"})

    do_HEAD = do_GET

    def do_PUT(self):
        status_match = re.fullmatch(PREFIX + r"/library/([^/]+)/reading_status", self.route())
        if status_match:
            if not self.authorized():
                return None
            status = self.body().get("status")
            with self.state.lock:
                if status_match[1] not in self.state.books:
                    return self.respond(404, {"error": "not_found"})
                if status not in ("unread", "in_progress", "finished"):
                    return self.respond(422, {"error": "invalid_status"})
                # Explicit status wins over progress and keeps the saved place.
                self.state.statuses[status_match[1]] = status
                self.state.touch(status_match[1])
                return self.respond(200, self.state.publication(self.base, status_match[1]))
        match = re.fullmatch(PREFIX + r"/library/([^/]+)/progress", self.route())
        if not match or not self.authorized():
            return None if match else self.respond(404, {"error": "not_found"})
        update = self.body()
        try:
            observed = parse_observed_at(update.get("observed_at"))
        except ValueError as error:
            return self.respond(422, {"error": "invalid_progress", "message": str(error)})
        resolve = update.get("resolve_conflict")
        if resolve is not None and type(resolve) is not bool:
            return self.respond(422, {"error": "invalid_progress", "message": "resolve_conflict must be true or false"})
        place = {"asset_id": update.get("asset_id"), "locator": update.get("locator"),
                 "position_seconds": update.get("position_seconds"), "observed_at": format_time(observed)}
        with self.state.lock:
            current = self.state.progress.get(match[1])
            version = current["version"] if current else 0
            if current and current["client_mutation_id"] == update.get("client_mutation_id"):
                same = all(current[key] == value for key, value in place.items())
                return self.respond(200 if same else 409, {"progress": current} if same else {"error": "progress_conflict", "progress": current})
            self.state.writes += 1
            if self.state.conflict_after and self.state.writes == self.state.conflict_after:
                # Simulate another device. Its activity time is unknown unless
                # --conflict-observed asks for one older or newer than this write.
                version += 1
                current = dict(current or update, version=version, client_mutation_id=str(uuid.uuid4()))
                current.pop("expected_version", None)
                current.pop("resolve_conflict", None)
                shift = {"older": -60, "newer": 60}.get(self.state.conflict_observed)
                current["observed_at"] = format_time(observed + shift) if shift and observed is not None else None
                current["updated_at"] = format_time(time.time())
                self.state.progress[match[1]] = current
            if update.get("expected_version") != version:
                return self.respond(409, {"error": "progress_conflict", "progress": current})
            if current and not resolve and not chronological(current, place, observed):
                return self.respond(409, {"error": "progress_conflict", "progress": current})
            saved = dict(place, version=version + 1, updated_at=format_time(time.time()),
                         client_mutation_id=update["client_mutation_id"])
            self.state.progress[match[1]] = saved
            # Recent order follows the observed activity, never the upload time.
            self.state.touch(match[1], observed)
            self.respond(200, {"progress": saved})

    def approve(self):
        code = parse_qs(urlparse(self.path).query).get("user_code", [""])[0]
        with self.state.lock:
            for device in self.state.devices.values():
                if device["user_code"] == code:
                    device["approved"] = True
        data = f"<h1>Device {code} approved</h1>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def serve(self, item):
        _, media_type, _, data = item
        etag = '"' + hashlib.sha256(data).hexdigest()[:16] + '"'
        if self.headers.get("If-None-Match") == etag:
            self.send_response(304)
            self.send_header("ETag", etag)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        start, end, status = 0, len(data) - 1, 200
        requested = re.fullmatch(r"bytes=(\d+)-(\d*)", self.headers.get("Range", ""))
        if_range = self.headers.get("If-Range")
        if requested and (if_range is None or if_range == etag):
            start = int(requested[1])
            end = min(int(requested[2]) if requested[2] else end, end)
            status = 206
        self.send_response(status)
        self.send_header("Content-Type", media_type)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", etag)
        self.send_header("Content-Length", str(end - start + 1))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data[start:end + 1])


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8099)
    parser.add_argument("--base", default="", help="Serve under this subpath, e.g. /shelfarr")
    parser.add_argument("--auto-approve", action="store_true")
    parser.add_argument("--slow-down", action="store_true", help="Answer the first poll with slow_down")
    parser.add_argument("--conflict-after", type=int, default=0, metavar="N")
    parser.add_argument("--conflict-observed", choices=("unknown", "older", "newer"), default="unknown",
                        help="Activity time of the simulated other device's place, relative to the conflicting write")
    parser.add_argument("--extra-books", type=int, default=0, metavar="N", help="Add N more mock books to exercise paging")
    parser.add_argument("--grant-requesting", action="store_true", help="Give every new token the requesting scopes")
    parser.add_argument("--old-server", action="store_true", help="Behave like a server without requesting")
    parser.add_argument("--request-outcome", choices=("available", "not_found", "failed"), default="available",
                        help="Where new requests end after searching")
    args = parser.parse_args()

    Handler.state = State(args.auto_approve, args.conflict_after, args.slow_down, args.extra_books, args.conflict_observed,
                          args.grant_requesting, args.old_server, args.request_outcome)
    Handler.base = args.base.rstrip("/")
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"Mock Shelfarr consumer API on http://{args.host}:{args.port}{Handler.base}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
