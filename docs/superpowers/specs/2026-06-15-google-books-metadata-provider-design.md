# Google Books Metadata Provider — Design

**Date:** 2026-06-15
**Status:** Approved (design)

## Goal

Add Google Books as a third book metadata source alongside the existing Open Library
and Hardcover providers. Google Books is queried through its public REST API
(`https://www.googleapis.com/books/v1`).

## Decisions

- **API key: required.** Google Books is only enabled once an API key is configured
  (mirrors how Hardcover is gated on its token). `GoogleBooksClient.configured?` returns
  true only when `google_books_api_key` is present, and the admin settings UI provides a
  direct "Get API Key" link to
  `https://console.cloud.google.com/apis/library/books.googleapis.com`.
  (Revised from the original "optional key" decision at the user's request.)
- **Auto fallback order:** Hardcover → Open Library → Google Books. Google Books is the
  last resort, queried only when Open Library returns no results *and* a key is
  configured.
- **`metadata_source` setting stays a free-text field.** Only its description is updated
  to mention the new `googlebooks` value.

## Approach

Add a dedicated `GoogleBooksClient` service modelled on `OpenLibraryClient` /
`HardcoverClient`, wired into `MetadataService`. Rejected alternative: a generic
"provider" abstraction unifying all three sources — out of scope, risks regressions on
the existing Hardcover/Open Library paths.

## Components

### 1. `GoogleBooksClient` (`app/services/google_books_client.rb`)

Class-method service following the `OpenLibraryClient` pattern: Faraday connection,
`Data`-defined result structures, and error classes
`Error` / `ConnectionError` / `NotFoundError` / `RateLimitError`.

- Base URL: `https://www.googleapis.com/books/v1`
- `search(query, limit:)` → `GET /volumes?q=...&maxResults=N` (appends `&key=` when
  configured). Returns an array of `SearchResult`. `limit` defaults to
  `google_books_search_limit`.
- `volume(id)` → `GET /volumes/{id}` for book details.
- `configured?` → `true` (key optional; source always available).
- `test_connection` → minimal search (`maxResults=1`); returns boolean.
- `cover_url` → derived from `volumeInfo.imageLinks` (force HTTPS, strip `&edge=curl`).

**Field mapping** (from `volumeInfo` / `accessInfo`):

| Shelfarr field | Google Books source |
|---|---|
| title | `volumeInfo.title` |
| author | `volumeInfo.authors[0]` |
| description | `volumeInfo.description` |
| year | year parsed from `volumeInfo.publishedDate` |
| cover_url | `volumeInfo.imageLinks.thumbnail` |
| has_ebook | `accessInfo.epub.isAvailable` |
| has_audiobook | `nil` (not provided) |
| series_name / series_position | `nil` (not provided) |

### 2. `MetadataService` (`app/services/metadata_service.rb`)

- Add `"googlebooks"` case to `search` and `book_details`.
- `search_with_fallback`: Hardcover (if configured) → Open Library → Google Books.
  Google Books runs only when Open Library returns no results.
- New private methods: `search_googlebooks`, `fetch_googlebooks_details`,
  `normalize_googlebooks_result`, `normalize_googlebooks_details` — each producing a
  unified `SearchResult` with `source: "googlebooks"`.
- `test_connections`: add `results[:googlebooks]`.
- `available?`: Google Books always available.

### 3. `SettingsService` (`app/services/settings_service.rb`)

- New category: `"google_books" => "Google Books"`.
- New settings:
  - `google_books_api_key` (string, default `""`) — optional; raises quota.
  - `google_books_search_limit` (integer, default `20`).
- Update `metadata_source` description to mention `googlebooks`.
- Add `"google_books"` to the **Integrations** tab category list in the form.

### 4. `Book` model + migration

- Migration: add `google_books_id` (string) column + index on `books`.
- `find_by_work_id` / `find_or_initialize_by_work_id`: add `when "googlebooks"` branch
  targeting the `google_books_id` column.
- `unified_work_id`: add a `google_books_id` branch.
- `parse_work_id`: unchanged (already generic, splits on `:`).

### 5. Admin (test connection)

- `Admin::SettingsController#test_google_books` — modelled on `test_hardcover`, using
  `SystemHealth.for_service("google_books")`.
- Route: `post test_google_books` under admin settings.
- View `_form.html.erb`: "Test Google Books Connection" button block for the
  `google_books` category. The `google_books_api_key` field renders as a password field
  automatically (key name contains `api_key`).

### 6. Related integrations

- `BookMetadataBackfillService#metadata_lookup_errors`: add `GoogleBooksClient::Error`.
- Verify `request_creation_service`, `upload_processing_job`,
  `duplicate_detection_service`, and `integrations/command_processor` work unchanged —
  they route through `find_by_work_id` / `parse_work_id`, which are already generic.

## Data flow

1. User searches → `MetadataService.search` dispatches by `metadata_source`
   (`auto` → fallback chain ending in Google Books).
2. `GoogleBooksClient.search` returns `SearchResult`s normalized to the unified shape.
3. Selecting a result yields a `work_id` of `googlebooks:<volumeId>`.
4. `Book.find_or_initialize_by_work_id` stores the id in `google_books_id`.
5. `BookMetadataBackfillService` calls `MetadataService.book_details("googlebooks:<id>")`
   → `GoogleBooksClient.volume` to backfill missing fields.

## Error handling

`GoogleBooksClient` raises typed errors. `MetadataService.search_googlebooks` rescues
`GoogleBooksClient::Error` and returns `[]` (consistent with the other sources).
HTTP 429 → `RateLimitError`; 404 → `NotFoundError`; connection/timeout/SSL →
`ConnectionError`.

## Testing

- `test/services/google_books_client_test.rb` with VCR cassettes under
  `test/cassettes/google_books/` (search, search-no-results, volume details,
  volume-not-found).
- `metadata_service_test.rb`: add `googlebooks` source cases and fallback-chain coverage.
- `Book` model tests: `find_by_work_id` / `find_or_initialize_by_work_id` /
  `unified_work_id` for the `googlebooks` source.

## Out of scope

- Generic provider abstraction / refactor of existing sources.
- Edition-level lookups for Google Books (no equivalent of Open Library editions).
- Audiobook availability detection (not exposed by the API).
