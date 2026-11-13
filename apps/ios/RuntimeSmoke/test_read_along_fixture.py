#!/usr/bin/env python3
"""Checks the read-along fixture (read_along_fixture.py, served by smoke_server.py) over
real HTTP before the simulator smoke relies on it: older clients see unchanged details,
the Media Overlay book's SMIL and generated narration match its manifest exactly (a tone
inside every cue, silence in every gap), resources and paired audio are served only as
listed, stale alignments and malformed declarations are refused, and progress writes get
the server's `locations.readAlong` check. Also the control port's `POST /reset`, which
gives every UI test case the fixture as the server started.

    python3 -B apps/ios/RuntimeSmoke/test_read_along_fixture.py
"""

import http.client
import io
import json
import os
import re
import socket
import struct
import sys
import threading
import unittest
import uuid
import wave
import xml.etree.ElementTree as ET
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "scripts"))
import mock_consumer_server as mock  # noqa: E402
import read_along_fixture as reading  # noqa: E402
import smoke_server  # noqa: E402

PREFIX = mock.PREFIX
FEATURES = {"X-Shelfarr-Reader-Features": "read-along"}
FORMATS = {"X-Shelfarr-Reader-Formats": "epub,pdf,cbz"}
SMIL = "{http://www.w3.org/ns/SMIL}"


class Fixture:
    def __init__(self):
        mock.Handler.state = mock.State(True, 0, False, 3)
        mock.Handler.base = ""
        smoke_server.READING = reading.ReadAlong(mock.Handler.state)
        smoke_server.SWITCH = smoke_server.Switch("127.0.0.1", 0)
        smoke_server.SWITCH.up()
        self.port = smoke_server.SWITCH.server.server_address[1]
        self.token = None
        grant = self.call("POST", "/auth/device", {"client_name": "read-along fixture test"})[1]
        self.token = self.call("POST", "/auth/token", {"device_code": grant["device_code"]})[1]["access_token"]

    def close(self):
        smoke_server.SWITCH.down()

    def call(self, method, path, body=None, headers=None, raw=False):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        payload = json.dumps(body).encode() if body is not None else None
        sent = dict(headers or {})
        if self.token:
            sent.setdefault("Authorization", f"Bearer {self.token}")
        if payload is not None:
            sent["Content-Type"] = "application/json"
        connection.request(method, path if path.startswith(PREFIX) else PREFIX + path, body=payload, headers=sent)
        response = connection.getresponse()
        data = response.read()
        connection.close()
        if raw:
            return response, data
        return response.status, (json.loads(data) if data else None)


class ReadAlongFixtureTests(unittest.TestCase):
    def setUp(self):
        self.fixture = Fixture()

    def tearDown(self):
        self.fixture.close()

    def details(self, publication, headers=None):
        status, body = self.fixture.call("GET", f"/library/{publication}", headers=dict(FORMATS, **(headers or {})))
        self.assertEqual(status, 200)
        return body

    def manifest(self, publication):
        summary = self.details(publication, FEATURES)["assets"][0]["read_along"]
        status, body = self.fixture.call("GET", summary["manifest_url"])
        return summary, status, body

    def test_clients_that_dont_declare_read_along_see_unchanged_details(self):
        for publication in ("narrated-1", "paired-1", "book-1"):
            plain = self.details(publication)
            self.assertTrue(all("read_along" not in asset for asset in plain["assets"]))
            declared = self.details(publication, FEATURES)
            for asset in declared["assets"]:
                asset.pop("read_along", None)
            self.assertEqual(declared, plain, "the feature only adds summaries")
        status, listing = self.fixture.call("GET", "/library?limit=100", headers=dict(FORMATS, **FEATURES))
        self.assertEqual(status, 200)
        self.assertTrue(all("read_along" not in a for item in listing["items"] for a in item["assets"]), "listings never carry it")
        titles = [item["title"] for item in listing["items"]]
        self.assertGreater(titles.index("Narrated Fixture"), titles.index("Mock Book 003"), "fixture books sort after the mock's")

    def test_malformed_declarations_are_refused(self):
        for value in ("Read-Along", "read along", "x" * 129, ""):
            status, body = self.fixture.call("GET", "/library/narrated-1", headers=dict(FORMATS, **{"X-Shelfarr-Reader-Features": value}))
            self.assertEqual(status, 400, value)
            self.assertEqual(body["error"], "invalid_request")
        self.assertNotIn("read_along", self.details("narrated-1", {"X-Shelfarr-Reader-Features": "future-thing"})["assets"][0])

    def test_the_media_overlay_manifest_is_exactly_the_books_smil_and_narration(self):
        summary, status, manifest = self.manifest("narrated-1")
        self.assertEqual(status, 200)
        self.assertEqual(summary["status"], "available")
        self.assertEqual(summary["generation"], manifest["generation"])
        self.assertRegex(manifest["generation"], r"\A[0-9a-f]{64}\Z")
        self.assertEqual(manifest["cue_fields"], ["text", "fragment", "audio", "begin_ms", "end_ms"])
        epub = zipfile.ZipFile(io.BytesIO(mock.Handler.state.files["epub-n"][3]))
        self.assertEqual(epub.namelist()[0], "mimetype")
        # The cues are what the SMIL says, in reading order.
        from_smil = []
        for text_index, text in enumerate(manifest["text"]):
            smil = text["href"].replace(".xhtml", ".smil")
            for par in ET.fromstring(epub.read(smil)).iter(f"{SMIL}par"):
                target = par.find(f"{SMIL}text").get("src").split("#")[1]
                audio = par.find(f"{SMIL}audio")
                ms = lambda value: int(round(float(value.rstrip("s")) * 1000))  # noqa: E731
                from_smil.append([text_index, target, text_index, ms(audio.get("clipBegin")), ms(audio.get("clipEnd"))])
        self.assertEqual(manifest["cues"], from_smil)
        texts = [cue[0] for cue in manifest["cues"]]
        self.assertEqual(texts, sorted(texts), "cues are in reading order")
        # Every cue element exists in its document.
        for cue in manifest["cues"]:
            document = epub.read(manifest["text"][cue[0]]["href"]).decode()
            self.assertIn(f'id="{cue[1]}"', document)
        # The narration is a tone inside every cue and silence between them.
        for index, track in enumerate(manifest["audio"]):
            self.assertEqual(track["kind"], "epub_resource")
            data = epub.read(track["href"])
            self.assertEqual(track["size_bytes"], len(data))
            with wave.open(io.BytesIO(data)) as audio:
                rate = audio.getframerate()
                samples = struct.unpack(f"<{audio.getnframes()}h", audio.readframes(audio.getnframes()))
            cues = [cue for cue in manifest["cues"] if cue[2] == index]
            for _, _, _, begin, end in cues:
                inside = samples[begin * rate // 1000 + 10:end * rate // 1000 - 10]
                self.assertGreater(max(abs(v) for v in inside), 1000, "a tone is heard inside the cue")
            for (_, _, _, _, end), (_, _, _, begin, _) in zip(cues, cues[1:]):
                self.assertEqual(max(abs(v) for v in samples[end * rate // 1000:begin * rate // 1000]), 0, "silence between cues")
            self.assertLessEqual(cues[-1][4], len(samples) * 1000 // rate)
        # p4 follows a long paragraph, so it starts on a later page.
        chapter = epub.read("OEBPS/c1.xhtml").decode()
        self.assertGreater(chapter.index('id="p4"') - chapter.index('id="p3"'), 5000)

    def test_resources_and_narration_are_served_only_as_listed(self):
        _, _, manifest = self.manifest("narrated-1")
        audio = manifest["audio"][0]["url"]
        response, data = self.fixture.call("GET", audio, headers={"Range": "bytes=0-3"}, raw=True)
        self.assertEqual(response.status, 206)
        self.assertEqual(data, b"RIFF")
        for resource in manifest["resources"]:
            response, data = self.fixture.call("GET", resource["url"], raw=True)
            self.assertEqual(response.status, 200)
            self.assertEqual(len(data), resource["size_bytes"])
        root = manifest["resources_url"]
        for path in ("OEBPS/c1.smil", "OEBPS/../mimetype", "mimetype"):
            status, _ = self.fixture.call("GET", root + path)
            self.assertEqual(status, 404, path)
        response, _ = self.fixture.call("GET", audio, headers={"Authorization": "Bearer nope"}, raw=True)
        self.assertEqual(response.status, 401, "narration needs the bearer")

    def test_an_imported_alignment_names_the_paired_audiobook_and_can_go_stale(self):
        summary, status, manifest = self.manifest("paired-1")
        self.assertEqual(status, 200)
        self.assertEqual(summary["source"], "imported")
        self.assertEqual(summary["audiobook"], {"id": "paired-audio", "title": "Paired Fixture Narration"})
        self.assertEqual([a["asset_id"] for a in manifest["audio"]], ["track-p1", "track-p2"])
        for track in manifest["audio"]:
            self.assertEqual(track["kind"], "publication_asset")
            self.assertEqual(track["publication_id"], "paired-audio")
            response, data = self.fixture.call("GET", track["url"], raw=True)
            self.assertEqual(response.status, 200)
            self.assertEqual(data, mock.Handler.state.files[track["asset_id"]][3])
            self.assertTrue(track["content_url"].endswith(f"/assets/{track['asset_id']}/content"))
        before = manifest["generation"]
        smoke_server.READING.realign()
        _, _, again = self.manifest("paired-1")
        self.assertNotEqual(again["generation"], before, "importing again is a new generation")
        smoke_server.READING.mark_stale()
        stale = self.details("paired-1", FEATURES)["assets"][0]["read_along"]
        self.assertEqual(stale["status"], "stale")
        self.assertIn("reason", stale)
        status, body = self.fixture.call("GET", again["manifest_url"])
        self.assertEqual(status, 409)
        self.assertEqual(body["error"], "read_along_stale")
        status, _ = self.fixture.call("GET", again["audio"][0]["url"])
        self.assertEqual(status, 404, "a stale alignment's audio route is gone")

    def test_unaligned_books_name_their_audiobook(self):
        summary = self.details("book-1", FEATURES)["assets"][0]["read_along"]
        self.assertEqual(summary, {"status": "unaligned", "audiobook": {"id": "audio-1", "title": "A Test Audiobook"}})
        status, body = self.fixture.call("GET", "/library/book-1/assets/epub-1/read_along")
        self.assertEqual(status, 404)
        self.assertEqual(body["error"], "read_along_unaligned")

    def test_progress_writes_get_the_servers_read_along_check(self):
        generation = self.manifest("narrated-1")[2]["generation"]

        def write(read_along, version=0):
            return self.fixture.call("PUT", "/library/narrated-1/progress", {
                "asset_id": "epub-n", "expected_version": version, "client_mutation_id": str(uuid.uuid4()),
                "observed_at": mock.format_time(__import__("time").time()),
                "locator": {"href": "OEBPS/c1.xhtml", "type": "application/xhtml+xml",
                            "locations": {"fragments": ["p2"], "readAlong": read_along}}})

        for bad in ({"generation": generation, "audio": 0}, {"generation": generation, "audio": 2000, "offset_ms": 0},
                    {"generation": generation, "audio": 0, "offset_ms": 1.5}, {"generation": "XYZ", "audio": 0, "offset_ms": 0},
                    {"generation": generation, "audio": 0, "offset_ms": 0, "cue": 1}):
            status, _ = write(bad)
            self.assertEqual(status, 422, bad)
        status, body = write({"generation": generation, "audio": 0, "offset_ms": 3743})
        self.assertEqual(status, 200)
        self.assertEqual(body["progress"]["locator"]["locations"]["readAlong"]["offset_ms"], 3743)
        log = smoke_server.PROGRESS_LOG.snapshot()["narrated-1"]
        self.assertEqual(log["count"], 1, "refused writes never reach the mock, and each write is logged once")
        self.assertEqual(log["last"]["read_along"]["offset_ms"], 3743)
        self.assertEqual(log["last"]["fragments"], ["p2"])


class FreshFixtureTests(unittest.TestCase):
    """`POST /reset` on the real control port: what one UI test case leaves behind (a
    place another device saved, activity that reorders the library, progress writes, a
    request that added a book, a stale alignment, counters) is gone for the next case."""

    def setUp(self):
        smoke_server.install_fixture(3)
        self.fixture = Fixture.__new__(Fixture)
        # A fixed port, as in the smoke: going offline and back must reopen the same one.
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()
        smoke_server.SWITCH = smoke_server.Switch("127.0.0.1", port)
        smoke_server.SWITCH.up()
        self.fixture.port = port
        self.fixture.token = None
        self.control = smoke_server.QuickServer(("127.0.0.1", 0), smoke_server.ControlHandler)
        threading.Thread(target=self.control.serve_forever, daemon=True).start()
        self.sign_in()

    def tearDown(self):
        self.control.shutdown()
        self.control.server_close()
        smoke_server.SWITCH.down()

    def sign_in(self):
        self.fixture.token = None
        grant = self.fixture.call("POST", "/auth/device", {"client_name": "fresh fixture test"})[1]
        self.fixture.token = self.fixture.call("POST", "/auth/token", {"device_code": grant["device_code"]})[1]["access_token"]

    def control_call(self, method, path, body=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.control.server_address[1], timeout=10)
        payload = json.dumps(body).encode() if body is not None else None
        connection.request(method, path, body=payload, headers={"Content-Type": "application/json"} if payload else {})
        response = connection.getresponse()
        data = response.read()
        connection.close()
        return response.status, (json.loads(data) if data else None)

    def recent_ids(self):
        status, body = self.fixture.call("GET", "/library?limit=100", headers=FORMATS)
        self.assertEqual(status, 200)
        return [item["id"] for item in body["items"]]

    def progress(self, publication):
        status, body = self.fixture.call("GET", f"/library/{publication}/progress")
        self.assertEqual(status, 200)
        return body["progress"]

    def test_a_reset_leaves_nothing_from_the_previous_case(self):
        fresh_order = self.recent_ids()
        self.assertEqual(fresh_order[-1], "multi-1", "with no activity the library is by title")
        # What the format cases leave: a page place written by the app, another device's
        # place that moves a book to the top, and a request that adds a book.
        status, _ = self.fixture.call("PUT", "/library/pdf-1/progress", {
            "asset_id": "pdf-1", "expected_version": 0, "client_mutation_id": str(uuid.uuid4()),
            "observed_at": mock.format_time(__import__("time").time()),
            "locator": {"href": "document.pdf", "type": "application/pdf",
                        "locations": {"position": 5, "fragments": ["page=5"]}}}, headers=FORMATS)
        self.assertEqual(status, 200)
        self.assertEqual(self.control_call("POST", "/place", {"publication": "multi-1", "asset": "pdf-m", "page": 3})[0], 200)
        self.assertEqual(self.recent_ids()[:2], ["pdf-1", "multi-1"], "activity puts both before every untouched book")
        books = len(mock.Handler.state.books)
        mock.Handler.state.books["requested-1"] = ("A Request", "Someone", "ebook", ["epub-1"])
        # What the read-along cases leave: a stale alignment, and the counters.
        self.assertEqual(self.control_call("POST", "/read-along/stale")[0], 200)
        stale = self.fixture.call("GET", "/library/paired-1", headers=dict(FORMATS, **FEATURES))[1]
        self.assertEqual(stale["assets"][0]["read_along"]["status"], "stale")
        smoke_server.STATS.bump("grant_requests")
        self.assertEqual(smoke_server.PROGRESS_LOG.snapshot()["pdf-1"]["count"], 1)
        self.assertEqual(self.progress("pdf-1")["locator"]["locations"]["position"], 5)

        status, body = self.control_call("POST", "/reset")
        self.assertEqual((status, body), (200, {"reset": True}))

        # Tokens belong to the old fixture: each case signs in after resetting.
        status, _ = self.fixture.call("GET", "/me")
        self.assertEqual(status, 401)
        self.sign_in()
        self.assertIsNone(self.progress("pdf-1"), "the PDF opens at page 1 again")
        self.assertIsNone(self.progress("multi-1"))
        self.assertEqual(self.recent_ids(), fresh_order, "no activity reorders the library")
        self.assertEqual(len(mock.Handler.state.books), books)
        self.assertEqual(smoke_server.PROGRESS_LOG.snapshot(), {})
        status, stats = self.control_call("GET", "/stats")
        self.assertEqual(status, 200)
        self.assertEqual(stats["progress_writes"], {})
        self.assertEqual(stats["grant_requests"], 0)
        self.assertFalse(smoke_server.READING.stale)
        self.assertIs(smoke_server.READING.state, mock.Handler.state, "read-along books are in the new fixture")
        details = self.fixture.call("GET", "/library/paired-1", headers=dict(FORMATS, **FEATURES))
        self.assertEqual(details[0], 200)
        self.assertEqual(details[1]["assets"][0]["read_along"]["status"], "available")

    def test_within_a_case_places_and_writes_persist_offline_and_back(self):
        self.control_call("POST", "/place", {"publication": "comic-1", "asset": "cbz-1", "page": 3})
        self.assertEqual(self.control_call("POST", "/offline")[1], {"offline": True})
        self.assertEqual(self.control_call("POST", "/online")[1], {"offline": False})
        self.assertEqual(self.progress("comic-1")["locator"]["locations"]["position"], 3,
                         "going offline is not a reset")


if __name__ == "__main__":
    unittest.main(verbosity=2)
