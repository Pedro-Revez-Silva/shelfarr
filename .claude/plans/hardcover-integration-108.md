# Hardcover Integration Plan (Issue #108)

## Overview
Add Hardcover as primary metadata source with OpenLibrary as fallback, plus auto-matching for uploaded books.

## Work ID Format
Unified format: `source:id`
- `hardcover:12345`
- `openlibrary:OL45804W`

---

## Phase 1: HardcoverClient + MetadataService

### 1.1 New Settings
**File:** `app/services/settings_service.rb`

Add to `DEFINITIONS`:
```ruby
hardcover_api_token: { type: "string", default: "", category: "hardcover", description: "API token from Hardcover account settings" },
metadata_source: { type: "string", default: "auto", category: "hardcover", description: "Primary metadata source: auto, hardcover, or openlibrary" },
hardcover_search_limit: { type: "integer", default: 10, category: "hardcover", description: "Maximum search results from Hardcover" },
```

Add helper:
```ruby
def hardcover_configured?
  configured?(:hardcover_api_token)
end
```

### 1.2 HardcoverClient Service
**New File:** `app/services/hardcover_client.rb`

- GraphQL client for `https://api.hardcover.app/v1/graphql`
- Auth: `authorization` header with token
- Rate limit: 60 requests/minute
- Methods:
  - `search(query, limit:)` → Array of SearchResult
  - `book(book_id)` → BookDetails
  - `test_connection` → Boolean
  - `configured?` → Boolean

Data structures:
```ruby
SearchResult = Data.define(
  :id, :title, :author, :description, :rating, :release_year,
  :isbns, :series_names, :has_audiobook, :has_ebook, :cover_url
)

BookDetails = Data.define(
  :id, :title, :author, :description, :rating, :release_year,
  :isbns, :series_names, :has_audiobook, :has_ebook, :cover_url,
  :pages, :genres
)
```

### 1.3 MetadataService
**New File:** `app/services/metadata_service.rb`

Unified orchestrator:
- `search(query, limit:)` → Array of unified SearchResult
- `book_details(work_id)` → unified SearchResult
- `test_connections` → Hash of results
- `metadata_source` → current source setting
- `available?` → Boolean

Logic:
- If `auto`: try Hardcover first (if configured), fall back to OpenLibrary
- If `hardcover`: use only Hardcover
- If `openlibrary`: use only OpenLibrary

Unified SearchResult:
```ruby
SearchResult = Data.define(
  :source, :source_id, :title, :author, :description, :year,
  :cover_url, :isbns, :has_audiobook, :has_ebook, :series_names, :rating
) do
  def work_id
    "#{source}:#{source_id}"
  end
end
```

### 1.4 Database Migration
**New File:** `db/migrate/YYYYMMDDHHMMSS_add_metadata_source_to_books.rb`

```ruby
add_column :books, :metadata_source, :string, default: "openlibrary"
add_column :books, :hardcover_id, :string
add_index :books, :hardcover_id
```

### 1.5 Update Book Model
**File:** `app/models/book.rb`

```ruby
def unified_work_id
  if hardcover_id.present?
    "hardcover:#{hardcover_id}"
  elsif open_library_work_id.present?
    "openlibrary:#{open_library_work_id}"
  end
end
```

### 1.6 Update Controllers
**File:** `app/controllers/search_controller.rb`
- Replace `OpenLibraryClient.search` with `MetadataService.search`

**File:** `app/controllers/requests_controller.rb`
- Parse `work_id` to determine source
- Use appropriate ID column based on source

### 1.7 Health Check
**File:** `app/jobs/health_check_job.rb`
- Add `check_hardcover` method
- Test connection if configured

**File:** `app/models/system_health.rb`
- Add `"hardcover"` to SERVICES

### 1.8 Settings UI
**File:** `app/views/admin/settings/_form.html.erb`
- Add Hardcover section with API token field
- Add metadata source dropdown
- Add test connection button

**File:** `app/controllers/admin/settings_controller.rb`
- Add `test_hardcover` action

**File:** `config/routes.rb`
- Add `post :test_hardcover` route

### 1.9 Tests
**New File:** `test/services/hardcover_client_test.rb`
**New File:** `test/services/metadata_service_test.rb`

---

## Phase 2: Auto-Matching for Uploads

### 2.1 MetadataExtractorService
**New File:** `app/services/metadata_extractor_service.rb`

Extract metadata from files:
- EPUB: Parse OPF metadata (title, author, ISBN, description)
- M4B/MP3: Parse audio tags (future)
- Fallback: Parse filename

```ruby
Result = Data.define(:title, :author, :isbn, :description, :year, :publisher, :language, :confidence)
```

### 2.2 UploadAutoMatchService
**New File:** `app/services/upload_auto_match_service.rb`

Auto-match logic:
1. Extract metadata from file
2. If ISBN present, search by ISBN (95% confidence)
3. Search by title + author
4. Score results against extracted metadata
5. Return match result with confidence

Thresholds:
- ≥85%: Auto-accept
- 50-84%: Flag for review
- <50%: No match, manual selection needed

```ruby
Result = Data.define(:matched, :metadata_result, :confidence, :needs_review, :reason)
```

### 2.3 Database Migration
**New File:** `db/migrate/YYYYMMDDHHMMSS_add_auto_match_fields_to_uploads.rb`

```ruby
add_column :uploads, :metadata_source, :string
add_column :uploads, :metadata_source_id, :string
add_column :uploads, :auto_matched, :boolean, default: false
add_column :uploads, :needs_review, :boolean, default: false
add_column :uploads, :match_confidence, :integer
add_column :uploads, :match_reason, :string
```

### 2.4 Update UploadProcessingJob
**File:** `app/jobs/upload_processing_job.rb`

1. Extract metadata from file
2. Run auto-match
3. If high confidence: process automatically
4. If low confidence: flag for review, notify admin

### 2.5 Upload Review UI
**New File:** `app/views/admin/uploads/_review_form.html.erb`

Show:
- Extracted metadata
- Suggested match with cover
- Accept/Reject/Search manually buttons

### 2.6 Upload Controller Actions
**File:** `app/controllers/admin/uploads_controller.rb`

- `review` - Show review form
- `accept_match` - Accept suggested match
- `search_match` - Manual search
- `select_match` - Select from search results
- `process_without_metadata` - Use filename only

### 2.7 Routes
**File:** `config/routes.rb`

```ruby
resources :uploads do
  member do
    get :review
    post :accept_match
    get :search_match
    post :select_match
    post :process_without_metadata
  end
end
```

### 2.8 Tests
**New File:** `test/services/metadata_extractor_service_test.rb`
**New File:** `test/services/upload_auto_match_service_test.rb`

---

## Files Summary

### New Files (Phase 1)
- `app/services/hardcover_client.rb`
- `app/services/metadata_service.rb`
- `db/migrate/YYYYMMDDHHMMSS_add_metadata_source_to_books.rb`
- `test/services/hardcover_client_test.rb`
- `test/services/metadata_service_test.rb`
- `test/cassettes/hardcover/*.yml`

### New Files (Phase 2)
- `app/services/metadata_extractor_service.rb`
- `app/services/upload_auto_match_service.rb`
- `db/migrate/YYYYMMDDHHMMSS_add_auto_match_fields_to_uploads.rb`
- `app/views/admin/uploads/_review_form.html.erb`
- `test/services/metadata_extractor_service_test.rb`
- `test/services/upload_auto_match_service_test.rb`

### Modified Files
- `app/services/settings_service.rb`
- `app/models/book.rb`
- `app/models/system_health.rb`
- `app/controllers/search_controller.rb`
- `app/controllers/requests_controller.rb`
- `app/controllers/admin/settings_controller.rb`
- `app/controllers/admin/uploads_controller.rb`
- `app/jobs/health_check_job.rb`
- `app/jobs/upload_processing_job.rb`
- `app/views/admin/settings/_form.html.erb`
- `app/views/search/_results.html.erb`
- `config/routes.rb`
- `app/services/duplicate_detection_service.rb`

---

## Hardcover API Reference

**Endpoint:** `https://api.hardcover.app/v1/graphql`

**Auth:** Header `authorization: <token>`

**Rate Limit:** 60 requests/minute

**Search Query:**
```graphql
query SearchBooks($query: String!, $perPage: Int!) {
  search(query: $query, query_type: "Book", per_page: $perPage) {
    results
  }
}
```

**Available Fields:** title, author_names, description, rating, release_year, isbns, series_names, has_audiobook, has_ebook, cached_image

**Get Book:**
```graphql
query GetBook($id: Int!) {
  books(where: { id: { _eq: $id } }) {
    id, title, author_names, description, rating, release_year,
    isbns, series_names, has_audiobook, has_ebook, cached_image, pages, genres
  }
}
```
