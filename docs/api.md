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

- `status`
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

`DELETE /api/v1/requests/:id`

Cancels a cancellable request.

`POST /api/v1/requests/:id/retry`

Requires `requests:admin`.

## Users

`POST /api/v1/users`

Requires `users:write`.
