# Send ebooks to a stock Kobo (preview)

To connect a Kobo Store account and inspect its private catalogue, see
[Kobo accounts](kobo-accounts.md). That flow does not configure a reader or
enable Store coexistence for the reader integration below.

Shelfarr can serve selected library ebooks through the stock Kobo's Wi-Fi sync.
No KOReader, jailbreak, Kobo Cloud subscription, or new acquisition is needed.
Choose books separately for each physical reader. The reader fetches them when
you tap **Sync**; this is not an immediate push or a remote wake-up.

This is a protocol preview, not a claim that every Kobo generation has been
tested. The initial compatibility matrix is below. Kobo's private protocol and
firmware behavior can change. The integration follows the approach documented
by [Komga](https://komga.org/docs/guides/kobo/) and
[Calibre-Web](https://github.com/janeczku/calibre-web/wiki/Kobo-Integration).

## Before connecting

- Use a Kobo with stock software and a working Wi-Fi sync. Older devices that
  cannot reach an HTTP(S) endpoint or have no `[OneStoreServices]` configuration
  are not covered by this preview. Do not install another reader application.
- Use a Shelfarr address the device can reach. Include any deployment subpath.
  Browser-only sign-in gates (including Cloudflare Access) block the reader.
  Keep normal Shelfarr browser authentication enabled: the device URL provides
  its own narrowly scoped authentication.
- Prefer HTTPS with a certificate and TLS configuration your device trusts.
  Older firmware may require network/TLS troubleshooting. HTTP exposes the
  connection secret and book bytes; use it only on a trusted local network.
- **This preview replaces Kobo Store syncing.** It does not proxy Store
  authentication, purchases, OverDrive, or subscription content. Downloaded
  Store books are left alone. Save the original endpoint and restore it when
  you want normal Store syncing again. Do not sign out, reset the reader, or
  delete its database as an integration troubleshooting step.

## Connect each reader

1. In Shelfarr, open **My Profile → Kobo readers**. Enter a recognisable name
   and the Shelfarr address reachable from that Kobo.
2. Select **Create connection**. The private connection address appears once.
   It grants access to books selected for this reader; treat it like a password.
3. Connect the Kobo to a computer by USB. Back up
   `.kobo/Kobo/Kobo eReader.conf`, including the original `api_endpoint` value.
   Hidden files may need to be shown in your file manager.
4. In that file's existing `[OneStoreServices]` section, replace only the
   `api_endpoint` line with the exact line displayed by Shelfarr:

   ```ini
   [OneStoreServices]
   api_endpoint=https://shelfarr.example/kobo/<private-device-token>
   ```

5. Save, safely eject, and restart the reader. Open an acquired ebook in
   Shelfarr's **Library**, choose **Send to [reader]**, then tap **Sync** on Kobo.
6. Repeat with a separate connection for each reader. Sending to one reader
   does not select the book for another.

The connection URL cannot be recovered from Shelfarr. Use **Regenerate
connection address** if it is lost or exposed, then update the configuration.
The old address stops working and selected books remain selected. **Revoke
connection** removes device access and server-side selections. Neither action
deletes books already downloaded on the Kobo. Restore the original endpoint
on the reader to disconnect it fully.

## Supported files and status

- DRM-free EPUB and existing `.kepub`/`.kepub.epub` files, up to 250 MiB.
  Shelfarr does not convert EPUB to KEPUB. EPUBs declaring encryption (including
  font obfuscation) are rejected in this preview.
- Single-file library items and book-specific folders containing exactly one
  EPUB (up to five nested levels and 1,000 entries). Shared library-root folders
  and folders with multiple EPUBs must be disambiguated before sending.
- Copy and reference imports use the same root authorization as web downloads.
  Original library files are kept. PDFs, comics, audiobooks, remote-only owned
  library listings, and arbitrary filesystem paths are not sent.
- Metadata and embedded JPEG/PNG covers are served locally. Covers are bounded
  to 4 MiB and delivered at their embedded resolution. Missing covers do not
  prevent the ebook download.
- **Queued** means the book is selected for the reader. **Download requested**
  records a GET, not proof of a completed transfer or that the book was opened.
  Interrupted downloads support single HTTP byte ranges. Retry by syncing again.
- Replacing or editing a source file invalidates its queued download. Use
  **Send again** to publish the current file. A removed source cannot be fetched;
  no removal entitlement is sent to delete an existing reader copy.
- Reading state received from a Kobo is retained only for that reader. It is
  not interpreted as a web/mobile reading location or synced to other devices.
  This preview does not offer read-along or universal progress synchronization.

## Deployment and secret handling

The stock protocol puts the device secret in `/kobo/<token>/…`, rather than a
standard bearer header. Shelfarr stores only its SHA-256 digest, shows the raw
value once in a `no-store` setup response, and filters the token from Rails'
request-path and parameter logs. Users who are soft-deleted lose device access.

Configure your reverse proxy, CDN, APM, error tracker, and access logs to redact
the token or exclude this route from URL collection. Shelfarr cannot sanitize
logs produced before a request reaches Rails. Do not paste an actual connection
URL into an issue, screenshot, analytics event, or support transcript. Book
download URLs include the same secret. All generated device links use the base
address saved at setup, not the Kobo's sometimes malformed Host header.

## Physical-device acceptance matrix

Automated tests cover legacy User-Agent handling, per-device authorization,
token rotation, replay/pagination, file changes, references, range/HEAD responses,
state isolation, embedded covers, and the browser setup/send flows.

Before removing the preview label, record the model and firmware of each test
reader and complete the following on the oldest, middle, and newest generation:

| Check | Oldest reader | Middle reader | Newest reader |
|---|---|---|---|
| Model and stock firmware version | Pending | Pending | Pending |
| Initialization and authenticated sync over actual network/TLS | Pending | Pending | Pending |
| EPUB 2 and EPUB 3 download, open, chapter navigation, cover | Pending | Pending | Pending |
| Existing KEPUB download and open | Pending | Pending | Pending |
| Second sync creates no duplicate or reading-position reset | Pending | Pending | Pending |
| Interrupted transfer resumes; file replacement + Send again | Pending | Pending | Pending |
| Sending to another reader leaves this reader unchanged | Pending | Pending | Pending |
| Rotate/revoke blocks old URL; restore saved Store endpoint | Pending | Pending | Pending |

No physical-device results have been recorded yet. In a failure report, include
model, firmware, whether HTTP/HTTPS and a subpath were used, the failing step,
and redacted Rails logs. Never include the token or Kobo account keys.
