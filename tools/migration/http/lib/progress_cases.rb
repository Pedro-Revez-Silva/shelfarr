# frozen_string_literal: true

require "json"
require "securerandom"

module Migration
  module Http
    module ProgressCases
      JSON_HEADERS = { "Content-Type" => "application/json" }.freeze
      FORM_HEADERS = { "Content-Type" => "application/x-www-form-urlencoded" }.freeze
      TEXT_HEADERS = { "Content-Type" => "text/plain" }.freeze
      UNSUPPORTED_VERB = { "status" => 405, "code" => "method_not_allowed" }.freeze
      UNSUPPORTED_BODY = { "status" => 415, "code" => "unsupported_media_type" }.freeze
      UNSUPPORTED_ASSET = { "status" => 501, "code" => "unsupported_asset_format" }.freeze
      UNSUPPORTED_KIND = { "status" => 501, "code" => "unsupported_publication_kind" }.freeze
      GENERIC_MEDIA = { "status" => 422, "code" => "invalid_progress" }.freeze
      UNSUPPORTED_FORMATS = { "status" => 501, "code" => "unsupported_reader_format" }.freeze
      LOCATOR = { "href" => "OEBPS/chapter.xhtml", "type" => "application/xhtml+xml", "locations" => { "progression" => 0.3, "totalProgression" => 0.2, "position" => 4 } }.freeze

      def seed_progress_library
        root = @paths.media
        stamp = Time.at(1_700_200_000, 7, :nsec)
        %w[pw-audio pw-audio-b pw-audio-c pw-audio-d pw-audio-e pw-audio-upper pw-audio-shape pw-audio-status pw-audio-bare].each_with_index do |key, index|
          path = write_bytes(File.join(root, "#{key}.mp3"), deterministic_bytes(40 + index, 2500 + index), stamp + index)
          @books[key] = create_book("PW #{key}", :audiobook, path, author: "Progress")
        end
        serial = File.join(root, "pw-serial")
        2.times { |index| write_bytes(File.join(serial, "Part #{index + 1}.m4b"), deterministic_bytes(60 + index, 1800 + index), stamp + index) }
        @books["pw-serial"] = create_book("PW serial", :audiobook, serial)
        %w[pw-epub pw-epub-b pw-epub-c pw-epub-d pw-epub-e pw-epub-status pw-epub-formats pw-epub-form].each_with_index do |key, index|
          @books[key] = create_book("PW #{key}", :ebook, write_epub(File.join(root, "#{key}.epub"), key, stamp + index))
        end
        mixed = File.join(root, "pw-mixed")
        write_epub(File.join(mixed, "Mixed.epub"), "pw-mixed", stamp)
        write_bytes(File.join(mixed, "Mixed.pdf"), "%PDF-1.4\n#{'p' * 700}", stamp)
        @books["pw-mixed"] = create_book("PW mixed", :ebook, mixed)
        @books["pw-missing"] = create_book("PW missing", :ebook, File.join(root, "pw-missing.epub"))
        @books["pw-comic"] = create_book("PW comic", :comicbook, write_epub(File.join(root, "pw-comic.epub"), "pw-comic", stamp))
        @books["pw-comic-status"] = create_book("PW comic status", :comicbook, write_epub(File.join(root, "pw-comic-status.epub"), "pw-comic-status", stamp))
      end

      def progress_scenarios
        @epoch = Time.now.utc.change(usec: 250_000)
        @now = @epoch
        @mutations = 0
        read_scenarios
        audio_write_scenarios
        audio_validation_scenarios
        locator_scenarios
        scope_and_account_scenarios
        legacy_row_scenarios
        status_scenarios
        shape_scenarios
        projection_scenarios
      end

      private

      def tick(seconds = 1)
        @now += seconds
      end

      def iso(offset)
        (@epoch + offset).utc.iso8601(3)
      end

      def mutation
        format("00000000-0000-4000-8000-%012d", @mutations += 1)
      end

      def book_of(key)
        @books.fetch(key)
      end

      def asset_id(key, format = nil)
        found = listed_assets(book_of(key)).find { |candidate| format.nil? || candidate.format == format }
        found&.id || ("0" * 64)
      end

      def progress_url(key, suffix = "progress")
        "#{Cases::PREFIX}/library/#{book_of(key).id}/#{suffix}"
      end

      def audio_fields(key, version: 0, seconds: 17.5, mutation_id: nil, **extra)
        { "asset_id" => asset_id(key), "expected_version" => version, "client_mutation_id" => mutation_id || mutation, "position_seconds" => seconds }.merge(extra.transform_keys(&:to_s))
      end

      def ebook_fields(key, locator, version: 0, mutation_id: nil, **extra)
        { "asset_id" => asset_id(key), "expected_version" => version, "client_mutation_id" => mutation_id || mutation, "locator" => locator }.merge(extra.transform_keys(&:to_s))
      end

      def put_progress(name, key, body, bearer: "alice-full", headers: JSON_HEADERS, at: nil, go: nil, ignore: false)
        text = body.is_a?(String) ? body : JSON.generate(body)
        entry = request(name, progress_url(key), bearer: bearer, method: "PUT", headers: headers, body: text, at: at || tick, go: go, track: book_of(key).id)
        restore_state(book_of(key).id, entry.fetch("state_before")) if ignore
        entry
      end

      def put_status(name, key, body, bearer: "alice-full", headers: JSON_HEADERS, at: nil, go: nil, ignore: false, extra_headers: {})
        text = body.is_a?(String) ? body : JSON.generate(body)
        entry = request(name, progress_url(key, "reading_status"), bearer: bearer, method: "PUT", headers: headers.merge(extra_headers), body: text, at: at || tick, go: go, track: book_of(key).id)
        restore_state(book_of(key).id, entry.fetch("state_before")) if ignore
        entry
      end

      def get_progress(name, key, bearer: "alice-full", method: "GET", go: nil, path: nil)
        request(name, path || progress_url(key), bearer: bearer, method: method, at: tick, go: go, track: book_of(key).id)
      end

      def read_scenarios
        %w[alice-full bob-full alice-read-only alice-progress-only alice-revoked alice-expired carol-deleted-user ownerless-library member-no-scopes admin-full].each do |label|
          get_progress("progress-get-#{label}", "pw-audio", bearer: label)
        end
        get_progress("progress-get-unauthenticated", "pw-audio", bearer: nil)
        get_progress("progress-head", "pw-audio", method: "HEAD")
        get_progress("progress-head-forbidden", "pw-audio", bearer: "alice-progress-only", method: "HEAD")
        %w[0 01 999999 abc 9223372036854775807 9223372036854775808 99999999999999999999 1%20].each do |id|
          request("progress-get-id-#{id}", "#{Cases::PREFIX}/library/#{id}/progress", bearer: "alice-full", at: tick)
        end
        request("progress-get-format-suffix", "#{Cases::PREFIX}/library/#{book_of('pw-audio').id}.json/progress", bearer: "alice-full", at: tick, go: { "status" => 404, "code" => "not_found" })
        get_progress("progress-get-missing-media", "pw-missing")
        get_progress("progress-get-comic", "pw-comic", go: UNSUPPORTED_KIND)
        unacquired = Book.where(file_path: [ nil ]).first
        request("progress-get-unacquired", "#{Cases::PREFIX}/library/#{unacquired.id}/progress", bearer: "alice-full", at: tick) if unacquired
      end

      def audio_write_scenarios
        key = "pw-audio"
        first = audio_fields(key, seconds: 17.5, mutation_id: "6f1c8d2e-3b4a-4c5d-8e9f-0a1b2c3d4e5f", observed_at: iso(-3600))
        put_progress("audio-create", key, first)
        put_progress("audio-retry-later", key, first, at: tick(600))
        put_progress("audio-retry-other-seconds", key, first.merge("position_seconds" => 18))
        put_progress("audio-retry-other-observed", key, first.merge("observed_at" => iso(-3599)))
        put_progress("audio-retry-observed-dropped", key, first.except("observed_at"))
        put_progress("audio-retry-stale-version", key, first.merge("expected_version" => 77))
        put_progress("audio-retry-uppercase-uuid", key, first.merge("client_mutation_id" => first["client_mutation_id"].upcase))
        put_progress("audio-new-mutation-stale-version", key, audio_fields(key, version: 0, seconds: 40))
        put_progress("audio-new-mutation-future-version", key, audio_fields(key, version: 5, seconds: 40))
        second = audio_fields(key, version: 1, seconds: 30, observed_at: iso(-1800))
        put_progress("audio-update", key, second)
        put_progress("audio-older-activity-with-current-version", key, audio_fields(key, version: 2, seconds: 900, observed_at: iso(-7200)))
        put_progress("audio-equal-time-other-place", key, audio_fields(key, version: 2, seconds: 31, observed_at: iso(-1800)))
        put_progress("audio-equal-time-same-place", key, audio_fields(key, version: 2, seconds: 30, observed_at: iso(-1800)))
        put_progress("audio-resolve-older-wrong-version", key, audio_fields(key, version: 2, seconds: 400, observed_at: iso(-9000), resolve_conflict: true))
        choice = audio_fields(key, version: 3, seconds: 400, observed_at: iso(-9000), resolve_conflict: true)
        put_progress("audio-resolve-older", key, choice)
        put_progress("audio-resolve-retry", key, choice, at: tick(60))
        put_progress("audio-resolve-reused-uuid", key, choice.merge("expected_version" => 4, "position_seconds" => 5))
        put_progress("audio-resolve-false-null", key, audio_fields(key, version: 4, seconds: 6, observed_at: iso(-9500), resolve_conflict: nil))
        put_progress("audio-resolve-false", key, audio_fields(key, version: 4, seconds: 6, observed_at: iso(-9500), resolve_conflict: false))
        put_progress("audio-without-activity-time", key, audio_fields(key, version: 4, seconds: 7))
        put_progress("audio-known-time-after-unknown", key, audio_fields(key, version: 5, seconds: 8, observed_at: iso(-100)))
        put_progress("audio-null-activity-time", key, audio_fields(key, version: 6, seconds: 9, observed_at: nil))
        put_progress("audio-unknown-field-ignored", key, audio_fields(key, version: 7, seconds: 10, device: "phone", extra: { "a" => [ 1 ] }))
        put_progress("audio-duplicate-key-last-wins", key, %({"asset_id":"#{asset_id(key)}","expected_version":8,"client_mutation_id":"#{mutation}","position_seconds":1,"position_seconds":11}))
        get_progress("audio-read-back", key)
        get_progress("audio-read-back-other-account", key, bearer: "bob-full")
        put_progress("audio-other-account-create", key, audio_fields(key, seconds: 3), bearer: "bob-full")
        put_progress("audio-other-account-retry-version-zero", key, audio_fields(key, version: 0, seconds: 4), bearer: "bob-full")
        get_progress("audio-read-back-bob", key, bearer: "bob-full")
        put_progress("serial-create-first-track", "pw-serial", audio_fields("pw-serial", seconds: 12))
        serial_assets = listed_assets(book_of("pw-serial"))
        put_progress("serial-move-to-second-track", "pw-serial", audio_fields("pw-serial", version: 1, seconds: 2, asset_id: serial_assets.last.id))
        put_progress("serial-seconds-as-integer", "pw-serial", audio_fields("pw-serial", version: 2, seconds: 5, asset_id: serial_assets.last.id))
      end

      def audio_validation_scenarios
        key = "pw-audio-c"
        good = audio_fields(key, mutation_id: "11111111-1111-4111-8111-111111111111")
        variants = {
          "missing-asset" => good.except("asset_id"), "null-asset" => good.merge("asset_id" => nil), "array-asset" => good.merge("asset_id" => [ good["asset_id"] ]),
          "uppercase-asset" => good.merge("asset_id" => good["asset_id"].upcase), "short-asset" => good.merge("asset_id" => good["asset_id"][0, 63]),
          "version-string" => good.merge("expected_version" => "0"), "version-float" => good.merge("expected_version" => 0.0), "version-null" => good.merge("expected_version" => nil),
          "version-true" => good.merge("expected_version" => true), "version-negative" => good.merge("expected_version" => -1), "version-array" => good.merge("expected_version" => [ 0 ]),
          "version-int64-max" => good.merge("expected_version" => 2**63 - 1), "version-beyond-int64" => good.merge("expected_version" => 2**63), "version-huge" => good.merge("expected_version" => 10**30),
          "missing-mutation" => good.except("client_mutation_id"), "bad-mutation" => good.merge("client_mutation_id" => "not-a-uuid"), "mutation-padded" => good.merge("client_mutation_id" => "#{good['client_mutation_id']} "),
          "mutation-null" => good.merge("client_mutation_id" => nil), "mutation-number" => good.merge("client_mutation_id" => 5),
          "seconds-negative" => good.merge("position_seconds" => -1), "seconds-over-31-days" => good.merge("position_seconds" => 2_678_401), "seconds-just-over" => good.merge("position_seconds" => 2_678_400.001),
          "seconds-string" => good.merge("position_seconds" => "10"), "seconds-null" => good.merge("position_seconds" => nil), "seconds-true" => good.merge("position_seconds" => true),
          "seconds-array" => good.merge("position_seconds" => [ 1 ]), "seconds-object" => good.merge("position_seconds" => { "a" => 1 }), "seconds-missing" => good.except("position_seconds"),
          "seconds-huge" => good.merge("position_seconds" => 999_999_999), "locator-on-audio" => good.merge("locator" => { "href" => "a", "locations" => {} }),
          "locator-empty-on-audio" => good.merge("locator" => {}),
          "observed-no-zone" => good.merge("observed_at" => "2026-11-07T10:00:00"), "observed-date-only" => good.merge("observed_at" => "2026-11-07"), "observed-word" => good.merge("observed_at" => "yesterday"),
          "observed-number" => good.merge("observed_at" => 1_762_500_000), "observed-object" => good.merge("observed_at" => { "at" => iso(-10) }), "observed-array" => good.merge("observed_at" => [ iso(-10) ]),
          "observed-true" => good.merge("observed_at" => true), "observed-blank" => good.merge("observed_at" => ""), "observed-padded" => good.merge("observed_at" => " #{iso(-10)}"),
          "observed-feb-30" => good.merge("observed_at" => "2026-02-30T10:00:00Z"), "observed-feb-29-common-year" => good.merge("observed_at" => "2026-02-29T10:00:00Z"),
          "observed-month-13" => good.merge("observed_at" => "2026-13-01T10:00:00Z"), "observed-day-0" => good.merge("observed_at" => "2026-11-00T10:00:00Z"),
          "observed-hour-24" => good.merge("observed_at" => "2026-11-07T24:00:00Z"), "observed-minute-60" => good.merge("observed_at" => "2026-11-07T10:60:00Z"), "observed-second-60" => good.merge("observed_at" => "2026-11-07T10:00:60Z"),
          "observed-offset-24" => good.merge("observed_at" => "2026-11-07T10:00:00+24:00"), "observed-offset-compact" => good.merge("observed_at" => "2026-11-07T10:00:00+0100"),
          "observed-ten-digit-fraction" => good.merge("observed_at" => "2026-11-07T10:00:00.1234567890Z"), "observed-empty-fraction" => good.merge("observed_at" => "2026-11-07T10:00:00.Z"),
          "observed-lowercase" => good.merge("observed_at" => "2026-11-07t10:00:00z"), "observed-future" => good.merge("observed_at" => (@now + 700).utc.iso8601(3)),
          "observed-fullwidth-digits" => good.merge("observed_at" => "２０２６-11-07T10:00:00Z"),
          "resolve-string" => good.merge("resolve_conflict" => "true"), "resolve-one" => good.merge("resolve_conflict" => 1), "resolve-array" => good.merge("resolve_conflict" => [ true ]),
          "resolve-object" => good.merge("resolve_conflict" => { "yes" => true }), "resolve-empty-string" => good.merge("resolve_conflict" => ""),
          "unknown-asset" => good.merge("asset_id" => "0" * 64), "asset-of-another-book" => good.merge("asset_id" => asset_id("pw-audio")), "asset-of-an-ebook" => good.merge("asset_id" => asset_id("pw-epub"))
        }
        variants.each { |name, body| put_progress("audio-invalid-#{name}", key, body) }
        { "audio-invalid-json-brace" => "{", "audio-invalid-json-trailing-comma" => %({"a":1,}), "audio-invalid-json-text" => "not json", "audio-invalid-json-nan" => %({"position_seconds":NaN}),
          "audio-array-body" => "[]", "audio-null-body" => "null", "audio-string-body" => %("x"), "audio-number-body" => "5", "audio-empty-body" => "", "audio-empty-object" => "{}" }.each do |name, body|
          put_progress(name, key, body)
        end
        put_progress("audio-seconds-overflowing-float", key, JSON.generate(good).sub('"position_seconds":17.5', '"position_seconds":1e400'))
        put_progress("audio-invalid-json-deeply-nested", key, %({"a":#{'[' * 120}#{']' * 120}}))
        put_progress("audio-invalid-json-bom", key, "﻿#{JSON.generate(good)}")
        put_progress("audio-form-encoded-body", key, URI.encode_www_form(good.transform_values(&:to_s)), headers: FORM_HEADERS, go: UNSUPPORTED_BODY)
        put_progress("audio-text-body", key, JSON.generate(good), headers: TEXT_HEADERS, go: UNSUPPORTED_BODY)
        put_progress("epub-too-large-media", "too-large", ebook_fields("too-large", LOCATOR), go: GENERIC_MEDIA)
        put_progress("epub-empty-file", "empty", ebook_fields("empty", LOCATOR))
        put_progress("audio-limit-future-tolerance-accepted", "pw-audio-d", audio_fields("pw-audio-d", observed_at: (@now + 1 + 299).utc.iso8601(3)))
        put_progress("audio-limit-future-tolerance-exact", "pw-audio-e", audio_fields("pw-audio-e", observed_at: (@now + 1 + 300).utc.iso8601(3)))
        put_progress("audio-limit-future-tolerance-over", "pw-audio-e", audio_fields("pw-audio-e", observed_at: (@now + 1 + 300.001r).utc.iso8601(3)))
        put_progress("audio-normalised-offset", "pw-audio-upper", audio_fields("pw-audio-upper", mutation_id: "6F1C8D2E-3B4A-4C5D-8E9F-0A1B2C3D4E5F", observed_at: "2025-11-07T10:15:30.123456+01:00"))
        put_progress("audio-normalised-offset-retry", "pw-audio-upper", audio_fields("pw-audio-upper", mutation_id: "6F1C8D2E-3B4A-4C5D-8E9F-0A1B2C3D4E5F", observed_at: "2025-11-07T09:15:30.123Z"))
        put_progress("audio-offset-sub-millisecond-differs", "pw-audio-upper", audio_fields("pw-audio-upper", mutation_id: "6F1C8D2E-3B4A-4C5D-8E9F-0A1B2C3D4E5F", observed_at: "2025-11-07T09:15:30.124Z"))
      end

      def locator_scenarios
        key = "pw-epub"
        full = LOCATOR.merge("title" => "One", "text" => { "highlight" => "x" }, "vendor" => { "k" => [ 1, 2 ] })
        full["locations"] = full["locations"].merge("cfi" => "/2/4", "readAlong" => { "generation" => "c" * 64, "audio" => 2, "offset_ms" => 1500 })
        body = ebook_fields(key, full, mutation_id: "22222222-2222-4222-8222-222222222222", observed_at: iso(-3000))
        put_progress("epub-create-full-locator", key, body)
        put_progress("epub-retry-reordered-keys", key, body.merge("locator" => full.to_a.reverse.to_h))
        put_progress("epub-retry-equal-numbers", key, JSON.generate(body).sub('"progression":0.3', '"progression":0.30'))
        put_progress("epub-retry-changed-locator", key, body.merge("locator" => full.merge("href" => "OEBPS/two.xhtml")))
        put_progress("epub-retry-added-field", key, body.merge("locator" => full.merge("extra" => 1)))
        put_progress("epub-update-integer-fractions", key, ebook_fields(key, { "href" => "a.xhtml", "locations" => { "progression" => 1, "totalProgression" => 0, "position" => 99_999_999_999_999_999_999 } }, version: 1, observed_at: iso(-2000)))
        get_progress("epub-read-back", key)
        put_progress("epub-update-minimal-locator", key, ebook_fields(key, { "href" => "OEBPS/chapter 2.xhtml?x=1#y", "locations" => {} }, version: 2))
        put_progress("epub-update-encoded-path", key, ebook_fields(key, { "href" => "OEBPS/chapter%202.xhtml", "locations" => {}, "unicode" => "é😀" }, version: 3))
        put_progress("epub-accepts-dot-segments-only-as-names", key, ebook_fields(key, { "href" => "a..b/%252e%252e/c", "locations" => {} }, version: 4))
        invalid_key = "pw-epub-b"
        refused = {
          "locator-null" => nil, "locator-array" => [], "locator-string" => "x", "locator-number" => 5, "locator-empty" => {}, "no-href" => { "locations" => {} }, "no-locations" => { "href" => "a" },
          "locations-null" => { "href" => "a", "locations" => nil }, "locations-array" => { "href" => "a", "locations" => [] }, "href-empty" => { "href" => "", "locations" => {} },
          "href-blank" => { "href" => " \t", "locations" => {} }, "href-null" => { "href" => nil, "locations" => {} }, "href-number" => { "href" => 5, "locations" => {} },
          "href-too-long" => { "href" => "a" * 2049, "locations" => {} }, "href-absolute" => { "href" => "/abs", "locations" => {} }, "href-encoded-absolute" => { "href" => "%2Fabs", "locations" => {} },
          "href-url" => { "href" => "https://attacker.example", "locations" => {} }, "href-colon" => { "href" => "a:b", "locations" => {} }, "href-encoded-colon" => { "href" => "a%3Ab", "locations" => {} },
          "href-dotdot" => { "href" => "..", "locations" => {} }, "href-dotdot-prefix" => { "href" => "../private.xhtml", "locations" => {} }, "href-dotdot-middle" => { "href" => "a/../b", "locations" => {} },
          "href-encoded-dotdot" => { "href" => "%2e%2e/x", "locations" => {} }, "href-encoded-dotdot-upper" => { "href" => "a/%2E%2E", "locations" => {} },
          "href-backslash" => { "href" => "a\\b", "locations" => {} }, "href-encoded-backslash" => { "href" => "a%5Cb", "locations" => {} }, "href-encoded-nul" => { "href" => "a%00b", "locations" => {} },
          "href-control" => { "href" => "a\u0001b", "locations" => {} }, "href-encoded-control" => { "href" => "a%1fb", "locations" => {} }, "href-newline" => { "href" => "a\nb", "locations" => {} },
          "progression-high" => { "href" => "a", "locations" => { "progression" => 1.1 } }, "progression-negative" => { "href" => "a", "locations" => { "progression" => -0.1 } },
          "progression-null" => { "href" => "a", "locations" => { "progression" => nil } }, "progression-string" => { "href" => "a", "locations" => { "progression" => "0.5" } },
          "total-progression-high" => { "href" => "a", "locations" => { "totalProgression" => 2 } }, "position-zero" => { "href" => "a", "locations" => { "position" => 0 } },
          "position-negative" => { "href" => "a", "locations" => { "position" => -1 } }, "position-float" => { "href" => "a", "locations" => { "position" => 1.0 } },
          "position-null" => { "href" => "a", "locations" => { "position" => nil } }, "position-string" => { "href" => "a", "locations" => { "position" => "3" } },
          "read-along-null" => { "href" => "a", "locations" => { "readAlong" => nil } }, "read-along-array" => { "href" => "a", "locations" => { "readAlong" => [] } },
          "read-along-empty" => { "href" => "a", "locations" => { "readAlong" => {} } },
          "read-along-missing-offset" => { "href" => "a", "locations" => { "readAlong" => { "generation" => "c" * 64, "audio" => 0 } } },
          "read-along-extra-key" => { "href" => "a", "locations" => { "readAlong" => { "generation" => "c" * 64, "audio" => 0, "offset_ms" => 0, "x" => 1 } } },
          "read-along-uppercase-generation" => { "href" => "a", "locations" => { "readAlong" => { "generation" => "C" * 64, "audio" => 0, "offset_ms" => 0 } } },
          "read-along-audio-high" => { "href" => "a", "locations" => { "readAlong" => { "generation" => "c" * 64, "audio" => 2000, "offset_ms" => 0 } } },
          "read-along-audio-negative" => { "href" => "a", "locations" => { "readAlong" => { "generation" => "c" * 64, "audio" => -1, "offset_ms" => 0 } } },
          "read-along-offset-high" => { "href" => "a", "locations" => { "readAlong" => { "generation" => "c" * 64, "audio" => 0, "offset_ms" => 172_800_001 } } },
          "read-along-audio-float" => { "href" => "a", "locations" => { "readAlong" => { "generation" => "c" * 64, "audio" => 0.0, "offset_ms" => 0 } } },
          "oversized" => { "href" => "a", "locations" => {}, "text" => { "highlight" => "x" * 17_000 } }
        }
        refused.each { |name, locator| put_progress("epub-invalid-#{name}", invalid_key, ebook_fields(invalid_key, locator, mutation_id: "33333333-3333-4333-8333-333333333333")) }
        put_progress("epub-invalid-seconds-with-locator", invalid_key, ebook_fields(invalid_key, LOCATOR, position_seconds: 0))
        put_progress("epub-invalid-observed-time", invalid_key, ebook_fields(invalid_key, LOCATOR, observed_at: "nope"))
        put_progress("epub-null-seconds-accepted", "pw-epub-c", ebook_fields("pw-epub-c", LOCATOR, position_seconds: nil, observed_at: iso(-60)))
        put_progress("epub-audio-asset-refused", invalid_key, ebook_fields(invalid_key, LOCATOR).merge("asset_id" => asset_id("pw-audio")))
        put_progress("epub-overflowing-progression", invalid_key, JSON.generate(ebook_fields(invalid_key, LOCATOR)).sub('"progression":0.3', '"progression":1e400'))
        put_progress("epub-missing-media", "pw-missing", ebook_fields("pw-missing", LOCATOR).merge("asset_id" => "a" * 64))
        mixed = "pw-mixed"
        put_progress("epub-mixed-epub-asset", mixed, ebook_fields(mixed, LOCATOR).merge("asset_id" => asset_id(mixed, "epub")))
        pdf_locator = { "href" => "document.pdf", "type" => "application/pdf", "locations" => { "position" => 3 } }
        put_progress("epub-mixed-pdf-asset", mixed, ebook_fields(mixed, pdf_locator, version: 1).merge("asset_id" => asset_id(mixed, "pdf")), go: UNSUPPORTED_ASSET, ignore: true)
        put_progress("comic-record-write", "pw-comic", ebook_fields("pw-comic", LOCATOR), go: UNSUPPORTED_KIND, ignore: true)
      end

      def scope_and_account_scenarios
        key = "pw-audio-b"
        put_progress("scope-read-only-write", key, audio_fields(key), bearer: "alice-read-only")
        put_progress("scope-unauthenticated-write", key, audio_fields(key), bearer: nil)
        %w[alice-revoked alice-expired carol-deleted-user ownerless-library member-no-scopes].each do |label|
          put_progress("scope-write-#{label}", key, audio_fields(key), bearer: label)
        end
        put_progress("scope-progress-only-write", key, audio_fields(key, seconds: 21, mutation_id: "44444444-4444-4444-8444-444444444444"), bearer: "alice-progress-only")
        get_progress("scope-progress-only-read", key, bearer: "alice-progress-only")
        get_progress("scope-full-read-after-progress-only-write", key)
        put_progress("scope-admin-write", key, audio_fields(key, version: 0, seconds: 22), bearer: "admin-full")
        put_progress("scope-write-wrong-token", key, audio_fields(key), bearer: nil, headers: JSON_HEADERS.merge("Authorization" => "Bearer shf_#{'x' * 40}"))
        put_progress("scope-write-basic-auth", key, audio_fields(key), bearer: nil, headers: JSON_HEADERS.merge("Authorization" => "Basic YWxpY2U6eA=="))
        put_status("scope-status-read-only", key, { "status" => "finished" }, bearer: "alice-read-only")
        put_status("scope-status-unauthenticated", key, { "status" => "finished" }, bearer: nil)
        put_status("scope-status-progress-only", key, { "status" => "in_progress" }, bearer: "alice-progress-only")
        put_status("scope-status-deleted-owner", key, { "status" => "finished" }, bearer: "carol-deleted-user")
        %w[POST DELETE PATCH].each { |verb| request("verb-progress-#{verb.downcase}", progress_url(key), bearer: "alice-full", method: verb, headers: JSON_HEADERS, body: "{}", at: tick, go: UNSUPPORTED_VERB) }
        %w[GET HEAD POST DELETE].each { |verb| request("verb-status-#{verb.downcase}", progress_url(key, "reading_status"), bearer: "alice-full", method: verb, headers: JSON_HEADERS, body: "{}", at: tick, go: UNSUPPORTED_VERB) }
      end

      def legacy_row_scenarios
        seeded = ConsumerProgress.where(user: users.fetch("alice")).joins(:book).order(:id).to_a
        audio = seeded.find { |row| row.book.audiobook? }
        reading = seeded.find { |row| !row.book.audiobook? && row.book.ebook? }
        [ audio, reading ].compact.each_with_index do |row, index|
          book = row.book
          @books["legacy-#{index}"] = book
          get_progress("legacy-#{index}-read", "legacy-#{index}")
          current = listed_assets(book).first
          next unless current

          fields = if book.audiobook?
            { "asset_id" => current.id, "expected_version" => row.version, "client_mutation_id" => mutation, "position_seconds" => 321.5 }
          else
            { "asset_id" => current.id, "expected_version" => row.version, "client_mutation_id" => mutation, "locator" => LOCATOR }
          end
          put_progress("legacy-#{index}-stale-version", "legacy-#{index}", fields.merge("expected_version" => row.version + 1))
          put_progress("legacy-#{index}-update", "legacy-#{index}", fields.merge("observed_at" => iso(-5)))
          put_progress("legacy-#{index}-older-activity", "legacy-#{index}", fields.merge("expected_version" => row.version + 1, "client_mutation_id" => mutation, "observed_at" => iso(-500)))
        end
      end

      def status_scenarios
        key = "pw-epub-status"
        %w[finished unread in_progress finished].each_with_index { |status, index| put_status("status-set-#{index}-#{status}", key, { "status" => status }) }
        put_status("status-repeat-finished", key, { "status" => "finished" })
        put_status("status-other-account", key, { "status" => "in_progress" }, bearer: "bob-full")
        put_status("status-progress-only-token", key, { "status" => "unread" }, bearer: "alice-progress-only")
        { "unknown" => { "status" => "unknown" }, "array" => { "status" => [ "finished" ] }, "null" => { "status" => nil }, "number" => { "status" => 1 }, "true" => { "status" => true },
          "object" => { "status" => { "a" => "finished" } }, "capitalised" => { "status" => "Finished" }, "padded" => { "status" => " finished" }, "empty-object" => {}, "array-body" => [], "unknown-field" => { "state" => "finished" } }.each do |name, body|
          put_status("status-invalid-#{name}", key, body)
        end
        { "json-brace" => "{", "json-text" => "not json", "empty" => "", "null" => "null", "string" => %("finished") }.each { |name, body| put_status("status-invalid-#{name}", key, body) }
        put_status("status-extra-fields-ignored", key, { "status" => "in_progress", "device" => "tablet", "nested" => { "a" => [ 1 ] } })
        put_status("status-duplicate-key", key, %({"status":"unread","status":"finished"}))
        request("status-unknown-book-id", "#{Cases::PREFIX}/library/999999/reading_status", bearer: "alice-full", method: "PUT", headers: JSON_HEADERS, body: %({"status":"finished"}), at: tick, track: 999_999)
        %w[0 01 abc 9223372036854775808].each do |id|
          request("status-book-id-#{id}", "#{Cases::PREFIX}/library/#{id}/reading_status", bearer: "alice-full", method: "PUT", headers: JSON_HEADERS, body: %({"status":"finished"}), at: tick)
        end
        unacquired = Book.where(file_path: [ nil ]).first
        request("status-unacquired", "#{Cases::PREFIX}/library/#{unacquired.id}/reading_status", bearer: "alice-full", method: "PUT", headers: JSON_HEADERS, body: %({"status":"finished"}), at: tick, track: unacquired.id) if unacquired
        put_status("status-comic-record", "pw-comic-status", { "status" => "finished" }, go: UNSUPPORTED_KIND, ignore: true)
        put_status("status-missing-media", "pw-missing", { "status" => "finished" })
        put_status("status-formats-epub", "pw-epub-formats", { "status" => "finished" }, extra_headers: { Cases::FORMATS_HEADER => "epub" })
        put_status("status-formats-invalid", "pw-epub-formats", { "status" => "unread" }, extra_headers: { Cases::FORMATS_HEADER => "mobi" })
        put_status("status-formats-padded", "pw-epub-formats", { "status" => "in_progress" }, extra_headers: { Cases::FORMATS_HEADER => " epub " })
        put_status("status-formats-empty", "pw-epub-formats", { "status" => "unread" }, extra_headers: { Cases::FORMATS_HEADER => "" })
        put_status("status-formats-pdf", "pw-epub-formats", { "status" => "unread" }, extra_headers: { Cases::FORMATS_HEADER => "pdf" }, go: UNSUPPORTED_FORMATS, ignore: true)
        put_status("status-features-header-ignored", "pw-epub-formats", { "status" => "in_progress" }, extra_headers: { Cases::FEATURES_HEADER => "read-along" })
        put_status("status-form-encoded", "pw-epub-form", "status=finished", headers: FORM_HEADERS, go: UNSUPPORTED_BODY, ignore: true)
        put_status("status-text-body", "pw-epub-form", %({"status":"finished"}), headers: TEXT_HEADERS, go: UNSUPPORTED_BODY)
        put_progress("status-then-progress-write", "pw-audio-status", audio_fields("pw-audio-status", version: 0, seconds: 44, observed_at: iso(-30)))
        put_status("status-on-audio-finished", "pw-audio-status", { "status" => "finished" })
        put_progress("status-survives-later-progress", "pw-audio-status", audio_fields("pw-audio-status", version: 1, seconds: 45, observed_at: iso(-20)))
        put_status("status-on-audio-unread-keeps-place", "pw-audio-status", { "status" => "unread" })
        put_status("status-without-progress-in-progress", "pw-audio-bare", { "status" => "in_progress" })
        put_status("status-without-progress-finished", "pw-audio-d", { "status" => "finished" })
      end

      def shape_scenarios
        key = "pw-audio-shape"
        body = audio_fields(key, version: 0, seconds: 60, observed_at: iso(-10))
        put_progress("shape-write-after-status", key, body)
        put_progress("shape-exact-retry", key, body, at: tick(7200))
        put_progress("shape-large-uuid-case", key, body.merge("expected_version" => 1, "client_mutation_id" => "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE", "position_seconds" => 2_678_400, "observed_at" => iso(-5)))
        put_progress("shape-seconds-zero", key, body.merge("expected_version" => 2, "client_mutation_id" => mutation, "position_seconds" => 0, "observed_at" => iso(-4)))
        put_progress("shape-seconds-fraction", key, body.merge("expected_version" => 3, "client_mutation_id" => mutation, "position_seconds" => 0.000001, "observed_at" => iso(-3)))
      end

      def projection_scenarios
        users_by_label = { "alice-full" => "alice", "bob-full" => "bob" }
        users_by_label.each_key do |label|
          @books.each do |key, book|
            next unless key.start_with?("pw-") || key.start_with?("legacy-")
            next if book.comicbook?

            request("projection-#{label}-#{key}", "#{Cases::PREFIX}/library/#{book.id}", bearer: label, at: tick)
          end
          %w[unread in_progress finished].each { |status| request("projection-#{label}-library-#{status}", "#{Cases::PREFIX}/library?status=#{status}&limit=50", bearer: label, at: tick) }
          request("projection-#{label}-continue", "#{Cases::PREFIX}/continue?limit=20", bearer: label, at: tick)
          request("projection-#{label}-continue-formats", "#{Cases::PREFIX}/continue", bearer: label, headers: { Cases::FORMATS_HEADER => "epub" }, at: tick)
        end
      end

      def record_write(entry, body, at, track, before)
        entry["body"] = body
        if body.is_a?(String) && !body.dup.force_encoding(Encoding::UTF_8).valid_encoding?
          entry["body"] = nil
          entry["body_base64"] = [ body ].pack("m0")
        end
        entry["at"] = at.utc.iso8601(6) if at
        return unless track

        entry["tracked_book"] = Integer(track)
        entry["state_before"] = before.fetch("state")
        entry["state"] = progress_state(track)
        entry["tokens_changed"] = token_changes(before.fetch("tokens"))
      end

      def progress_state(book_id)
        id = Integer(book_id)
        ActiveRecord::Base.with_connection do |connection|
          {
            "progress" => connection.select_all("SELECT user_id, book_id, asset_id, CAST(locator AS TEXT) AS locator, position_seconds, version, client_mutation_id, CAST(created_at AS TEXT) AS created_at, CAST(updated_at AS TEXT) AS updated_at, CAST(observed_at AS TEXT) AS observed_at FROM consumer_progresses WHERE book_id = #{id} ORDER BY user_id, id").to_a,
            "reading" => connection.select_all("SELECT user_id, book_id, status, CAST(created_at AS TEXT) AS created_at, CAST(updated_at AS TEXT) AS updated_at FROM consumer_reading_states WHERE book_id = #{id} ORDER BY user_id, id").to_a
          }
        end
      end

      def restore_state(book_id, state)
        id = Integer(book_id)
        ActiveRecord::Base.with_connection do |connection|
          connection.execute("DELETE FROM consumer_progresses WHERE book_id = #{id}")
          connection.execute("DELETE FROM consumer_reading_states WHERE book_id = #{id}")
          insert_rows(connection, "consumer_progresses", state.fetch("progress"))
          insert_rows(connection, "consumer_reading_states", state.fetch("reading"))
        end
      end

      def insert_rows(connection, table, rows)
        rows.each do |row|
          columns = row.keys
          connection.execute("INSERT INTO #{table} (#{columns.join(', ')}) VALUES (#{row.values.map { |value| connection.quote(value) }.join(', ')})")
        end
      end

      def progress_rows
        ActiveRecord::Base.with_connection do |connection|
          connection.select_all("SELECT user_id, book_id, asset_id, CAST(locator AS TEXT) AS locator, position_seconds, version, client_mutation_id, CAST(created_at AS TEXT) AS created_at, CAST(updated_at AS TEXT) AS updated_at, CAST(observed_at AS TEXT) AS observed_at FROM consumer_progresses ORDER BY user_id, book_id").to_a
        end
      end

      def reading_rows
        ActiveRecord::Base.with_connection do |connection|
          connection.select_all("SELECT user_id, book_id, status, CAST(created_at AS TEXT) AS created_at, CAST(updated_at AS TEXT) AS updated_at FROM consumer_reading_states ORDER BY user_id, book_id").to_a
        end
      end

      def token_marks
        ActiveRecord::Base.with_connection do |connection|
          connection.select_all("SELECT id, CAST(last_used_at AS TEXT) AS last_used_at, CAST(updated_at AS TEXT) AS updated_at, CAST(revoked_at AS TEXT) AS revoked_at, replaces_api_token_id FROM api_tokens ORDER BY id").to_a.index_by { |row| row.fetch("id") }
        end
      end

      def token_changes(before)
        token_marks.reject { |id, row| before[id] == row }.transform_keys(&:to_s)
      end
    end
  end
end
