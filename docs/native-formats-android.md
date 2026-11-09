# Android: PDF and CBZ reading

How the native Android app reads PDFs and comic archives (CBZ) alongside EPUB. The
wire contract is shared with the web and iOS readers; this page covers what the
Android client does with it. See [native-progress-android.md](native-progress-android.md)
for saving and reconciling places, and [native-offline-android.md](native-offline-android.md)
for downloads.

## What the app asks for

- Library listings, details, Continue and status changes send
  `X-Shelfarr-Reader-Formats: epub,pdf,cbz`. A server that predates the header
  ignores it and keeps offering only EPUB files for books, so nothing changes against
  older servers. Other calls (sign-in, progress, files) don't send it.
- Optional fields are read when present and ignored when absent: `content_kind` on a
  publication (`graphic` for comics), `page_count` and `reading_order_url` on a CBZ
  asset, and `reader_formats` in `server.json`.
- `book_type` stays `ebook` or `audiobook`. A comic is an `ebook` with
  `content_kind: "graphic"`, so it opens in the reader, never the audio player.

A book's readable files are one per format, the first of each in the server's order.
An EPUB-only book therefore resolves to exactly the same file as before. A PDF over
500 MiB, a CBZ over 2 GiB, or a CBZ without a reading order isn't offered.

## Which format opens

1. A saved place keeps its own format: a place in the PDF opens the PDF.
2. Otherwise a ready download's format.
3. Otherwise the only format there is.
4. With several formats and nothing to go on, the reader asks. Nothing is saved until
   the reader turns a page, so the next open asks again until there is a place.

An EPUB never reaches the PDF or comic reader, and a PDF or CBZ never reaches Readium's
EPUB parser or navigator. A place is only ever applied to the file it was saved in.

Downloads follow the same rule. **Download** keeps the format of the saved place;
with several formats and no saved place it asks which (*Download which format?*). The
download records its format (`format` in the manifest) and keeps it across edition
updates while the new edition still has that format. Downloads made before this
version have no `format`; they are worked out from the pinned file, so an existing
EPUB download stays valid and isn't fetched again when the server starts listing a
PDF of the same book.

## The readers

Both are drawn natively in Compose inside `ReaderActivity`, which hosts Readium only
for EPUB.

- **PDF** uses the platform's `android.graphics.pdf.PdfRenderer` (API 21+, the app's
  minimum is 26). Verified against the installed SDK 37 stubs: `PdfRenderer(ParcelFileDescriptor)`
  throws `IOException` for a damaged file and `SecurityException` for a
  password-protected one; only one page may be open at a time and the class is not
  thread-safe before Android 15, so every render is serialized on one worker; a page's
  size is in points; `Page.render(bitmap, null, null, RENDER_MODE_FOR_DISPLAY)` fits
  the page into an `ARGB_8888` bitmap. It runs no PDF JavaScript, forms or links.
  No Readium PDF adapter is linked.
- **CBZ** pages are inflated from the archive one at a time and decoded with
  `BitmapFactory` at the smallest sample size that still fills the screen.

Reading is quiet and full-page by default. A tap in the middle shows or hides the
controls; taps in the outer quarters, swipes, Page Up/Page Down, Space (Shift+Space
back) and the left and right arrows turn pages (keys a focused control uses, such as
arrows moving between the controls, stay with that control). Pinch or double-tap
zooms up to 5×; while zoomed a drag pans and never turns, and a sharper copy is drawn
for the current page. The controls show the title and format, previous/next buttons, a
page slider and **Page N of M**, which opens **Go to page**. When hidden, a small
`N / M` folio stays. EPUB text settings are not shown for fixed pages. TalkBack reads
each page as *Page N of M*, offers *Next page* and *Previous page* actions and a
labelled action to show the controls; all controls are labelled, and the bars wrap
under large text (checked at 2× on a 320 dp phone).

Rendering happens off the main thread. Each page bitmap is at most 8 million pixels
(about 32 MiB), recently drawn pages are cached up to a sixth of the heap (16–96 MiB),
and a page that fails is shown with its reason instead of crashing.

## Places

- **PDF**: `{"href":"document.pdf","type":"application/pdf","locations":{"position":N,
  "totalProgression":(N-1)/count,"fragments":["page=N"]}}`, N one-based.
- **CBZ**: `href` and `type` of item N in the generation's reading order (the exact
  escaped href), `position` N, `totalProgression` (N-1)/count.

A page the reader actually sees is written at once to the durable local outbox with
its `observed_at`, then sent with the existing debounce, retry, UUID and compare-and-set
rules. "Seen" means the pager has settled on it *and* its image is drawn; the time is
read at that moment and kept through any wait for the server. Opening, restoring,
rotating, zooming, re-rendering, choosing a format and acknowledgements write nothing,
and a neighbouring page drawn ahead of time is not reading until the reader settles on it.

The page on screen and the reading place are kept apart (`PageProgress`). A page that
can't be drawn (a damaged comic image, a PDF page the renderer refuses, running out of
memory) says so, with *Your reading place hasn't moved* and **Try again**; it never
changes the local place, the outbox, the server or the activity time. Swipes, edge taps,
the controls and hardware keys turn from the page on screen, so the reader can skip past
it or go back, and a page that draws on a retry is saved at the time it was drawn.

A saved place this file can't show (a PDF page past the end, a non-integer position,
another file's href, a CBZ page whose href doesn't match item N) is never replaced with
page one. The reader is told (*Your saved place isn't in this file*) and chooses
**Start at page 1** or the last page; looking is not reading, and the saved place stays
until a page is turned.

## Files, downloads and offline

Online reading uses the evictable reading cache (`cache/epub/<account>/<asset>`,
the same directory and EPUB file names as before; PDFs and comics are `book.pdf` and
`book.cbz` beside their own metadata). That is not an offline download.

A download is ready only when every byte is present and verified:

- PDF: the announced size and a `%PDF-x.y` header in the first KiB.
- CBZ: the announced size, the reading order fetched from `reading_order_url`, and the
  archive's own ZIP32 directory matching it. The order is saved beside the archive as
  `<file>.order.json`, written atomically before the archive is marked complete. A CBZ
  whose order is missing on the next start is reported as *Files missing*.

Bytes past the announced size are refused as they arrive. A `410` for the reading order
means the generation was replaced (*Changed on your server*). Downloads stay per
account, use the account's own HTTP client, and are removed with the account.

The reading-order URL must resolve inside the configured server (same scheme, host,
port and subpath); redirects that leave it are refused, and the body is read only up
to 8 MiB.

## CBZ safety

Only non-split, non-encrypted ZIP32 archives with JPEG, PNG or WebP pages are read.
There is no CBR/RAR support and no DRM. Opening an archive reads at most a 64 KiB tail,
an 8 MiB directory and 10,000 entries, and refuses:

- ZIP64, split archives, a prefix whose offsets weren't moved, or trailing data;
- encrypted entries, symbolic links, compression other than stored or deflate;
- absolute, `..`/`.` or backslash names, control characters, invalid UTF-8 and
  duplicate names;
- a reading order whose positions aren't 1…N, whose hrefs aren't the server's
  canonical escapes, whose media types don't match the name, or whose sizes, offsets,
  methods or CRCs differ from the archive's directory and local headers;
- pages over 32 MiB or more than 2 GiB of pages in total.

A page is inflated only up to its declared size, must use all of its compressed bytes,
and must match its CRC-32. Its image header must be the declared type, no wider or
taller than 30,000 pixels. Nothing is ever extracted to disk.

## Tests

- JVM: `ComicArchiveTest` (valid and malicious archives, escapes, CRC, inflation
  bounds), `ReadingOrderClientTest` (subpath, origin, redirect, size, 404/410),
  `ReadingFormatsTest` (old and new JSON, format choice, download format, resume across
  formats), `ReaderFormatsHeaderTest`, `PageLocatorsTest`, and `FixedLayoutFilesTest`
  (real HTTP and files: a pre-PDF EPUB download kept without refetching when a PDF
  appears, explicit PDF downloads, wrong or oversized PDFs, CBZ order caching and
  restart, 410, mismatched orders, foreign order URLs, and the reading cache online and
  offline).
- Robolectric: `PagedReaderTest` (opening, swipes, edge taps, commands, middle tap,
  zoom and pan, rebuilding on rotation, labelled controls, real CBZ decoding through
  `BitmapFactory`), `PageProgressTest`, `PageReadingTest` (the reader wired to
  `PageProgress` and a real `ProgressSync` over a durable store and contract server: a
  failed page, then Next by control, key and edge tap; prefetching and slow pages;
  trying again; silent opening, rebuilding, resizing and zooming; a real comic with a
  damaged page; screenshots `16-*`), `GoToPageDialogTest`, and `FixedLayoutScreenshotTest`, which renders
  `15-*` into `app/build/screenshots`: quiet and controls on a phone, a night comic page
  decoded from a real archive, 2× text on a phone and a 320 dp phone, the format choice,
  the invalid-place choice, and the download format choice.
- Instrumentation (`FixedLayoutReaderTest`, run by `android-reader-smoke.sh` on CI's
  emulator): a PDF drawn with the platform's `PdfDocument` renders through
  `PdfRenderer`, a Page Down key turns it, the write carries the PDF locator and a
  plausible `observed_at`, a recreated activity and a reopen show the same page and send
  nothing; an impossible saved place is kept through opening and choosing and replaced
  only by a page turn; a comic page with a bad checksum is never saved and Page Down
  goes past it; a CBZ and a PDF download, then open offline from the download,
  with the comic's page kept locally. Each check reads the pixels on screen and saves a
  screenshot.

## Limits

- This machine has no KVM, so the instrumentation is compiled locally but runs only on
  CI's emulator. Physical-device checks (TalkBack, hardware keyboards, very large
  real-world PDFs and comics) remain in the acceptance flow.
- Robolectric has no `PdfRenderer`, so PDF rendering is verified only on the emulator;
  JVM render tests use drawn pages for the PDF reader and real decoding for comics.
- Right-to-left (manga) page order and two-page spreads are not implemented.
- Edition replacement follows the existing download engine: updating a download replaces
  the old files rather than keeping both.
- Offline, if the saved place is in a format that isn't on the device but another
  format is downloaded, the reader reports it can't reach the server rather than
  offering the downloaded format.
