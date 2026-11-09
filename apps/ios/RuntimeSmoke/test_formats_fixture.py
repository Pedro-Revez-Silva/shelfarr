#!/usr/bin/env python3
"""Checks the reader-format additions to apps/scripts/mock_consumer_server.py over real
HTTP: what old and new clients are served, the generated PDF and CBZ, reading orders,
page-place validation, Continue, cursors and keep-alive.

    python3 -B apps/ios/RuntimeSmoke/test_formats_fixture.py
"""

import http.client
import io
import json
import os
import re
import struct
import sys
import threading
import unittest
import uuid
import zipfile
import zlib

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scripts"))
import mock_consumer_server as mock  # noqa: E402

PREFIX = mock.PREFIX
HEADER = "X-Shelfarr-Reader-Formats"


class FixtureServer:
    def __init__(self, old_server=False):
        mock.Handler.state = mock.State(True, 0, False, 3, old_server=old_server)
        mock.Handler.base = ""
        self.server = mock.ThreadingHTTPServer(("127.0.0.1", 0), mock.Handler)
        self.server.daemon_threads = True
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        grant = self.call("POST", "/auth/device", {"client_name": "fixture test"})[1]
        self.token = self.call("POST", "/auth/token", {"device_code": grant["device_code"]})[1]["access_token"]

    def close(self):
        self.server.shutdown()
        self.server.server_close()

    def call(self, method, path, body=None, headers=None, raw=False, connection=None):
        own = connection is None
        connection = connection or http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        payload = json.dumps(body).encode() if body is not None else None
        sent = dict(headers or {})
        if getattr(self, "token", None):
            sent.setdefault("Authorization", f"Bearer {self.token}")
        if payload is not None:
            sent["Content-Type"] = "application/json"
        connection.request(method, PREFIX + path, body=payload, headers=sent)
        response = connection.getresponse()
        data = response.read()
        if own:
            connection.close()
        if raw:
            return response, data
        return response.status, (json.loads(data) if data else None), response


class OldAndNewClients(unittest.TestCase):
    def setUp(self):
        self.fixture = FixtureServer()

    def tearDown(self):
        self.fixture.close()

    def listing(self, formats=None, query=""):
        headers = {HEADER: formats} if formats is not None else {}
        status, body, response = self.fixture.call("GET", "/library?limit=100" + query, headers=headers)
        self.assertEqual(status, 200)
        return body, response

    def test_an_old_client_sees_exactly_the_epub_and_audio_library(self):
        body, _ = self.listing()
        ids = {item["id"] for item in body["items"]}
        self.assertEqual(ids, {"book-1", "audio-1", "book-x1", "book-x2", "book-x3"})
        for item in body["items"]:
            self.assertNotIn("content_kind", item)
            self.assertTrue(all(asset["format"] in ("epub", "wav") for asset in item["assets"]))
        self.assertEqual(self.listing("epub")[0], body, "declaring only epub is the default")
        status, _, _ = self.fixture.call("GET", "/library/comic-1")
        self.assertEqual(status, 404, "an old client can't open a comic record")

    def test_a_capable_client_gets_the_format_books(self):
        body, response = self.listing("epub,pdf,cbz")
        self.assertEqual(response.getheader("Vary"), HEADER)
        items = {item["id"]: item for item in body["items"]}
        self.assertTrue({"pdf-1", "comic-1", "multi-1"} <= set(items))
        comic = items["comic-1"]
        self.assertEqual(comic["book_type"], "ebook", "no new book_type")
        self.assertEqual(comic["content_kind"], "graphic")
        self.assertEqual(items["book-1"]["content_kind"], "book")
        cbz = comic["assets"][0]
        self.assertEqual(cbz["format"], "cbz")
        self.assertEqual(cbz["page_count"], 10)
        self.assertEqual(cbz["reading_order_url"], f"{PREFIX}/library/comic-1/assets/cbz-1/reading_order")
        self.assertEqual([a["format"] for a in items["multi-1"]["assets"]], ["epub", "pdf"])
        only_pdf = {item["id"]: item for item in self.listing("pdf,epub,pdf")[0]["items"]}
        self.assertEqual(only_pdf["comic-1"]["assets"], [], "undeclared formats are never serialized")
        ebooks = {item["id"] for item in self.listing("epub,pdf,cbz", "&type=ebook")[0]["items"]}
        self.assertIn("comic-1", ebooks, "type=ebook includes comics for capable clients")

    def test_invalid_declarations_are_refused(self):
        for value in ["", "EPUB", "epub,mobi", "epub,,pdf", "x" * 65]:
            status, body, _ = self.fixture.call("GET", "/library", headers={HEADER: value})
            self.assertEqual(status, 400, value)
            self.assertEqual(body["error"], "invalid_request")
        self.assertEqual(self.fixture.call("GET", "/library", headers={HEADER: " epub , pdf "})[0], 200)

    def test_cursors_are_bound_to_the_declared_formats(self):
        status, page, _ = self.fixture.call("GET", "/library?limit=2", headers={HEADER: "epub,pdf,cbz"})
        self.assertEqual(status, 200)
        cursor = page["next_cursor"]
        status, _, _ = self.fixture.call("GET", f"/library?limit=2&cursor={cursor}")
        self.assertEqual(status, 400, "a capable listing's cursor is refused without the header")
        self.assertEqual(self.fixture.call("GET", f"/library?limit=2&cursor={cursor}", headers={HEADER: "cbz,pdf,epub"})[0], 200)
        legacy = self.fixture.call("GET", "/library?limit=2")[1]["next_cursor"]
        self.assertEqual(self.fixture.call("GET", f"/library?limit=2&cursor={legacy}", headers={HEADER: "epub"})[0], 200,
                         "explicit epub shares the default cursor")

    def test_server_facts_and_an_old_server(self):
        status, facts, _ = self.fixture.call("GET", "/server.json")
        self.assertEqual(facts["reader_formats"], ["cbz", "epub", "pdf"])
        self.fixture.close()
        self.fixture = FixtureServer(old_server=True)
        status, facts, _ = self.fixture.call("GET", "/server.json")
        self.assertNotIn("reader_formats", facts)
        body, _ = self.listing("epub,pdf,cbz")
        self.assertNotIn("comic-1", {item["id"] for item in body["items"]}, "an old server ignores the header")


class GeneratedFiles(unittest.TestCase):
    def setUp(self):
        self.fixture = FixtureServer()

    def tearDown(self):
        self.fixture.close()

    def content(self, asset):
        response, data = self.fixture.call("GET", f"/assets/{asset}/content", raw=True)
        self.assertEqual(response.status, 200)
        return response, data

    def test_the_pdf_is_well_formed(self):
        response, pdf = self.content("pdf-1")
        self.assertEqual(response.getheader("Content-Disposition"), "attachment")
        self.assertEqual(response.getheader("X-Content-Type-Options"), "nosniff")
        self.assertTrue(pdf.startswith(b"%PDF-1.4"))
        self.assertTrue(pdf.rstrip().endswith(b"%%EOF"))
        start = int(re.search(rb"startxref\n(\d+)", pdf)[1])
        self.assertTrue(pdf[start:].startswith(b"xref"))
        entries = re.findall(rb"(\d{10}) 00000 n ", pdf[start:])
        for number, offset in enumerate(entries, start=1):
            self.assertTrue(pdf[int(offset):].startswith(b"%d 0 obj" % number), number)
        self.assertIn(b"/Count 6", pdf)
        self.assertIn(b"/URI (https://example.invalid/never-opened)", pdf, "the link a reader must not follow")

    def test_the_comic_and_its_reading_order(self):
        _, cbz = self.content("cbz-1")
        status, order, _ = self.fixture.call("GET", "/library/comic-1/assets/cbz-1/reading_order")
        self.assertEqual(status, 200)
        self.assertEqual(order["asset_id"], "cbz-1")
        self.assertEqual(order["format"], "cbz")
        items = order["items"]
        self.assertEqual([i["position"] for i in items], list(range(1, 11)))
        self.assertEqual([i["href"] for i in items], [f"Issue%201/p{n}.png" for n in range(1, 11)], "natural order: p2 before p10")
        self.assertEqual({i["compression_method"] for i in items}, {0, 8}, "stored and deflated pages")
        with zipfile.ZipFile(io.BytesIO(cbz)) as archive:
            self.assertIsNone(archive.testzip())
            for item in items:
                info = archive.getinfo(item["href"].replace("%20", " "))
                self.assertEqual(info.header_offset, item["local_header_offset"])
                self.assertEqual(f"{info.CRC:08x}", item["crc32"])
                page = archive.read(info)
                self.assertEqual(len(page), item["size_bytes"])
                self.assertTrue(page.startswith(b"\x89PNG\r\n\x1a\n"))
                width, height = struct.unpack(">II", page[16:24])
                self.assertEqual((width, height), (600, 900))
                idat = page.index(b"IDAT")
                length = struct.unpack(">I", page[idat - 4:idat])[0]
                zlib.decompress(page[idat + 4:idat + 4 + length])
        for path in ["/library/pdf-1/assets/pdf-1/reading_order", "/library/book-1/assets/cbz-1/reading_order",
                     "/library/comic-1/assets/missing/reading_order"]:
            status, body, _ = self.fixture.call("GET", path)
            self.assertEqual((status, body), (410, {"error": "asset_unavailable"}), path)


class PagePlaces(unittest.TestCase):
    def setUp(self):
        self.fixture = FixtureServer()
        self.versions = {}
        # Each write is observed a second after the last, as reading would be.
        self.clock = mock.time.time() - 120

    def tearDown(self):
        self.fixture.close()

    def put(self, publication, asset, locator):
        self.clock += 1
        body = {"asset_id": asset, "locator": locator, "expected_version": self.versions.get(publication, 0),
                "client_mutation_id": str(uuid.uuid4()), "observed_at": mock.format_time(self.clock)}
        status, answer, _ = self.fixture.call("PUT", f"/library/{publication}/progress", body)
        if status == 200:
            self.versions[publication] = answer["progress"]["version"]
        return status, answer

    def pdf(self, page, **extra):
        locations = {"position": page, "totalProgression": min(1, (page - 1) / 6), "fragments": [f"page={page}"]}
        locations.update(extra)
        return {"href": "document.pdf", "type": "application/pdf", "locations": locations}

    def test_pdf_places_follow_the_contract(self):
        self.assertEqual(self.put("pdf-1", "pdf-1", self.pdf(3))[0], 200)
        self.assertEqual(self.put("pdf-1", "pdf-1", self.pdf(40))[0], 200, "only the 100,000 bound is checked")
        refused = [
            self.pdf(2.0), self.pdf(0), self.pdf(100_001), self.pdf(3, cfi="/4/2"), self.pdf(3, fragments=["page=4"]),
            self.pdf(3, totalProgression=1.5), dict(self.pdf(3), href="OEBPS/c1.xhtml"), dict(self.pdf(3), type="image/png"),
            dict(self.pdf(3), otherLocations={}), dict(self.pdf(3), title="x" * 1025), {"href": "document.pdf"},
        ]
        for locator in refused:
            status, answer = self.put("pdf-1", "pdf-1", locator)
            self.assertEqual(status, 422, locator)
            self.assertEqual(answer["error"], "invalid_progress")
        self.assertEqual(self.put("pdf-1", "epub-1", self.pdf(3))[0], 200, "EPUB places are not page places")

    def test_comic_places_name_item_n_of_the_order(self):
        def page(n, href=None, kind="image/png", **extra):
            locations = {"position": n, "totalProgression": (n - 1) / 10}
            locations.update(extra)
            return {"href": href or f"Issue%201/p{n}.png", "type": kind, "locations": locations}
        self.assertEqual(self.put("comic-1", "cbz-1", page(10))[0], 200)
        for locator in [page(3, href="Issue%201/p4.png"), page(3, kind="image/jpeg"), page(11, href="Issue%201/p10.png"),
                        page(3, fragments=["page=3"]), page(3, href="Issue 1/p3.png")]:
            self.assertEqual(self.put("comic-1", "cbz-1", locator)[0], 422, locator)
        self.assertEqual(self.put("comic-1", "pdf-1", self.pdf(1))[0], 422, "a file of another publication")

    def test_the_smoke_servers_other_device_places(self):
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import smoke_server  # noqa: E402  (shares this fixture's mock state)
        order = self.fixture.call("GET", "/library/comic-1/assets/cbz-1/reading_order")[1]["items"]
        for page, href in [(5, order[4]["href"]), (40, "replaced/p40.png")]:
            smoke_server.save_place({"publication": "comic-1", "asset": "cbz-1", "page": page})
            status, body, _ = self.fixture.call("GET", "/library/comic-1/progress")
            self.assertEqual(status, 200)
            locator = body["progress"]["locator"]
            self.assertEqual((locator["href"], locator["locations"]["position"]), (href, page))
            self.assertTrue(body["progress"]["observed_at"], "another device's time")
        self.assertNotIn("replaced/p40.png", [item["href"] for item in order], "a page this archive doesn't have")

    def test_continue_offers_only_places_the_client_can_open(self):
        self.assertEqual(self.put("multi-1", "pdf-m", self.pdf(2))[0], 200)
        everything = self.fixture.call("GET", "/continue", headers={HEADER: "epub,pdf,cbz"})[1]["items"]
        self.assertIn("multi-1", [i["id"] for i in everything])
        without_pdf = self.fixture.call("GET", "/continue", headers={HEADER: "epub,cbz"})[1]["items"]
        self.assertNotIn("multi-1", [i["id"] for i in without_pdf])
        legacy = self.fixture.call("GET", "/continue")[1]["items"]
        self.assertNotIn("multi-1", [i["id"] for i in legacy])
        status, publication, _ = self.fixture.call("PUT", "/library/multi-1/reading_status", {"status": "finished"},
                                                   headers={HEADER: "epub,pdf,cbz"})
        self.assertEqual(status, 200)
        self.assertEqual(publication["content_kind"], "book")
        self.assertEqual(publication["progress"]["asset_id"], "pdf-m", "a status change keeps the place")

    def test_keep_alive_survives_refusals(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.fixture.port, timeout=10)
        status, _, _ = self.fixture.call("GET", "/library", headers={HEADER: "nope"}, connection=connection)
        self.assertEqual(status, 400)
        locator = self.pdf(2.5)
        body = {"asset_id": "pdf-1", "locator": locator, "expected_version": 0, "client_mutation_id": str(uuid.uuid4())}
        status, _, _ = self.fixture.call("PUT", "/library/pdf-1/progress", body, connection=connection)
        self.assertEqual(status, 422)
        status, page, _ = self.fixture.call("GET", "/library/pdf-1", headers={HEADER: "pdf"}, connection=connection)
        self.assertEqual(status, 200, "the same connection still parses the next request")
        self.assertEqual(page["assets"][0]["format"], "pdf")
        connection.close()


if __name__ == "__main__":
    unittest.main()
