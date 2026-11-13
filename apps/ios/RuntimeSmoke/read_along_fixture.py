"""Read-along fixture books for the iOS simulator smoke test (docs/read-along.md).

Loaded by smoke_server.py on top of apps/scripts/mock_consumer_server.py, which stays
unchanged. The alignment is known exactly because the audio is generated for it: every
cue is a two-second tone of its own pitch, with 600 ms of silence between cues, so a cue
heard is a tone heard and a gap is silence. Nothing here estimates timing.

* "Narrated Fixture" (narrated-1): an EPUB 3 with real Media Overlays. Its spine
  documents name SMIL files whose <par>s pair <text src="c1.xhtml#p1"> with
  <audio src="audio/c1.wav" clipBegin=... clipEnd=...>, and the WAV narration is inside
  the EPUB. Paragraph p3 is long, so p4 starts on a later page on iPhone and iPad.
* "Paired Fixture" (paired-1) and "Paired Fixture Narration" (paired-audio): an EPUB
  without overlays and a separate two-track audiobook, with an imported alignment
  bound to both by SHA-256, as `read_along:import` would store it.

Clients see summaries only on details requested with `X-Shelfarr-Reader-Features:
read-along`; listings and other clients are unchanged. The titles sort after the
mock's "Mock Book" titles, so the existing smoke's library pages are unchanged too.
"""

import hashlib
import io
import json
import math
import re
import struct
import threading
import wave
import zipfile

RATE = 8000
CUE_MS = 2000
GAP_MS = 600
VERSION = 1
FEATURES_HEADER = "X-Shelfarr-Reader-Features"
FEATURE_NAME = re.compile(r"\A[a-z][a-z0-9-]{0,31}\Z")
HEX = re.compile(r"\A[0-9a-f]{64}\Z")
MAX_MS = 48 * 3_600_000

NARRATED = [
    ("c1", "By the River", [
        ("p1", "The river was high that spring, and the ferry ran only at noon."),
        ("p2", "Mara counted the boats from the bridge before the bells began."),
        ("p3", " ".join(["The water carried branches, a door, a chair, and the smell of rain from the hills."] * 70)),
        ("p4", "When the bells stopped, the ferryman lifted his lantern and called her name."),
        ("p5", "She ran down the steps with the letter held against her coat."),
        ("p6", "On the far bank the town was already lighting its windows."),
    ]),
    ("c2", "The Far Bank", [
        ("q1", "The inn kept one room for travellers who arrived after dark."),
        ("q2", "Mara read the letter twice by the fire before she understood it."),
        ("q3", "In the morning she would go back across the water."),
    ]),
]

PAIRED = [
    ("d1", "The Lighthouse", [
        ("r1", "The lighthouse stood at the end of a long stone pier."),
        ("r2", "Every evening the keeper climbed one hundred and twelve steps."),
        ("r3", "From the lamp room he could see the whole curve of the bay."),
    ]),
    ("d2", "Fog", [
        ("s1", "In autumn the fog came in so thick the lamp seemed to float."),
        ("s2", "Ships answered the horn with their own, far out in the grey."),
    ]),
]


def tone_track(count, first_index):
    """WAV narration: `count` cues of two seconds, each its own pitch, 600 ms of silence after each."""
    frames = bytearray()
    for index in range(count):
        hertz = 300 + 60 * (first_index + index)
        for n in range(RATE * CUE_MS // 1000):
            frames += struct.pack("<h", int(5000 * math.sin(2 * math.pi * hertz * n / RATE)))
        frames += b"\0\0" * (RATE * GAP_MS // 1000)
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(RATE)
        audio.writeframes(bytes(frames))
    return buffer.getvalue()


def cue_times(count):
    return [(index * (CUE_MS + GAP_MS), index * (CUE_MS + GAP_MS) + CUE_MS) for index in range(count)]


def clock(ms):
    return f"{ms / 1000:g}s"


def chapter_xhtml(title, paragraphs):
    body = "".join(f'<p id="{pid}">{text}</p>' for pid, text in paragraphs)
    return ('<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml">'
            f"<head><title>{title}</title></head><body><h1>{title}</h1>{body}</body></html>")


def build_epub(chapters, title, overlays):
    """An EPUB 3; with `overlays`, each chapter has a SMIL overlay and WAV narration inside."""
    files = {}
    manifest, spine, toc = [], [], []
    audio = {}
    for n, (cid, heading, paragraphs) in enumerate(chapters):
        files[f"OEBPS/{cid}.xhtml"] = chapter_xhtml(heading, paragraphs).encode()
        overlay = f' media-overlay="m{cid}"' if overlays else ""
        manifest.append(f'<item id="{cid}" href="{cid}.xhtml" media-type="application/xhtml+xml"{overlay}/>')
        spine.append(f'<itemref idref="{cid}"/>')
        toc.append(f'<li><a href="{cid}.xhtml">{heading}</a></li>')
        if overlays:
            track = tone_track(len(paragraphs), sum(len(c[2]) for c in chapters[:n]))
            audio[cid] = track
            files[f"OEBPS/audio/{cid}.wav"] = track
            pars = "".join(
                f'<par id="{pid}-par"><text src="{cid}.xhtml#{pid}"/>'
                f'<audio src="audio/{cid}.wav" clipBegin="{clock(begin)}" clipEnd="{clock(end)}"/></par>'
                for (pid, _), (begin, end) in zip(paragraphs, cue_times(len(paragraphs))))
            files[f"OEBPS/{cid}.smil"] = (
                '<?xml version="1.0" encoding="UTF-8"?><smil xmlns="http://www.w3.org/ns/SMIL" '
                'xmlns:epub="http://www.idpf.org/2007/ops" version="3.0">'
                f'<body><seq epub:textref="{cid}.xhtml">{pars}</seq></body></smil>').encode()
            manifest.append(f'<item id="m{cid}" href="{cid}.smil" media-type="application/smil+xml"/>')
            manifest.append(f'<item id="a{cid}" href="audio/{cid}.wav" media-type="audio/wav"/>')
    files["META-INF/container.xml"] = (
        '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
        '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>').encode()
    files["OEBPS/nav.xhtml"] = (
        '<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
        '<head><title>Contents</title></head><body><nav epub:type="toc"><ol>' + "".join(toc) + "</ol></nav></body></html>").encode()
    meta = '<meta property="media:active-class">-epub-media-overlay-active</meta>' if overlays else ""
    files["OEBPS/content.opf"] = (
        '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">'
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
        f'<dc:identifier id="id">urn:shelfarr:{title.lower().replace(" ", "-")}</dc:identifier>'
        f'<dc:title>{title}</dc:title><dc:language>en</dc:language>{meta}</metadata><manifest>'
        '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
        + "".join(manifest) + "</manifest><spine>" + "".join(spine) + "</spine></package>").encode()
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as book:
        book.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        for name in ["META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml"] + \
                [n for n in files if n not in ("META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml")]:
            # Narration is stored, as real overlay EPUBs usually keep it; text is deflated.
            method = zipfile.ZIP_STORED if name.endswith(".wav") else zipfile.ZIP_DEFLATED
            book.writestr(zipfile.ZipInfo(name), files[name], compress_type=method)
    return buffer.getvalue(), files, audio


MEDIA_TYPES = {".xhtml": "application/xhtml+xml", ".opf": "application/oebps-package+xml", ".xml": "application/xml",
               ".smil": "application/smil+xml", ".wav": "audio/wav"}


def media_type(path):
    for suffix, kind in MEDIA_TYPES.items():
        if path.endswith(suffix):
            return kind
    return "application/octet-stream"


class ReadAlong:
    """Installs the fixture books into a mock State and serves their read-along routes."""

    def __init__(self, state):
        self.lock = threading.Lock()
        self.state = state
        narrated, self.narrated_files, _ = build_epub(NARRATED, "Narrated Fixture", overlays=True)
        paired, self.paired_files, _ = build_epub(PAIRED, "Paired Fixture", overlays=False)
        self.tracks = [tone_track(len(paragraphs), 0) for _, _, paragraphs in PAIRED]
        state.files.update({
            "epub-n": ("narrated-fixture.epub", "application/epub+zip", "epub", narrated),
            "epub-p": ("paired-fixture.epub", "application/epub+zip", "epub", paired),
            "track-p1": ("Paired 1.wav", "audio/wav", "wav", self.tracks[0]),
            "track-p2": ("Paired 2.wav", "audio/wav", "wav", self.tracks[1]),
        })
        state.books.update({
            "narrated-1": ("Narrated Fixture", "Fixture Narrator", "ebook", ["epub-n"]),
            "paired-1": ("Paired Fixture", "Fixture Author", "ebook", ["epub-p"]),
            "paired-audio": ("Paired Fixture Narration", "Fixture Narrator", "audiobook", ["track-p1", "track-p2"]),
        })
        self.reset()

    def reset(self):
        with self.lock:
            self.stale = False
            self.imported_revision = 1

    def mark_stale(self):
        with self.lock:
            self.stale = True

    def realign(self):
        """Imports the alignment again: a new generation for the same files."""
        with self.lock:
            self.stale = False
            self.imported_revision += 1

    # Manifests ---------------------------------------------------------------------

    def generation(self, publication_id):
        if publication_id == "narrated-1":
            return hashlib.sha256(b"media_overlay\x001\x00epub-n").hexdigest()
        with self.lock:
            revision = self.imported_revision
        digest = hashlib.sha256(self.state.files["epub-p"][3]).hexdigest()
        return hashlib.sha256(f"imported\x00{revision}\x00{digest}".encode()).hexdigest()

    def core(self, publication_id):
        """The route-free manifest for a fixture book, or None for any other."""
        if publication_id == "narrated-1":
            chapters, files, source, asset = NARRATED, self.narrated_files, "media_overlay", "epub-n"
        elif publication_id == "paired-1":
            chapters, files, source, asset = PAIRED, self.paired_files, "imported", "epub-p"
        else:
            return None
        texts, cues = [], []
        for index, (cid, _, paragraphs) in enumerate(chapters):
            texts.append({"href": f"OEBPS/{cid}.xhtml", "media_type": "application/xhtml+xml"})
            for (pid, _), (begin, end) in zip(paragraphs, cue_times(len(paragraphs))):
                cues.append([index, pid, index, begin, end])
        if source == "media_overlay":
            audio = [{"kind": "epub_resource", "href": f"OEBPS/audio/{cid}.wav", "media_type": "audio/wav",
                      "size_bytes": len(files[f"OEBPS/audio/{cid}.wav"])} for cid, _, _ in chapters]
        else:
            audio = [{"kind": "publication_asset", "publication_id": "paired-audio", "asset_id": track,
                      "filename": self.state.files[track][0], "media_type": "audio/wav",
                      "size_bytes": len(self.state.files[track][3])} for track in ("track-p1", "track-p2")]
        resources = [{"href": path, "media_type": media_type(path), "size_bytes": len(files[path])}
                     for path in ["META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml"]
                     + [f"OEBPS/{cid}.xhtml" for cid, _, _ in chapters]]
        return {
            "version": VERSION, "generation": self.generation(publication_id), "source": source,
            "ebook_asset_id": asset, "package_path": "OEBPS/content.opf", "text": texts, "audio": audio,
            "cue_fields": ["text", "fragment", "audio", "begin_ms", "end_ms"], "cues": cues,
            "coverage": {"complete": True, "text_sections": len(chapters), "aligned_sections": len(chapters),
                         "unaligned_sections": [], "cues": len(cues), "audio_ms": len(cues) * CUE_MS},
            "resources": resources, "resources_bytes": sum(r["size_bytes"] for r in resources),
        }

    def summary(self, base, publication_id, asset_id, prefix):
        """An EPUB asset's `read_along` summary, as the server projects it."""
        url = f"{base}{prefix}/library/{publication_id}/assets/{asset_id}/read_along"
        if publication_id == "paired-1" and self.stale:
            return {"status": "stale", "source": "imported",
                    "reason": "The audiobook files changed after the alignment was imported. An administrator can recheck it."}
        core = self.core(publication_id)
        if core is None:
            if publication_id == "book-1":
                return {"status": "unaligned", "audiobook": {"id": "audio-1", "title": "A Test Audiobook"}}
            return {"status": "unaligned"}
        summary = {"status": "available", "source": core["source"], "generation": core["generation"], "manifest_url": url,
                   "coverage": {k: core["coverage"][k] for k in ("complete", "text_sections", "aligned_sections", "cues", "audio_ms")},
                   "text_bytes": core["resources_bytes"], "audio_bytes": sum(a["size_bytes"] for a in core["audio"])}
        if core["source"] == "imported":
            summary["audiobook"] = {"id": "paired-audio", "title": "Paired Fixture Narration"}
        return summary

    def manifest(self, base, prefix, publication_id, asset_id):
        """(status, payload) for GET .../read_along."""
        book = self.state.books.get(publication_id)
        if book is None or asset_id not in book[3]:
            return 410, {"error": "asset_unavailable"}
        if publication_id == "paired-1" and self.stale:
            return 409, {"error": "read_along_stale", "status": "stale", "source": "imported"}
        core = self.core(publication_id)
        if core is None:
            return 404, {"error": "read_along_unaligned", "status": "unaligned"}
        root = f"{base}{prefix}/library/{publication_id}/assets/{asset_id}/read_along"
        manifest = dict(core, publication_id=publication_id, manifest_url=root, resources_url=f"{root}/resources/")
        manifest["resources"] = [dict(r, url=f"{root}/resources/{r['href']}") for r in core["resources"]]
        audio = []
        for track in core["audio"]:
            if track["kind"] == "epub_resource":
                audio.append(dict(track, url=f"{root}/resources/{track['href']}"))
            else:
                audio.append(dict(track, url=f"{root}/audio/{track['asset_id']}",
                                  content_url=f"{base}{prefix}/assets/{track['asset_id']}/content"))
        manifest["audio"] = audio
        return 200, manifest

    def resource(self, publication_id, asset_id, path):
        """One listed entry (text or `epub_resource` narration) as a mock file tuple, or None."""
        core = self.core(publication_id)
        if core is None or core["ebook_asset_id"] != asset_id:
            return None
        listed = {r["href"] for r in core["resources"]} | {a.get("href") for a in core["audio"] if a["kind"] == "epub_resource"}
        files = self.narrated_files if publication_id == "narrated-1" else self.paired_files
        if path not in listed or path not in files:
            return None
        return (path.rsplit("/", 1)[-1], media_type(path), "entry", files[path])

    def audio(self, publication_id, asset_id, audio_id):
        core = self.core(publication_id)
        if core is None or core["ebook_asset_id"] != asset_id or (publication_id == "paired-1" and self.stale):
            return None
        if not any(a.get("asset_id") == audio_id for a in core["audio"]):
            return None
        return self.state.files[audio_id]


def parse_features(value):
    """The declared features, or raises ValueError as the server answers 400."""
    if value is None:
        return set()
    if not 1 <= len(value.encode()) <= 128:
        raise ValueError("Declare reader features as a comma-separated list such as read-along")
    names = [name.strip() for name in value.split(",")]
    if not all(FEATURE_NAME.match(name) for name in names):
        raise ValueError("Reader feature names are lowercase words joined by hyphens")
    return set(names) & {"read-along"}


def read_along_error(locator):
    """The server's `locations.readAlong` check (ProgressWriter#valid_read_along?), or None."""
    locations = locator.get("locations") if isinstance(locator, dict) else None
    if not isinstance(locations, dict) or "readAlong" not in locations:
        return None
    value = locations["readAlong"]
    if not isinstance(value, dict) or sorted(value) != ["audio", "generation", "offset_ms"]:
        return "readAlong needs exactly generation, audio and offset_ms"
    if not isinstance(value["generation"], str) or not HEX.match(value["generation"]):
        return "readAlong.generation must be 64 lowercase hex"
    if type(value["audio"]) is not int or not 0 <= value["audio"] <= 1999:
        return "readAlong.audio must be an integer from 0 to 1999"
    if type(value["offset_ms"]) is not int or not 0 <= value["offset_ms"] <= MAX_MS:
        return "readAlong.offset_ms must be whole milliseconds up to 48 hours"
    return None


def json_body(payload):
    return json.dumps(payload).encode()
