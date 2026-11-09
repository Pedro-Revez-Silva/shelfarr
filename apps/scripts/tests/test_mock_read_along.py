"""The development mock's read-along fixtures follow docs/read-along.md and stay opt-in."""

import hashlib
import http.client
import io
import json
import re
import threading
import time
import unittest
import xml.etree.ElementTree as ElementTree
import zipfile
from http.server import ThreadingHTTPServer

from support import SCRIPTS, load

SMIL = "{http://www.w3.org/ns/SMIL}"


def clock_ms(value):
    """The SMIL full clock values the fixture writes (0:00:02.000)."""
    hours, minutes, seconds = value.split(":")
    return round((int(hours) * 3600 + int(minutes) * 60 + float(seconds)) * 1000)


class MockServer:
    def __init__(self, **options):
        self.module = load(SCRIPTS / "mock_consumer_server.py", "mock_consumer_server_under_test")
        handler = type("Handler", (self.module.Handler,), {})
        handler.state = self.module.State(True, 0, False, **options)
        handler.base = ""
        self.state = handler.state
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.token = self.call("POST", "/api/consumer/v1/auth/token",
                               {"device_code": self.call("POST", "/api/consumer/v1/auth/device", {"client_name": "t"})[2]["device_code"]})[2]["access_token"]

    def close(self):
        self.server.shutdown()
        self.server.server_close()

    def raw(self, method, path, body=None, headers=None, connection=None):
        own = connection is None
        connection = connection or http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=10)
        payload = json.dumps(body).encode() if body is not None else None
        sent = {"Authorization": f"Bearer {self.token}"} if hasattr(self, "token") else {}
        sent.update(headers or {})
        if payload is not None:
            sent["Content-Type"] = "application/json"
        connection.request(method, path, body=payload, headers=sent)
        response = connection.getresponse()
        data = response.read()
        if own:
            connection.close()
        return response.status, response.headers, data

    def call(self, method, path, body=None, headers=None):
        status, headers, data = self.raw(method, path, body, headers)
        return status, headers, json.loads(data) if data else None


class DefaultMockTest(unittest.TestCase):
    def setUp(self):
        self.mock = MockServer()
        self.addCleanup(self.mock.close)

    def test_without_the_flag_the_feature_header_changes_nothing(self):
        plain = self.mock.raw("GET", "/api/consumer/v1/library/book-1")
        declared = self.mock.raw("GET", "/api/consumer/v1/library/book-1", headers={"X-Shelfarr-Reader-Features": "read-along"})
        self.assertEqual(plain[2], declared[2])
        self.assertEqual(plain[1]["Vary"], declared[1]["Vary"])
        facts = self.mock.call("GET", "/api/consumer/v1/server.json")[2]
        self.assertNotIn("reader_features", facts)
        listing = self.mock.call("GET", "/api/consumer/v1/library")[2]
        self.assertFalse(any(item["id"].startswith(("garden", "lighthouse")) for item in listing["items"]))
        self.assertEqual(404, self.mock.raw("GET", "/api/consumer/v1/library/book-1/assets/epub-1/read_along")[0])


class ReadAlongMockTest(unittest.TestCase):
    def setUp(self):
        self.mock = MockServer(read_along=True)
        self.addCleanup(self.mock.close)

    def detail(self, publication, declared=True):
        headers = {"X-Shelfarr-Reader-Features": "read-along"} if declared else {}
        return self.mock.call("GET", f"/api/consumer/v1/library/{publication}", headers=headers)

    def test_server_facts_name_the_feature(self):
        facts = self.mock.call("GET", "/api/consumer/v1/server.json")[2]
        self.assertEqual(["read-along"], facts["reader_features"])
        self.assertEqual([1], facts["read_along_manifest_versions"])

    def test_summaries_only_on_declared_details(self):
        status, headers, plain = self.detail("garden-1", declared=False)
        self.assertEqual(200, status)
        self.assertNotIn("read_along", plain["assets"][0])
        self.assertIn("X-Shelfarr-Reader-Features", headers["Vary"])
        summary = self.detail("garden-1")[2]["assets"][0]["read_along"]
        self.assertEqual("available", summary["status"])
        self.assertEqual("media_overlay", summary["source"])
        self.assertRegex(summary["generation"], r"^[0-9a-f]{64}$")
        self.assertEqual(8, summary["coverage"]["cues"])
        # A plain EPUB says it is unaligned; listings never carry summaries.
        self.assertEqual({"status": "unaligned"}, self.detail("book-1")[2]["assets"][0]["read_along"])
        listing = self.mock.call("GET", "/api/consumer/v1/library", headers={"X-Shelfarr-Reader-Features": "read-along"})[2]
        self.assertFalse(any("read_along" in asset for item in listing["items"] for asset in item["assets"]))

    def test_malformed_feature_declarations_are_refused(self):
        for value in ("Read-Along", "read along", "", "x" * 129):
            status, _, body = self.mock.call("GET", "/api/consumer/v1/library/garden-1", headers={"X-Shelfarr-Reader-Features": value})
            self.assertEqual(400, status, value)
            self.assertEqual("invalid_request", body["error"])
        # Unknown names are ignored, as on the server.
        self.assertNotIn("read_along", self.detail_with("future-thing")["assets"][0])

    def detail_with(self, features):
        return self.mock.call("GET", "/api/consumer/v1/library/garden-1", headers={"X-Shelfarr-Reader-Features": features})[2]

    def test_the_media_overlay_manifest_is_what_the_book_s_own_smil_says(self):
        summary = self.detail("garden-1")[2]["assets"][0]["read_along"]
        status, _, manifest = self.mock.call("GET", summary["manifest_url"])
        self.assertEqual(200, status)
        self.assertEqual(summary["generation"], manifest["generation"])
        self.assertEqual(["text", "fragment", "audio", "begin_ms", "end_ms"], manifest["cue_fields"])
        epub = zipfile.ZipFile(io.BytesIO(self.mock.state.files["epub-garden"][3]))
        cues = []
        for text_index, doc in enumerate(["chapter1", "chapter2"]):
            smil = ElementTree.fromstring(epub.read(f"OEBPS/{doc}.smil"))
            html = epub.read(f"OEBPS/{doc}.xhtml").decode()
            for par in smil.iter(f"{SMIL}par"):
                text = par.find(f"{SMIL}text").get("src")
                audio = par.find(f"{SMIL}audio")
                fragment = text.split("#", 1)[1]
                self.assertIn(f'id="{fragment}"', html)
                self.assertEqual("audio/narration.wav", audio.get("src"))
                cues.append([text_index, fragment, 0, clock_ms(audio.get("clipBegin")), clock_ms(audio.get("clipEnd"))])
        self.assertEqual(cues, manifest["cues"])
        audio = manifest["audio"][0]
        entry = epub.getinfo("OEBPS/audio/narration.wav")
        self.assertEqual(("epub_resource", "OEBPS/audio/narration.wav", entry.file_size), (audio["kind"], audio["href"], audio["size_bytes"]))
        self.assertEqual(zipfile.ZIP_STORED, entry.compress_type)
        # Audio, SMIL and video never appear among the text resources.
        self.assertFalse(any(r["href"].endswith((".smil", ".wav")) for r in manifest["resources"]))

    def test_resources_are_served_only_when_listed_with_ranges(self):
        manifest = self.mock.call("GET", self.detail("garden-1")[2]["assets"][0]["read_along"]["manifest_url"])[2]
        audio_url = manifest["audio"][0]["url"]
        status, headers, body = self.mock.raw("GET", audio_url, headers={"Range": "bytes=0-43"})
        self.assertEqual(206, status)
        self.assertEqual(b"RIFF", body[:4])
        self.assertEqual("attachment", headers["Content-Disposition"])
        self.assertEqual(manifest["generation"], headers["X-Shelfarr-Read-Along"])
        unlisted = manifest["resources_url"] + "OEBPS/chapter1.smil"
        self.assertEqual(404, self.mock.raw("GET", unlisted)[0])
        chapter = next(r for r in manifest["resources"] if r["href"] == "OEBPS/chapter1.xhtml")
        self.assertIn(b'id="c0"', self.mock.raw("GET", chapter["url"])[2])

    def test_the_imported_alignment_names_the_separate_audiobook(self):
        summary = self.detail("lighthouse-1")[2]["assets"][0]["read_along"]
        self.assertEqual(("available", "imported"), (summary["status"], summary["source"]))
        self.assertEqual({"id": "lighthouse-audio-1", "title": "The Paired Lighthouse"}, summary["audiobook"])
        manifest = self.mock.call("GET", summary["manifest_url"])[2]
        audiobook = self.detail("lighthouse-audio-1")[2]
        self.assertEqual([a["id"] for a in audiobook["assets"]], [t["asset_id"] for t in manifest["audio"]])
        for track, asset in zip(manifest["audio"], audiobook["assets"]):
            self.assertEqual(("publication_asset", "lighthouse-audio-1", asset["content_url"], asset["size_bytes"]),
                             (track["kind"], track["publication_id"], track["content_url"], track["size_bytes"]))
            served = self.mock.raw("GET", track["url"])[2]
            self.assertEqual(hashlib.sha256(served).hexdigest(), hashlib.sha256(self.mock.state.files[asset["id"]][3]).hexdigest())
        # Cues are in reading order and each file's cues follow its own clock.
        self.assertEqual([c[1] for c in manifest["cues"]], [f"c{n}" for n in range(8)])
        self.assertEqual([[0, 0], [0, 2000], [0, 4000], [0, 6000], [1, 0], [1, 2000], [1, 4000], [1, 6000]],
                         [[c[2], c[3]] for c in manifest["cues"]])

    def test_statuses_follow_the_contract(self):
        status, _, body = self.mock.call("GET", "/api/consumer/v1/library/book-1/assets/epub-1/read_along")
        self.assertEqual((404, "read_along_unaligned"), (status, body["error"]))
        self.assertEqual(410, self.mock.raw("GET", "/api/consumer/v1/library/book-1/assets/epub-garden/read_along")[0])
        stale = MockServer(read_along=True, read_along_stale=True)
        self.addCleanup(stale.close)
        status, _, body = stale.call("GET", "/api/consumer/v1/library/lighthouse-1/assets/epub-lighthouse/read_along")
        self.assertEqual((409, "read_along_stale"), (status, body["error"]))
        self.assertEqual("stale", stale.call("GET", "/api/consumer/v1/library/lighthouse-1",
                                             headers={"X-Shelfarr-Reader-Features": "read-along"})[2]["assets"][0]["read_along"]["status"])

    def test_read_along_places_are_checked_like_the_server(self):
        generation = self.detail("garden-1")[2]["assets"][0]["read_along"]["generation"]
        locator = {"href": "OEBPS/chapter1.xhtml", "type": "application/xhtml+xml",
                   "locations": {"fragments": ["c1"], "readAlong": {"generation": generation, "audio": 0, "offset_ms": 2100}}}
        update = {"asset_id": "epub-garden", "locator": locator, "expected_version": 0, "client_mutation_id": "m1",
                  "observed_at": self.mock.module.format_time(time.time() - 60)}
        self.assertEqual(200, self.mock.call("PUT", "/api/consumer/v1/library/garden-1/progress", update)[0])
        for bad in ({"generation": generation, "audio": 0}, {"generation": "x", "audio": 0, "offset_ms": 1},
                    {"generation": generation, "audio": 2000, "offset_ms": 1}, {"generation": generation, "audio": 0, "offset_ms": 1.5}):
            body = dict(update, client_mutation_id="m2", expected_version=1,
                        locator=dict(locator, locations=dict(locator["locations"], readAlong=bad)))
            self.assertEqual(422, self.mock.call("PUT", "/api/consumer/v1/library/garden-1/progress", body)[0], bad)

    def test_keep_alive_survives_an_unread_body_and_a_refusal(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.mock.server.server_address[1], timeout=10)
        self.addCleanup(connection.close)
        refused = self.mock.raw("GET", "/api/consumer/v1/library/garden-1", headers={"X-Shelfarr-Reader-Features": "Bad"}, connection=connection)
        self.assertEqual(400, refused[0])
        posted = self.mock.raw("POST", "/api/consumer/v1/auth/revoke-nothing", body={"x": 1}, connection=connection)
        self.assertEqual(404, posted[0])
        again = self.mock.raw("GET", "/api/consumer/v1/library/garden-1", connection=connection)
        self.assertEqual(200, again[0])
        self.assertTrue(re.search(rb'"id": "garden-1"', again[2]))


if __name__ == "__main__":
    unittest.main()
