# PDF and comic reading

Shelfarr's consumer API and browser reader can open PDFs and CBZ comics in
addition to EPUBs and audio. This page describes what is implemented, how
clients opt in, and what stays out of scope.

| Format | Consumer API | Web reader | Native apps |
|---|---|---|---|
| EPUB | Yes (default) | Yes, ≤ 32 MiB | Yes |
| PDF (`application/pdf`) | Opt-in, ≤ 500 MiB | Yes, page rendering with text selection | Android implemented; iOS implemented, SDK/runtime verification pending |
| CBZ (`application/vnd.comicbook+zip`) | Opt-in, ≤ 2 GiB, JPEG/PNG/WebP pages | Yes, page images | Android implemented; iOS implemented, SDK/runtime verification pending |
| CBR/RAR, CB7, MOBI/AZW | Not supported | Not supported | Not supported |
| Read-along (text + narration) | Feature, not a format: [read-along](read-along.md) | Yes | Not yet |

Read-along is not a reading format and is not negotiated here. It is declared
with `X-Shelfarr-Reader-Features` and described in [read-along](read-along.md).

Native behavior and verification limits are documented for
[Android](native-formats-android.md) and [iPhone/iPad](native-formats-ios.md).
Native rendering on physical devices remains a separate acceptance gate.

## Format negotiation

Clients declare what they can open on library calls:

```
X-Shelfarr-Reader-Formats: epub,pdf,cbz
```

- Sent on `GET /library`, `GET /library/:id`, `GET /continue` and
  `PUT /library/:id/reading_status`. Missing means **EPUB only**: installed
  apps keep exactly the projection they were built against.
- The value is a lowercase comma list of `epub`, `pdf` and `cbz`, at most 64
  bytes, with optional spaces around names. Duplicates and order are normalized
  (`pdf,epub,pdf` equals `epub,pdf`). Empty, unknown or uppercase names receive
  400 `{"error":"invalid_request"}`. Responses carry
  `Vary: X-Shelfarr-Reader-Formats`.
- Only declared formats are serialized. Audio publications are unaffected.
- Cursors are bound to the normalized selection. The default selection keeps its
  previous cursor identity, so `epub` (explicit) and no header share cursors,
  and an EPUB-only cursor is refused for an `epub,pdf,cbz` listing.
- Comic records (stored as `comicbook`) are listed only when `pdf` or `cbz` is
  declared, and always appear as `book_type: "ebook"`; no new `book_type`
  value reaches installed apps. Clients that send the header also receive
  `content_kind`: `graphic` for comic records or ebooks marked graphic,
  otherwise `book`. `type=ebook` includes comic records for those clients.
- `GET /server.json` lists `reader_formats` the server can serve, before sign-in.
  It says nothing about what a given client can render.

Asset, transfer, reading-order and progress endpoints do not need the header:
asset IDs are exact file generations, and only a capable client can learn the
ID of a PDF or CBZ.

```json
{
  "id": "42",
  "book_type": "ebook",
  "content_kind": "graphic",
  "assets": [{
    "id": "opaque-file-generation-id",
    "filename": "Issue 1.cbz",
    "format": "cbz",
    "media_type": "application/vnd.comicbook+zip",
    "size_bytes": 48211337,
    "position": 0,
    "content_url": "/api/consumer/v1/library/42/assets/opaque-file-generation-id",
    "page_count": 24,
    "reading_order_url": "/api/consumer/v1/library/42/assets/opaque-file-generation-id/reading_order"
  }]
}
```

A folder can hold several formats of one work; each file is a separate asset
in natural filename order. Clients choose which to open and must not apply one
asset's place to another.

## What the server checks

The server never extracts pages, renders PDFs or inflates images. It opens the
already-authorized file descriptor and checks only:

- **PDF:** size ≤ 500 MiB and a `%PDF-x.y` header in the first 1 KiB. A file
  without one is not listed. This does not prove every page renders; a damaged
  or password-protected PDF can still fail in the client, which must say so.
- **CBZ:** size ≤ 2 GiB and bounded ZIP metadata, before any entry is parsed:
  - plain ZIP32 on one disk; exactly one consistent end-of-central-directory
    record; the directory ends where that record begins; no ZIP64 locator;
  - at most 10,000 entries and a 2 MiB central directory;
  - methods stored (0) or deflate (8) only; no encryption flags, AES or masked
    headers; no ZIP64 or Info-ZIP Unicode-path extra fields;
  - names are UTF-8 when flagged, otherwise ASCII; no absolute, drive,
    backslash, control-character, empty, `.` or `..` parts; no duplicate
    names, including Unicode-equivalent spellings; no symlinks or special files;
  - every local header repeats its directory entry's flags, method, name and
    (without a data descriptor) CRC and sizes; entries do not overlap;
  - pages are `.jpg`, `.jpeg`, `.png` or `.webp` files, 1 byte to 32 MiB each and
    2 GiB in total, ignoring hidden and `__MACOSX` entries. At least one page.
    Each page's compressed input is capped at 32 MiB plus 64 KiB for DEFLATE
    overhead, before any page bytes are fetched or allocated by the web reader.
  - the page list response stays within 8 MiB.

  Any violation leaves the CBZ out of the listing (and a progress or
  reading-order request for it fails), rather than offering a book that cannot
  open safely. A valid archive can still contain an image that fails to decode.

A malformed PDF or CBZ never hides a valid EPUB or audio file beside it, and an
EPUB-only client never waits for, or is affected by, PDF/CBZ inspection.

## CBZ reading order

```
GET /api/consumer/v1/library/:id/assets/:asset_id/reading_order
{
  "asset_id": "opaque-file-generation-id",
  "format": "cbz",
  "items": [{
    "position": 1,
    "href": "Issue%201/page01.jpg",
    "media_type": "image/jpeg",
    "size_bytes": 1832211,
    "compressed_size": 1824002,
    "compression_method": 8,
    "local_header_offset": 0,
    "crc32": "9a3c01ef"
  }]
}
```

- Requires `library:read`. 410 `asset_unavailable` for a changed generation, an
  unknown asset, a non-CBZ asset or an archive that fails the checks above.
- Items are in natural, case-insensitive name order (`page2` before `page10`),
  with the exact name breaking ties. `position` is one-based. `href` is the
  ZIP-root entry name with every byte outside `A-Z a-z 0-9 - . _ ~ /`
  percent-encoded. No filesystem path appears.
- `local_header_offset`, `compressed_size` and `compression_method` let a
  client range-read one page from `content_url`. It must read the 30-byte local
  header, check its signature, name length and method, skip its name and extra
  field, inflate at most `size_bytes` (`deflate-raw` for method 8) and compare
  the length and CRC-32 with the item before decoding. Clients bound decoded
  image dimensions and memory; nothing extracts the whole archive.
- Native clients may download the archive and use their own ZIP reader, but must
  follow this page order and these checks.

## Page locators

PDF and CBZ places use the existing progress endpoint, version, UUID retry and
`observed_at` rules unchanged. Only the locator shape differs.

PDF (one resource, `document.pdf`; pages bounded at 100,000):

```json
{"href": "document.pdf", "type": "application/pdf",
 "locations": {"position": 12, "totalProgression": 0.36, "fragments": ["page=12"]}}
```

CBZ (item N of this generation's reading order):

```json
{"href": "Issue%201/page12.jpg", "type": "image/jpeg",
 "locations": {"position": 12, "totalProgression": 0.46}}
```

- `locations.position` is required, a one-based integer. `progression` and
  `totalProgression` are optional, from 0 to 1. A PDF may send exactly
  `fragments: ["page=N"]` for the same N; a CBZ sends no fragments.
- Allowed keys are `href`, `type`, `title` (≤ 1 KiB), `text` and `locations`,
  and within `locations` only those above. A `cfi` or any other text position
  is refused with 422: an EPUB place is never applied to a PDF or an image.
- The server checks a PDF place only against the 100,000-page bound, since it
  does not parse pages. Clients clamp only their display to the actual page
  count; restoring an out-of-range place must not invent a page-one activity
  or overwrite the saved place.
- A CBZ place must match the reading order's `href`, `media_type` and
  `position` for that exact asset generation. A replaced archive is a new
  generation; its old places return 422.
- Opening, restoring, zooming, rotating, re-rendering and remote
  acknowledgements are not reading activity. Save actual page changes at once.

Continue only offers a publication whose saved place is on an asset the caller
can open, so an EPUB-only app does not list a book last read as a PDF.

## Web page reader

The browser reader at `/read/:id` opens PDF and CBZ assets in a page reader that
shares the EPUB reader's quiet surface, progress outbox, conflict handling,
offline shell and account binding.

- **Quiet by default.** The page fills the screen with no header or toolbar.
  Taps on the left or right third, swipes (at fit size), arrow and Page keys
  turn pages. A tap in the middle, Escape or the focusable **Show reading
  controls** button reveals the overlay: library link, title, Previous / Next
  with **Page N of M**, a page number field and slider, zoom (−, Fit, +), the
  format choice when there are several, sync state, Download and reading
  status. EPUB font controls are not shown for pages. Controls are at least
  48 px tall and sized in `rem`, so browser text size applies. Page turns are
  announced to screen readers; comic pages have "Page N of M" alternative text.
- **PDF.** Self-hosted Mozilla PDF.js 6.4.299 (patched for GHSA-hq66-cqwq-w95j;
  that release has no `eval`/`new Function` path). Scripting, XFA and the
  annotation/form layer are off: annotation appearances are drawn into the page
  image and no link, form field or script becomes interactive. Pages are
  fetched with 256 KiB range requests without background prefetching. The
  worker, standard fonts (system fonts are not used), CMaps and the OpenJPEG and
  JBIG2 WebAssembly decoders come only from digested Shelfarr assets through a
  resource factory that refuses names or origins not on the page's list. Each
  page is a canvas (capped at 16 million pixels) with PDF.js's selectable,
  invisible text layer; selecting text never turns a page. Password-protected
  or damaged PDFs show a plain explanation.
- **CBZ.** The reader fetches the reading order, checks it against the asset,
  then range-reads one page at a time (plus the next, in the background). Each
  local header is compared with the order, data is inflated with
  `DecompressionStream("deflate-raw")` only up to the announced size, length and
  CRC-32 are verified, and the image header must be JPEG, PNG or WebP of at most
  16,384 px a side and 40 megapixels before the browser decodes it. A page that
  fails says "Page N couldn't be shown" instead of leaving the previous page on
  screen. Pages show in natural order, left to right; reading direction and
  two-page spreads are not inferred.
- **Zoom.** +/− buttons and keys, and two-finger pinch, zoom
  from 100% to 400%; a zoomed page pans, and **Fit** or `0` returns to the whole
  page. Rotating or resizing refits the current page. Zoom and refit are never
  reading activity.
- **Places.** Only a page the reader turns to or chooses is saved, immediately,
  through the browser outbox with its activity time. Opening restores the saved
  page silently. A saved page that no longer exists shows the nearest page
  with a notice and keeps the saved place until a real turn.
- **Several formats.** Without a saved place, comics open as CBZ (then PDF),
  other books as EPUB (then PDF). With one, the format holding it opens. The
  format list marks "your place"; choosing another format opens it at its
  beginning, says so, and saves nothing until a page is turned there.
- **Offline.** A PDF or CBZ download is complete only when its bytes, and for a
  CBZ its reading order for the same generation, are in this account's cache.
  Offline, the service worker answers page ranges and the reading order from
  that cache, and the PDF engine, worker, fonts, CMaps and decoders from its
  precached shell assets. Eviction of either part makes the download "stopped"
  rather than ready; an edition update keeps the old copy until the new one is
  complete, then removes both of the old entries.

Not verified here: Safari/WebKit and Firefox, real touch devices, and very
large or unusual PDFs. Automated browser tests use Chromium with generated
files.

## Kobo

Kobo delivery remains EPUB-only. Its progress bridge lists consumer assets with
the default EPUB selection, so a PDF or CBZ is never routed into Kobo's EPUB
handling.
