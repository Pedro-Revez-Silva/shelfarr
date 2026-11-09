# iOS and iPadOS: PDF and CBZ reading

How the native iOS app reads PDFs and comic archives (CBZ) alongside EPUB. The wire
contract is shared with the web and Android readers ([consumer-formats.md](consumer-formats.md));
this page covers what the iOS client does with it. See
[native-progress-ios.md](native-progress-ios.md) for saving and reconciling places and
[native-offline-ios.md](native-offline-ios.md) for downloads.

## What the app asks for

- Library listings, details, Continue and status changes send
  `X-Shelfarr-Reader-Formats: epub,pdf,cbz` (also when a request is replayed after a
  sign-in handover). Sign-in, progress, files, grants and reading orders don't. A server
  that predates the header ignores it and keeps offering only EPUB files for books.
- Optional fields are read when present and ignored when absent or malformed:
  `content_kind` on a publication (`graphic` for comics), `page_count` and
  `reading_order_url` on a CBZ asset, and `reader_formats` in `server.json`. Publications
  are cached for offline browsing with these fields.
- `book_type` stays `ebook` or `audiobook`. A comic is an `ebook` with
  `content_kind: "graphic"`, so it opens in the reader, never the player.

A book's readable files are one per format, the first of each in the server's order. An
EPUB-only book resolves to exactly the same file as before. A PDF over 500 MiB, a CBZ
over 2 GiB, or a CBZ without a reading order isn't offered.

Page positions are always JSON integers: whole numbers in a locator are written as
`12`, never `12.0`.

## Which format opens

1. A saved place keeps its own format: a place in the PDF opens the PDF.
2. Otherwise a ready download's format.
3. Otherwise the only format there is.
4. With several formats and nothing to go on, the reader asks (*How would you like to read
   it?*), suggesting page images first for comics and text first for other books, and
   marking formats already on the device. Nothing is saved until a page is turned, so the
   next open asks again until there is a place.

Offline, when the saved place is in a format that isn't on the device but another format
is (a download, or a complete reading copy), the reader says so (*Your place is in the
PDF*) and offers *Read the EPUB on this device* instead of failing. The other format
opens at its beginning, the reader is told the place stays where it was, and nothing is
written until a page is turned there. The **Format** menu in the reader switches formats
the same way.

Offline, the place used is the newest the device knows: a download's details are as old
as the download, so a later place seen in the book's cached details (another device's,
perhaps in another format) is used when it belongs to this edition.

An EPUB never reaches the PDF or comic reader, and a PDF or CBZ never reaches Readium.
Readium is used only for EPUB. A place is only ever applied to the file it was saved in.

## The readers

**Opinion.** Pages are the content, so the reader stays out of the way: the page fills
the screen on the chosen page colour with only a small `N / M` folio. A tap in the middle
shows a top bar (close, title, format when there are several, page layout) and a bottom
bar (previous and next in the reading direction, **Page N of M**, which opens **Go to
page**, and a page slider that jumps when let go). Taps on the outer quarters, swipes
(when not zoomed), arrow keys, Page Up/Down and Space (Shift+Space back) turn pages.
Reading direction is an explicit per-book choice in **Page layout**, never guessed from
language or metadata: right to left swaps edge taps, swipes, keys, the buttons, the slider
and the order of a spread. On iPad, **Two pages side by side** shows spreads in landscape,
with the first page alone like a cover. **Fit** chooses the whole page or the page width.

- **PDF** uses PDFKit's `PDFView` directly (`.singlePage`, or `.twoUp` with
  `displaysAsBook` for spreads), keeping PDFKit's text selection and pinch zoom. Before a
  page can be shown, links to anything other than a page of the same document are
  removed, other actions are dropped, and form widgets are made read-only without their
  actions; `pdfViewWillClick(onLink:with:)` is implemented so a remaining URL is never
  opened. A locked PDF is reported as password-protected; a damaged one as damaged.
- **CBZ** uses a `UIPageViewController` of zoomable pages (1–5×, double-tap to zoom; while
  zoomed a drag pans and never turns). Pages are read from the archive one at a time and
  decoded by ImageIO straight to the screen size (`kCGImageSourceThumbnailMaxPixelSize`,
  at most 4096 px), with a sharper copy when zoomed. Decoding is serial and the decoded
  page cache is bounded (32–128 MiB depending on the device). A page that can't be shown
  says *Page N couldn't be shown* instead of leaving another page on screen.

VoiceOver reads each comic page as *Page N of M* (or *Pages N and N+1 of M*), offers
*Next page*, *Previous page* and *Show reading controls* actions, supports three-finger
scrolling by page, and announces page turns. Controls are labelled, at least 44 pt, use
Dynamic Type, and the bottom bar puts the page number on its own line when text is large.

## Places

- **PDF**: `{"href":"document.pdf","type":"application/pdf","locations":{"position":N,
  "totalProgression":(N-1)/count,"fragments":["page=N"]}}`, N one-based.
- **CBZ**: `href` and `type` of item N in the generation's reading order (the exact escaped
  href), `position` N, `totalProgression` (N-1)/count. No fragments, CFIs or other text
  positions.

A page the reader actually reaches and that is actually drawn is written at once to the
durable local outbox with its `observed_at` (captured when it was drawn), then sent with
the existing debounce, retry, UUID and compare-and-set rules. The views report what they
show after every turn, jump or layout; a gate (`PageRestoration`) keeps the page being
read as the anchor while it stays on screen. Opening, restoring, rotating, zooming,
switching between one and two pages, choosing a format, changing direction or fit, and
acknowledgements write nothing.

A comic page that fails to decode or verify is never saved. The pager keeps its own
navigation target, so the reader can turn past a broken page; the saved place moves only
when a page that does display is reached. If the page being restored is broken, the
reader stops waiting for it, says so, and keeps the saved place.

A saved place this file can't show (a PDF page past the end, a fraction, another file's
href, a CBZ page whose href or type isn't item N) is never replaced with page one. The
reader explains (*Your saved place isn't in this file*) and offers **Start at page 1** or
**Go to the last page**; looking is not reading, and the place stays until a page is
turned.

## Files, downloads and offline

Online reading uses the evictable reading cache (`Caches/epub/<account>/<asset>`, the same
directory and `book.epub` name as before; PDFs and comics are `book.pdf` and `book.cbz`).
A comic's copy is complete only with its checked reading order beside it as
`book.order.json`; offline, a comic opens from the cache only with that order.

Downloads stay per account in Application Support, use the account's background transfer
grants exactly as EPUB and audio do, and are removed with the account. A book's download
holds one format (`format` in the manifest):

- With several formats, **Download** always asks which (*Download which format?*), listing
  the saved place's format first; **Download another format** replaces the one on the
  device. Updates and retries keep the format while the new edition still has it.
- Downloads made before this version have no `format`; it is worked out from the pinned
  file, so an existing EPUB download stays ready and isn't fetched again when the server
  starts listing a PDF of the same book.

A download is ready only when every byte is present and verified:

- PDF: the announced size and a `%PDF-x.y` header in the first KiB.
- CBZ: the reading order is fetched (bearer, inside the configured server, at most 8 MiB,
  cancelled past the bound) and checked, then stored atomically as `<file>.order.json`
  **before** any byte of the archive is planned; once the bytes are complete, the archive's
  own ZIP32 directory and local headers must match it before the file is marked complete.
  A missing order after a restart is reported as *Files missing*, and retrying fetches only
  the order. A `410` for the order means the generation was replaced (*Changed on your
  server*). Partial bytes, storage failures, cancelling and signing out never produce a
  ready download.

## CBZ safety

`ComicArchive` (in ShelfarrCore, so it is tested on Linux too) reads a CBZ in place and
never extracts it. It mirrors the server's checks:

- exactly one end-of-central-directory record ending the file, the directory ending where
  that record begins, one disk, no ZIP64 locator, at most 10,000 entries and a 2 MiB
  directory; trailing data or an unadjusted prefix is refused;
- stored or deflate entries only; no encryption, strong encryption or masked headers; no
  ZIP64, Info-ZIP Unicode path or AES extra fields; no symbolic links or special files;
- names are UTF-8 when flagged, otherwise ASCII, with no absolute, drive, backslash,
  control, empty, `.` or `..` parts, and no duplicates, including Unicode-equivalent
  spellings;
- every local header repeats its directory entry's flags, method, name and (without a data
  descriptor) CRC and sizes; a data descriptor, with or without its signature, must repeat
  them too; entries don't overlap;
- pages are `.jpg`, `.jpeg`, `.png` and `.webp` entries outside hidden parts (any path
  component starting with `.`, or exactly `__MACOSX`); structural checks apply to every
  entry. Each page is 1 byte to 32 MiB, at most 32 MiB + 64 KiB compressed, and at most
  2 GiB in total.

The reading order must describe exactly these pages (positions 1…N, canonical upper-case
escapes, matching media types, sizes, methods, offsets and lower-case CRCs). A page is
inflated by a small pure-Swift raw-DEFLATE decoder only up to its declared size; it must
use all of its compressed bytes and match its CRC-32. Its image header must be the
declared type, at most 30,000 px a side and 40 megapixels, before ImageIO sees it, and
ImageIO's own reported size is checked again before decoding. No new dependency, zlib
bridge or Apple-only API is used for this, so the same code runs in the Linux tests.

## Tests

- **Core (SwiftPM, runs on Linux and macOS)**: `InflateTests` (zlib dynamic and fixed
  vectors, stored blocks, size bounds, trailing data, invalid distances and codes),
  `ImageProbeTests`, `ReadingOrderTests`, `ComicArchiveTests` (valid archives with data
  descriptors, and malicious ones: traversal, encryption, ZIP64, links, duplicate and
  Unicode-equivalent names, disagreeing local headers and descriptors, overlaps, trailing
  data, prefixes, two directory records, oversized and mislabelled pages, compressed-size
  cap, hidden metadata), `FormatModelTests`, `PageLocatorTests`, `PageRestorationTests`,
  `PageSpreadsTests`, `FormatDecisionTests`, `ReaderFormatsAPITests`, `FormatDownloadsTests`
  (a pre-format EPUB download kept without refetching, explicit PDF downloads, CBZ order
  storage, restart, loss and recovery, mismatched, replaced, oversized and foreign orders,
  edition updates) and `FormatCacheTests`.
- **Fixture** (`apps/ios/RuntimeSmoke/test_formats_fixture.py`, run first by
  `ios-runtime-smoke.sh`): over real HTTP, old clients see byte-identical responses; new
  clients get the format books, invalid declarations are refused, cursors bind formats,
  the generated PDF and CBZ are well formed, reading orders match the archive, page places
  are validated as the server does, Continue hides places a client can't open, and
  keep-alive connections survive refusals.
- **Simulator UI tests** (`FormatsSmokeTests`, iPhone and iPad, via
  `apps/scripts/ios-runtime-smoke.sh --device all`): rendered pages checked in the screen's
  pixels (each fixture page has its own colour), swipes, edge taps and go-to-page, the
  PDF's external link not followed, rotation and reopening writing nothing, the exact saved
  page restored, an impossible saved page kept until a real turn, a comic downloaded,
  zoomed, turned right to left and (on iPad) shown as a spread, then reopened and turned
  offline with its original `observed_at` sent on reconnecting, the format choice, the
  download format choice, and the offline alternative format.

## Limits

- The app, the PDF and comic readers and the UI tests compile only with Xcode and the iOS
  SDK. They were written against PDFKit, UIKit and ImageIO as documented, and checked
  here only by a syntax parse; their build, rendering and behaviour are verified only once
  the simulator smoke runs on Xcode (16.4 and 26) for iPhone and iPad. Physical devices,
  VoiceOver, hardware keyboards and very large real-world files remain in the acceptance
  flow.
- PDFKit doesn't report a page that fails to render, so a PDF page counts as shown once
  PDFKit displays it.
- Spreads pair pages by position (cover alone, then 2–3, 4–5, …); a single image that is
  already a double-page spread is paired like any other page.
- One format of a book is downloaded at a time; downloading another replaces it.
- Edition replacement follows the existing download engine: updating replaces the old
  files rather than keeping both until the new ones are complete.
