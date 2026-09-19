# Series collections

Collections save the individual books in a Hardcover series. Each member is an
underlying **work**, independent of its publication edition and of whether you
want an ebook, an audiobook, or both. Seven works therefore require at most seven
ebooks and seven audiobooks. Existing suitable copies and open requests are
skipped when you submit the series again.

Screenshots: [Desktop](screenshot-collections.png) · [Mobile](screenshot-collections-mobile.png).

## Add and request a series

1. Configure Hardcover under the existing metadata settings.
2. Search for a book and open its details. If Hardcover supplies a series, use
   **View series collection** to load and save it. You can also add a series by
   its numeric Hardcover series ID on **Collections**.
3. Open the saved collection. Each book appears once, with separate ebook and
   audiobook availability.
4. Leave **Whole series** selected, or switch to individual book selection.
5. Select **Ebooks**, **Audiobooks**, or both, and choose the language.
6. Request the missing books. Acquisitions use the ordinary request, approval,
   matching, and download flows. Individual requests appear under **Requests**.

Opening a saved collection uses its stored membership. Adding the same series
again refreshes that membership after the entire provider response succeeds.
This milestone does not schedule refreshes or automatically acquire future
additions. Personal reading lists and Goodreads integration are separate work.

## Identity and unusual series entries

- Hardcover series and book IDs identify the collection and its members.
  ISBNs, edition IDs, cover changes, and publication years do not create more
  members. The same work can belong to multiple series.
- Existing ebook and audiobook library records with the exact Hardcover book
  ID are attached to the shared work without changing their files, editions,
  requests, or download history. Existing provider aliases on those records
  participate in request matching. Records without an established matching
  identity are not automatically merged based on title similarity.
- Merged records, partial books, and compilations/boxed sets are excluded from
  series import. Distinct works at the same numbered position are marked for
  review and skipped by whole-series acquisition. Select the intended book
  individually. Unnumbered entries remain separate; position is not an ID.
- A failed or incomplete provider fetch leaves the previous collection intact.
  A successful refresh can remove obsolete membership; it does not delete books
  or cancel requests.
- Owning an ebook does not satisfy an audiobook request. A copy in another or
  unknown language requires review before requesting a replacement. This feature
  does not replace owned copies automatically.

## Edition preference

Automatic selection for a collection prefers the newer known publication year
when otherwise equally suitable candidates have the same download type,
confidence, language, and scored quality. Existing matching and approval rules
still apply. Manual selection and ordinary single-book requests keep their
existing behaviour.

Reliable edition metadata is currently available from ZLibrary's explicit
publication year and from a custom acquisition provider's optional
`edition_year` field. Custom providers may return an integer or four-digit string
between 1000 and the current year. An upload timestamp, a year in a release
title, or an unverified inferred year is not edition evidence. If the leading
candidate has no reliable edition year, Shelfarr retains its normal selection.
This is a preference among available copies, not a guarantee that the latest
published edition is available from a configured acquisition source.

## Testing this branch

Use the feature checkout and its own development database:

```sh
bundle install
bin/rails db:prepare
bin/dev
```

Configure the normal providers and download clients in this development instance
before an actual acquisition test. The feature migration adds collections,
memberships, work identities, and an optional association on existing books; it
does not move or delete library files.

Focused regression tests:

```sh
PARALLEL_WORKERS=2 bin/rails test \
  test/services/book_collection_import_service_test.rb \
  test/services/book_collection_request_service_test.rb \
  test/services/hardcover_client_test.rb \
  test/services/edition_preference_service_test.rb \
  test/controllers/collections_controller_test.rb
bin/rails test:system TEST=test/system/collections_test.rb
```

Provider references:
[Hardcover series retrieval](https://github.com/hardcoverapp/hardcover-docs/blob/main/src/content/docs/api/guides/GettingBooksInSeries.mdx),
[Hardcover series standards](https://github.com/hardcoverapp/hardcover-docs/blob/main/src/content/docs/librarians/Standards/SeriesStandards.mdx).
