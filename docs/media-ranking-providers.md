# Media Ranking Providers

Ranking providers are optional HTTP services that enrich and re-rank the
combined acquisition candidates Shelfarr has already found. They are separate
from custom acquisition providers: a ranking-only service does not implement
search or acquisition and never supplies a downloadable artifact.

Shelfarr uses a versioned, media-neutral contract so the same service can
support adapters for books, movies, television, music, games, or other media.
Shelfarr currently sends book-family media, including ebooks, audiobooks, and
comics. Other applications can send their own media types to the same API.

## Configuration and Disabled Behavior

Add services under **Admin > Ranking Providers**. Each provider has a name,
base URL, optional encrypted bearer token, timeout, private-network permission,
and enabled flag.

If no ranking provider is configured or enabled, Shelfarr makes no ranking
request and uses its existing ordering. If multiple providers are enabled,
Shelfarr calls the highest-priority provider. A failed request is logged and
normal ordering is retained. Disabling or deleting a provider also makes
previously saved scores from that provider stop affecting result order.

The **Test** action calls `GET /health`. Search-time ranking calls
`POST /v1/rank`.

## Version 1 Ranking Contract

```http
POST /v1/rank
Content-Type: application/json
Authorization: Bearer <token>
```

Shelfarr saves and locally scores the complete acquisition set before making
this call. Candidates can come from Prowlarr, Jackett,
Newznab/NZBHydra2, Anna's Archive, Z-Library, Project Gutenberg, LibriVox, or
custom acquisition providers.

```json
{
  "schema_version": 1,
  "task": "candidate_ranking",
  "media": {
    "type": "book",
    "format": "audiobook",
    "title": "Still",
    "release_year": 2017,
    "language": "en",
    "contributors": [
      { "role": "author", "name": "Kennedy Ryan" },
      { "role": "narrator", "name": "Jakobi Diem" }
    ],
    "relationships": [
      { "type": "series", "name": "Grip", "position": "2" }
    ],
    "identifiers": {
      "isbn": ["1515944042"],
      "hardcover": ["123"]
    },
    "attributes": {
      "content_kind": "book",
      "publisher": "Example Press",
      "description": "Stored description...",
      "metadata_source": "hardcover"
    }
  },
  "context": {
    "request_id": "35",
    "language": "en",
    "scope": "single"
  },
  "preferences": {
    "preferred_download_types": ["usenet", "torrent", "direct"],
    "approved_formats": ["m4b", "mp3"],
    "rejected_formats": [],
    "preferred_formats": ["m4b", "mp3"],
    "prefer_single_file": true,
    "prefer_higher_bitrate": true,
    "minimum_seeders": 1
  },
  "candidates": [
    {
      "candidate_id": "987",
      "title": "Still - Kennedy Ryan - Jakobi Diem [M4B]",
      "source": "prowlarr",
      "indexer": "Example Books",
      "download_type": "usenet",
      "size_bytes": 734003200,
      "published_at": "2026-06-08T12:00:00Z",
      "detected_language": "en",
      "detected_formats": ["m4b"],
      "audiobook_structure": "single_file",
      "audio_bitrate_kbps": 128,
      "application_score": 72,
      "application_score_breakdown": {
        "title": 100,
        "author": 100,
        "language": 50,
        "format": 100,
        "health": 100,
        "search_attempt": "title_author",
        "search_query": "Still Kennedy Ryan English"
      }
    }
  ]
}
```

The common `media` shape is deliberately extensible. A movie adapter could
send `type: "movie"`, contributors with the `director` role, TMDB/IMDb
identifiers, and resolution or edition attributes. A recommendation service
may share the same normalization and enrichment pipeline and expose a separate
`POST /v1/recommend` operation; Shelfarr only consumes candidate ranking.

Shelfarr deliberately omits download URLs, magnet links, info URLs, provider
payloads, and cover URLs. Ranking does not require those fields, and they may
contain credentials or force additional network lookups.

## Response

The provider returns any subset of the supplied opaque candidate IDs:

```json
{
  "schema_version": 1,
  "rankings": [
    {
      "candidate_id": "987",
      "rank_score": 97,
      "match_evidence": {
        "matched_fields": ["title", "author", "series", "narrator"]
      }
    }
  ]
}
```

Scores must be integers from 0 through 100. Invalid scores, unknown candidate
IDs, and malformed entries are ignored. External scores reorder candidates
only within Shelfarr's configured download-type preference.

Ranking remains advisory. It never changes Shelfarr's confidence score and
cannot bypass language, format, availability, blocklist, minimum-seeder, or
confidence gates. An external score of 100 cannot make a below-threshold result
auto-selectable.
