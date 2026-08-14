# Custom Acquisition Providers

Custom acquisition providers let a local HTTP service participate in Shelfarr search and acquisition without adding a built-in integration.

This is a trusted home-lab integration point. Shelfarr calls the provider over HTTP, stores normalized results, and later asks the same provider to resolve the selected result into a concrete artifact Shelfarr can download or dispatch.

## Provider Setup

Add providers in **Admin > Acquisition Providers**.

Fields:

- `Name` - display name shown in search results.
- `Base URL` - provider origin, such as `http://provider:4567`.
- `Bearer Token` - optional token sent as `Authorization: Bearer <token>`.
- `Media Types` - whether the provider should be searched for ebooks, audiobooks, or both.
- `Timeout Seconds` - request timeout for provider calls.
- `Allow private network` - permit the provider and its download links to use private network addresses.

The **Test** action calls `GET /health` on the provider. A `2xx` response means the provider is reachable.

## Network Restrictions

Shelfarr validates every URL before contacting a provider or downloading an artifact it returned:

- Link-local and metadata addresses (for example `169.254.169.254`) are always refused.
- Private and loopback addresses (`localhost`, `10.x`, `172.16-31.x`, `192.168.x`, `127.x`) are refused unless the provider has **Allow private network** enabled. Enable it for providers running on your home-lab network.
- The same rules apply to `direct_url`/`nzb_url` artifacts returned by `/acquire`, including any HTTP redirects they go through.
- JSON responses from `/search` and `/acquire` are limited to 10 MB.

## Search

Shelfarr calls:

```http
POST /search
Content-Type: application/json
Authorization: Bearer <token>
```

Request body:

```json
{
  "query": "Dune Frank Herbert",
  "request": {
    "id": 123,
    "language": "en"
  },
  "book": {
    "id": 456,
    "title": "Dune",
    "author": "Frank Herbert",
    "book_type": "ebook",
    "content_kind": "book",
    "year": 1965,
    "release_date": "1965-08-01",
    "language": "en",
    "publisher": "Chilton Books",
    "series": "Dune",
    "series_position": "1",
    "narrator": null,
    "description": "Set on the desert planet Arrakis...",
    "issue_number": null,
    "isbn": "9780441172719",
    "metadata_source": "hardcover",
    "open_library_work_id": "OL893415W",
    "open_library_edition_id": "OL26712345M",
    "google_books_id": "abc123",
    "hardcover_id": "789"
  }
}
```

The book object contains metadata already stored by Shelfarr. `cover_url` is
intentionally omitted so providers do not need another network request just to
consume the matching context.

Response body can be either a bare array or an object with `results`:

```json
{
  "results": [
    {
      "id": "provider-result-1",
      "title": "Dune",
      "author": "Frank Herbert",
      "format": "epub",
      "language": "en",
      "size_bytes": 5242880,
      "download_type": "direct",
      "availability": "available",
      "rank_score": 96,
      "match_evidence": {
        "matched_fields": ["title", "author", "series"],
        "warnings": []
      },
      "info_url": "https://provider.example/books/provider-result-1",
      "published_at": "2026-06-08T12:00:00Z"
    }
  ]
}
```

Required result fields:

- `id` or `provider_result_id` or `guid`
- `title`

Recommended result fields:

- `author`
- `format` or `file_type`
- `language`
- `size_bytes`
- `download_type`: `direct`, `torrent`, or `usenet`
- `availability`: `available`, `unknown`, `temporarily_unavailable`, or provider-specific text
- `rank_score`: integer from `0` to `100`; replaces this result's ordering score among results with the same preferred download type
- `match_evidence`: optional provider-defined JSON explaining the ranking decision
- `info_url`
- `published_at`

Shelfarr stores the full result object as provider metadata so `/acquire` can receive it later.

`rank_score` is advisory ordering for results returned by this provider, not a replacement for Shelfarr's stored
confidence score. Results without it continue to rank by Shelfarr confidence.
It cannot make a low-confidence result auto-selectable, bypass language
or format preferences, override the configured download-type order, or make an
unavailable result downloadable. Invalid and out-of-range values are ignored.
This lets a trusted provider use richer metadata or a model-assisted matcher to
re-rank credible candidates without giving it control over Shelfarr's safety
gates.

## Acquire

Shelfarr calls this after an admin or auto-selection picks a custom provider result:

```http
POST /acquire
Content-Type: application/json
Authorization: Bearer <token>
```

Request body:

```json
{
  "provider_result_id": "provider-result-1",
  "result": {
    "id": 987,
    "title": "Dune - Frank Herbert [EPUB]",
    "source": "custom",
    "provider_result_id": "provider-result-1",
    "provider_payload": {
      "id": "provider-result-1",
      "title": "Dune",
      "download_type": "direct"
    }
  },
  "request": {
    "id": 123,
    "language": "en"
  },
  "book": {
    "id": 456,
    "title": "Dune",
    "author": "Frank Herbert",
    "book_type": "ebook"
  }
}
```

The provider must return one concrete artifact.

Direct download:

```json
{
  "download_type": "direct",
  "direct_url": "https://provider.example/files/dune.epub"
}
```

Torrent:

```json
{
  "download_type": "torrent",
  "magnet_url": "magnet:?xt=urn:btih:..."
}
```

Usenet:

```json
{
  "download_type": "usenet",
  "nzb_url": "https://provider.example/files/dune.nzb"
}
```

Shelfarr then handles the artifact with its normal download flow.

## Direct Artifact Support

Ebook direct downloads support:

- `epub`
- `pdf`
- `mobi`
- `azw3`

Audiobook direct downloads support:

- `zip` archives, extracted into the audiobook destination directory
- single audio files: `m4b`, `mp3`, `m4a`, `aac`, `flac`, `ogg`, `opus`

Direct downloads are capped by Shelfarr's existing direct-download limits: 512 MB for ebooks and 2 GB for audiobooks.

## Local Development

Use `bin/dev` for the normal development process. It runs Rails and the frontend watcher.

Background jobs use Solid Queue. If you run only `bin/rails server`, queued searches and downloads are persisted but may not execute until a worker is running. For a single-process local run that executes jobs in Puma, start Rails with:

```bash
SOLID_QUEUE_IN_PUMA=1 bin/rails server
```

Alternatively, run queued jobs manually from Rails console/runner while testing a provider.
