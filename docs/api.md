# Shelfarr API

Shelfarr exposes a JSON API under `/api/v1`.

For custom HTTP search/acquisition integrations called by Shelfarr, see [Custom Acquisition Providers](custom-acquisition-providers.md).

## Authentication

Use bearer authentication:

```http
Authorization: Bearer shf_...
```

Preferred tokens are user-scoped API tokens created from **Profile > API tokens**. The legacy global API token in settings is still accepted for compatibility and behaves as an admin token.

Scopes:

- `search:read` - search metadata providers
- `requests:read` - list and read visible requests
- `requests:write` - create and cancel requests for the token user
- `requests:admin` - retry requests and act across users
- `users:write` - create users

## Search

`GET /api/v1/search?q=dune&limit=5`

Returns metadata results with `work_id` values that can be passed to request creation.

## Requests

`GET /api/v1/requests`

Optional filters:

- `status` (`pending`, `searching`, `awaiting_purchase`, `not_found`,
  `downloading`, `processing`, `completed`, or `failed`)
- `created_via`
- `limit`

User tokens see their own requests. Admin/global tokens can see all requests.

`POST /api/v1/requests`

```json
{
  "work_id": "openlibrary:OL893415W",
  "book_type": "ebook",
  "title": "Dune",
  "author": "Frank Herbert",
  "language": "en"
}
```

Admin/global tokens may also pass `username` or `user_id` to create on behalf of a user. User-scoped tokens cannot create requests for other users.

`GET /api/v1/requests/:id`

Returns request status, book metadata, user attribution, and request origin metadata.
`awaiting_purchase` means Shelfarr found at least one enabled third-party store
offer, no acquisition download is running, and the request can be completed by
importing the file after purchase or retried for a fresh search.

Compatibility note: `awaiting_purchase` is an additive status. The meanings of
the existing statuses are unchanged, but API clients that exhaustively match
status strings should accept this new value before enabling a store provider.
Retrying one of these requests removes its previous quotes before starting a
fresh provider search.

`DELETE /api/v1/requests/:id`

Cancels a cancellable request.

`POST /api/v1/requests/:id/retry`

Requires `requests:admin`.

`GET /api/v1/requests/:id/search_results`

Requires `requests:read`. Returns downloadable acquisition candidates in `search_results` and currently enabled, market-valid third-party purchase options in a separate `store_offers` array. The first beta provider returns DRM-free ebook offers. Store offers include normalized provider, format, DRM, market, price, product URL, and quote-time fields; they are never downloadable or auto-selected by Shelfarr.

## Users

`POST /api/v1/users`

Requires `users:write`.
