# Third-party stores (Beta)

Shelfarr can surface paid DRM-free editions from supported third-party stores alongside its existing acquisition search. Shelfarr does not process payments, collect store credentials, or treat a store listing as a downloadable release.

This integration is in beta, is disabled by default, and currently supports ebook offers from eBooks.com. Provider responses and commercial terms can change independently of Shelfarr, so confirm that the integration is permitted for your deployment before relying on it.

## Enable the integration

### New installations

No extra container or volume is required. Install Shelfarr normally, create the first administrator, and then:

1. Open **Admin > Settings > Search > eBooks.com Store (Beta)**.
2. Enable the provider.
3. Enter the ISO 3166-1 two-letter country code for the person buying the book, such as `US`, `GB`, or `PT`.
4. Choose how many matching offers to retain per request (1-10; the default is 5).
5. Save, then select **Test eBooks.com Catalog**.

### Existing installations

Update Shelfarr normally and allow its automatic database migrations to finish. The upgrade adds the `store_offers` table and default-disabled settings; it does not alter existing provider credentials or encryption keys. Then follow the same settings steps above. There is no need to recreate existing settings.

If you use Docker Compose:

```bash
docker compose pull
docker compose up -d
```

Back up the Shelfarr data volume before any application upgrade, as usual.

## Use store offers

1. Search Shelfarr's metadata catalog and request an **ebook** normally.
2. When the request search runs, Shelfarr checks all configured acquisition sources and enabled store providers.
3. Open the request. Eligible eBooks.com results appear in a separate **Buy DRM-free** section with their format, localized price, and DRM or watermark disclosure. The quote is validated against the configured buyer market before it is shown.
4. Follow the product link and complete checkout on eBooks.com. Shelfarr never sees payment or account details.
5. Download the purchased file from the seller and upload it to the Shelfarr request. If user uploads are disabled, an administrator must perform the import.

Store offers are deliberately excluded from auto-selection. If downloadable results and store offers both exist, an administrator sees both sections. A regular requester sees the store-offer section and the existing **Search Results Available** banner while downloadable release selection remains with an administrator. Choosing or downloading an acquisition result does not purchase the store offer.

Shelfarr does not query the store while a user types in the metadata search box and does not crawl the complete store catalog. A lookup runs only as part of a request search or an explicit retry, and the configured offer limit caps the retained results. Identical catalog responses are cached for 24 hours. Outbound requests use a short shared cache lease so multiple Shelfarr worker processes do not stampede the seller; an eBooks.com `429` response activates a shared, bounded cooldown and honors `Retry-After` before another request is attempted. Responses are read through a 1 MB wire limit, deeply nested or oversized result sets are rejected, and only bounded fields from the documented API schema enter the offer pipeline.

Each lookup necessarily sends the requested title and, when available, its author or ISBN plus the configured buyer country to eBooks.com from the Shelfarr server's public IP address. Shelfarr does not send the requester's Shelfarr username, email address, store account, or payment details. Following an offer is a separate browser navigation governed by the seller's privacy policy.

Search-job operational logs use request IDs, provider names, counts, and error classes rather than book titles, authors, queries, upstream bodies, or URLs. Database debug output is suppressed for the job as well, so enabling debug logging does not copy catalog interests or cached offer payloads into SQL logs.

## Phase-one flow

```text
Request search
  -> downloadable acquisition results (existing SearchResult pipeline)
  -> DRM-free store catalog results (StoreOffer pipeline)
       -> seller product page and checkout
       -> buyer downloads the purchased EPUB/PDF
       -> buyer or admin uploads it to the existing request import flow
```

Store offers are deliberately separate from `SearchResult`. They are never eligible for auto-selection, never create a `Download`, and never reach `DownloadJob`. Checkout, account credentials, tax calculation, and card data stay with the seller.

When a search finds only store offers, the request is flagged as awaiting a purchase or import instead of entering the failed-search retry cycle. If regular-user uploads are disabled, the request page tells the buyer to ask an administrator to import the purchased file.

For existing installations, the upgrade maps the legacy store-only warning
state to the additive `awaiting_purchase` request status and converts its
matching diagnostic from a warning to an informational store-offer event.
Existing numeric request-status values remain unchanged; integrations that
exhaustively handle API status strings should add `awaiting_purchase`. Rolling
the migration back restores a state understood by the previous application.

## First provider: eBooks.com

The first beta provider uses the official eBooks.com Book API v2:

- Documentation: <https://api.ebooks.com/docs/index.html>
- OpenAPI definition: <https://api.ebooks.com/docs/v2/swagger.json>
- DRM-free search: `GET /v2/{countryCode}/book/search?title=...&author=...&drmFree=true`
- Edition lookup: `GET /v2/{countryCode}/book/isbn/{isbn}`

Shelfarr tries an ISBN lookup first when metadata includes an ISBN. An exact, eligible ISBN result avoids a second catalog call; title-and-author search is used only as the fallback. Only results that the API explicitly marks `drmFreeAvailable: true` and supplies as EPUB or PDF are retained. Prices, currencies, availability, and product URLs are localized by the configured two-letter buyer country code, and a conflicting market in the quoted price is rejected. `drmFreeType` is shown because DRM-free files may still contain a social watermark.

The public catalog API currently works without an API key. It is read-only: it does not purchase books, expose order status, provide a purchase webhook, or offer a general buyer-library download API.

### Permission and rollout

The connector is disabled by default and labeled beta. eBooks.com presents API/deep-link access through its affiliate program, while its general terms restrict deep links without permission. A production deployment should obtain affiliate or partner approval before enabling the connector broadly:

- Affiliate information: <https://www.ebooks.com/en-us/information/affiliates/>
- Registration: <https://www.ebooks.com/en-us/information/affiliate-register-interest/>

Do not invent referral parameters. Add them only from partner-issued integration instructions.

## Settings reference

**Admin > Settings > Search > eBooks.com Store (Beta):**

- `ebooks_com_enabled`: opt in to catalog offers; defaults to `false`.
- `ebooks_com_country_code`: required ISO 3166-1 two-letter buyer country used for territorial availability and localized prices.
- `ebooks_com_search_limit`: number of matching offers retained per request, clamped to 1-10.

These settings contain no credentials or secrets.

Each saved offer records the buyer market used for its territorial availability and price. Disabling the provider or changing its country code purges existing eBooks.com offers, and display/API queries independently require the provider to remain enabled with the same market. This prevents old localized purchase links from resurfacing after reconfiguration.

Catalog quotes expire after 24 hours. An offer-only request whose last quote has expired is returned to the normal pending queue so Shelfarr can refresh availability and price instead of continuing to advertise a stale purchase option.

## Upgrade and encryption safety

The feature adds a new `store_offers` table and new non-secret setting definitions. It does not modify or backfill existing acquisition providers, download clients, user OTP data, encrypted columns, or Active Record encryption configuration.

Future providers that require API keys or OAuth tokens must not place them in `SettingsService`: `settings.value` is not encrypted. Add a dedicated model with explicit encrypted attributes while keeping the existing Active Record encryption key tuple unchanged.

An application downgrade is not the same as disabling this provider. A
pre-store Shelfarr image does not recognize the additive `awaiting_purchase`
request status. Before downgrading, stop Shelfarr so no search or import job is
running and restore the complete pre-upgrade Shelfarr storage backup together
with the matching Compose file and image. Restore all SQLite databases and the
same Active Record encryption tuple as one unit (the `.encryption_keys` file in
the auto-generated setup, or the exact same externally managed values). Rolling
back only the primary database can leave incompatible jobs in the Solid Queue
database, while restoring encrypted rows without their original key tuple makes
existing credentials unreadable. A manual partial downgrade is not supported.

## Future purchase import

eBooks.com documents a buyer bookshelf OPDS feed, but its current authorization flow is intended for OPDS readers and does not advertise dynamic client registration for a self-hosted Shelfarr callback. Automatic post-purchase import therefore needs a partner-approved OAuth client and callback design. Until then, the supported completion path is the existing request-linked upload flow (or a future watched-folder importer).

Purchased files remain subject to the seller and publisher's personal-use license. DRM-free means the file can be used in compatible software; it does not grant redistribution rights.

## Beta limitations

- Only ebook offers are supported; audiobook stores are not yet connected.
- Shelfarr cannot complete checkout, confirm a purchase, or automatically fetch an eBooks.com bookshelf item.
- Catalog availability and prices are territorial and may change after the offer was recorded.
- A DRM-free file can still contain a visible or social watermark; Shelfarr shows the store's reported DRM type when available.
- Search is request-driven rather than a continuous store-catalog crawl.
- The seller's availability, API behavior, rate limits, affiliate requirements, and terms remain outside Shelfarr's control.

## Disable or change markets

Turn off `ebooks_com_enabled` to stop future lookups and hide existing eBooks.com offers. Changing the buyer country removes offers quoted for the previous market so outdated territorial availability or pricing cannot reappear.

No purchase or personal library data is deleted because Shelfarr does not store either one.
