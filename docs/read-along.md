# Read-along

Read-along shows the words being narrated while an ebook is heard. Shelfarr
offers it only where real text/audio alignment exists for the exact files in
the library. It never estimates timing from chapter lengths, percentages,
durations or text length, and it never substitutes speech synthesis for
narration. Books without alignment read and play exactly as before.

| | Server and consumer API | Web reader | Native apps |
|---|---|---|---|
| EPUB 3 Media Overlays (narration inside the EPUB) | Implemented | Implemented, online and offline | iOS/iPad implemented; SDK/runtime checks pending. Android in progress. |
| Imported alignment (EPUB + separate audiobook) | Implemented (admin import) | Implemented, online and offline | iOS/iPad implemented; SDK/runtime checks pending. Android in progress. |
| Computing alignment (forced aligner) | Not implemented | — | — |

Read-along is **not** an ebook format. It adds no asset, does not change how
any client opens an EPUB, and is invisible to installed clients unless they
declare the feature.

## Sources of alignment

**`media_overlay`**: an EPUB 3 publication whose spine documents name SMIL
Media Overlays ([EPUB 3.3 §9](https://www.w3.org/TR/epub-33/#sec-media-overlays)).
Each SMIL `<par>` pairs `<text src="chapter.xhtml#id">` with
`<audio src="audio.mp3" clipBegin=… clipEnd=…>`. Clock values follow the
[SMIL 3.0 grammar](https://www.w3.org/TR/SMIL3/smil-timing.html#q22): full
(`1:02:03.5`), partial (`02:03.5`) and timecount (`3.5`, `3.5s`, `250ms`,
`2min`, `1.5h`) values, converted to whole milliseconds. Text-only `<par>`s are
ignored; a clip without `clipEnd` runs to the end of its file and must be the
last cue on that file.

**`imported`**: an alignment produced elsewhere (for example by an aligner run
against the server's own files) for an EPUB and a separate audiobook. An
administrator imports a `shelfarr-read-along` version 1 document:

```json
{
  "format": "shelfarr-read-along",
  "version": 1,
  "tool": "aligner name and version (optional, ≤ 128 bytes)",
  "ebook": { "sha256": "<SHA-256 of the exact EPUB file>" },
  "audio": [ { "filename": "01.mp3", "sha256": "<SHA-256 of that file>" } ],
  "cues": [
    { "href": "OEBPS/chapter1.xhtml", "fragment": "p1", "audio": 0, "begin": 0.0, "end": 1.8 }
  ]
}
```

`href` is the archive path of a spine document, `fragment` an element ID in
it, `audio` an index into `audio`, `begin`/`end` seconds as JSON numbers
(stored to the millisecond). No other keys are accepted.

```sh
bin/rails "read_along:import[EBOOK_ID,AUDIOBOOK_ID,/path/to/alignment.json]"
bin/rails "read_along:recheck[EBOOK_ID]"   # rebind after files moved, only if the bytes are unchanged
bin/rails "read_along:remove[EBOOK_ID]"
bin/rails read_along:list
```

An import succeeds only when the EPUB and every listed audio file hash to the
document's digests. It is then bound to those files' asset generations. When
either generation changes (the file was replaced, moved or touched), the
alignment becomes `stale` until `recheck` proves the bytes are still the same.
One imported alignment exists per ebook record; importing again replaces it.

## Validation (both sources)

The whole alignment is refused (`invalid`) unless every cue names an element
that exists in a spine text document of this exact EPUB generation, and an
interval `0 ≤ begin < end ≤ 48 h` of an audio resource that is:

- for `media_overlay`, a present manifest item of an audio type inside the EPUB;
- for `imported`, one of the verified audiobook files.

Within one audio resource, cues sorted by start must not overlap (5 ms
tolerance for rounded clip values). At most 200,000 cues.

Safety bounds: plain ZIP32 only (ZIP64, encryption, links, traversal and
duplicate names refused); XML parsed without network access, DTD loading or
entity substitution, and documents declaring entities or using UTF-16/32
refused; package and container ≤ 4 MiB, each SMIL ≤ 8 MiB and all SMIL ≤ 64 MiB,
each text document ≤ 16 MiB and all ≤ 96 MiB; every reference resolved inside
the package (remote and absolute references are never fetched); deflated entries
inflate within their announced size with CRC checks. An EPUB that cannot be
read safely is reported as `unaligned` with a reason, not as narrated.

## Statuses

| Status | Meaning | Manifest response |
|---|---|---|
| `available` | A validated manifest exists; `coverage.complete` may still be false | 200 |
| `unaligned` | No alignment for this edition | 404 `read_along_unaligned` |
| `stale` | An imported alignment was made for an earlier file generation | 409 `read_along_stale` |
| `invalid` | Alignment data exists but was refused; `reason` says why | 422 `read_along_invalid` |

A request for an asset generation that no longer exists is 410 `asset_unavailable`.

## Discovering read-along

`GET /api/consumer/v1/server.json` lists `"reader_features":["read-along"]` and
`"read_along_manifest_versions":[1]`.

A client opts in on `GET /library/:id` with:

```
X-Shelfarr-Reader-Features: read-along
```

(a comma-separated list of lowercase hyphenated names ≤ 128 bytes; unknown
names are ignored, malformed values are 400 `invalid_request`; responses
`Vary` on it). Each EPUB asset then carries a summary. Without the header the
projection is byte-for-byte unchanged. Listings and Continue never include it.

```json
"read_along": {
  "status": "available",
  "source": "media_overlay",
  "generation": "<64 hex>",
  "manifest_url": "/api/consumer/v1/library/12/assets/<asset>/read_along",
  "coverage": { "complete": false, "text_sections": 3, "aligned_sections": 2, "cues": 812, "audio_ms": 3605000 },
  "text_bytes": 1840211,
  "audio_bytes": 61022451
}
```

Other statuses carry `status`, `source` (when known) and `reason`. An
`unaligned` EPUB whose work has an acquired audiobook names it
(`"audiobook": {"id","title"}`) so a client can say why read-along is missing.

## Manifest (version 1)

`GET /library/:id/assets/:asset_id/read_along` (scope `library:read`):

```json
{
  "version": 1,
  "generation": "<64 hex>",
  "source": "media_overlay",
  "publication_id": "12",
  "ebook_asset_id": "<64 hex>",
  "package_path": "OEBPS/content.opf",
  "text": [ { "href": "OEBPS/chapter1.xhtml", "media_type": "application/xhtml+xml" } ],
  "audio": [
    { "kind": "epub_resource", "href": "OEBPS/audio/narration.mp3", "media_type": "audio/mpeg", "size_bytes": 96574,
      "url": "/api/consumer/v1/library/12/assets/<asset>/read_along/resources/OEBPS/audio/narration.mp3" }
  ],
  "cue_fields": ["text", "fragment", "audio", "begin_ms", "end_ms"],
  "cues": [ [0, "p1", 0, 0, 1800], [0, "p2", 0, 2000, 3800] ],
  "coverage": { "complete": true, "text_sections": 2, "aligned_sections": 2, "unaligned_sections": [], "cues": 8, "audio_ms": 14400 },
  "resources": [ { "href": "META-INF/container.xml", "media_type": "application/xml", "size_bytes": 249, "url": "…" } ],
  "resources_bytes": 6188,
  "manifest_url": "…/read_along",
  "resources_url": "…/read_along/resources/"
}
```

- `cues` are in reading order (spine order, then document order). Each is
  `[text index, element ID, audio index, begin ms, end ms or null]`.
  Imports are normalized to that order without changing audio indexes or
  intervals, even when their input cues are listed in a different order.
- `audio[].kind` is `epub_resource` (an entry inside the same EPUB, by `href`)
  or `publication_asset` (an audiobook asset, by `publication_id` and
  `asset_id`, plus `filename`; the API also gives its normal `content_url`, so
  native clients download it with the existing transfer grant).
  A manifest has at most 2,000 audio tracks (indexes 0–1,999), matching the
  clients and saved-place format; an overlay above that limit is invalid.
- `resources` lists every entry a streaming reader may load for the text
  (container, package, and manifest items except audio, video, SMIL and
  script). `resources_bytes` is their total.
- `generation` binds the manifest to this EPUB generation, the audio
  generations and (for imports) the alignment record. Any change gives a new
  generation; old ones are never re-pointed.
- `coverage.unaligned_sections` lists (up to 50) linear text documents with
  readable text but no cues. They are read as text only.

### Resources and audio

- `GET …/read_along/resources/*path`: one listed archive entry (or an
  `epub_resource` narration file), GET/HEAD, single byte ranges, strong ETag,
  `If-Range`, `Content-Disposition: attachment`, `nosniff`, a sandboxing
  Content-Security-Policy, and `X-Shelfarr-Read-Along: <generation>`. Any
  other path is 404; a changed generation is 410.
- `GET …/read_along/audio/:audio_asset_id`: an imported alignment's audiobook
  file, served exactly as `GET /library/:audiobook/assets/:id` and only while
  that alignment is current.

The browser reader uses the same routes under `/read/:id/assets/:asset_id/…`
with its session.

## Saved places

Read-along adds no new progress endpoint. A place reached by listening is an
ordinary EPUB locator for the cue's element, with the exact narration offset:

```json
{
  "href": "OEBPS/chapter2.xhtml",
  "type": "application/xhtml+xml",
  "locations": {
    "fragments": ["p6"],
    "cfi": "epubcfi(/6/4!/4/6[user-content-p6])",
    "totalProgression": 0.33,
    "readAlong": { "generation": "<64 hex>", "audio": 0, "offset_ms": 13743 }
  }
}
```

`locations.readAlong` must have exactly those keys (`generation` 64 hex,
`audio` 0–1999, integer `offset_ms` ≤ 48 h); anything else is 422. Clients that
don't read along ignore it and use `cfi` (the web reader's own) or
`fragments`. A reader restoring a place trusts the offset only when
`generation` matches its manifest and the offset's cue is in the same `href`;
otherwise it starts at that element's cue.

Rules every client follows (the web reader does):

1. A listening checkpoint is written at most every five seconds of playback
   and at once on pause, seek, file change or leaving. Its `observed_at` is
   when it was heard, kept through offline queues and retries.
2. The text place is the last cue **reached** at that audio offset (its
   element), never an interpolated position, and nothing is written before the
   first cue is reached.
3. For an imported alignment, the audiobook's own progress (`asset_id`,
   `position_seconds`) is written with the **same** `observed_at`.
4. Restoring a place, resizing, page-follow and receiving a remote place are
   not activity. A genuine resume rewinds five seconds once; pausing inside
   that replayed span does not move the saved place back.
5. Turning pages while narration plays is browsing and writes nothing; while
   paused it is reading and writes a normal reading place (without
   `readAlong`), and the next Play starts from the narration on that page.
6. An audiobook place observed later than the ebook place (heard on its own
   player or another device) is **offered**, never written into the ebook.

## Web reader

- Opening: an EPUB with an `available` summary and `text_bytes ≤ 32 MiB` is
  read entry by entry from `resources_url` (or this browser's download), with
  audio, video and SMIL removed from the text engine's manifest. Narration
  plays through an `<audio>` element, so its size does not count against the
  web limit. Above 32 MiB of text resources the reader states the limit and
  points to a native app; reading the EPUB is unchanged.
- Controls: Play/Pause, back 15 s / forward 30 s, "Follow the text" and speed
  are in the reading-controls overlay with the coverage note. Once narration
  has started, a small Pause/Play pill (and "Back to the narration" after
  browsing) appears at the bottom; nothing else is added to the page. Space
  toggles narration; the browser's media session controls work.
- Highlight: the element of the cue being heard (nothing between cues); the
  page turns only when that element is out of view and follow is on.
- Resume: an accepted later place from another device is restored before
  narration resumes. A failed restore stays paused and retains that place
  for retry; restoring it never records listening activity.
- Offline: Download stores the manifest, every listed resource and every
  narration file. It is ready only when all are in this account's cache; a
  partly evicted download is shown as removed; a new generation is an update.
  Cancel reclaims resources already stored by an interrupted transfer. Cancelling
  an update preserves the earlier complete copy.

## Native implementations

The [iOS/iPad implementation](native-read-along-ios.md) includes core tests and
simulator smoke coverage. Its app-side SDK build, rendering and playback still
need macOS CI; Linux tests and syntax parsing do not verify those paths. Android
implementation is in progress. Physical-device acceptance remains separate.

Both clients follow these shared integration requirements:

1. Send `X-Shelfarr-Reader-Features: read-along` on publication detail and
   fetch the manifest; cache it with the download (bound to `generation`).
2. `media_overlay`: play `epub_resource` audio from the downloaded EPUB
   (Readium can expose the entry); `imported`: download the audiobook asset
   by `publication_id`/`asset_id` with the existing transfer grant.
3. Highlight by element ID in the rendered document (Readium decorations) and
   follow pages only for out-of-view cues.
4. Reuse the platform listening checkpoints and media session; write places
   as above, including the paired audiobook place with the same `observed_at`.
5. Readiness: an offline read-along book is ready only with the manifest, the
   EPUB and all audio files present for the same generation.

Not implemented anywhere: computing alignment on the server, chapter-level
switching between separate formats, and highlighting below the cue (word)
level when cues are sentences or paragraphs.
