# frozen_string_literal: true

require "cgi"
require "digest"
require "fileutils"
require "json"
require "zip"
require "active_support/testing/time_helpers"
require_relative "progress_cases"

module Migration
  module Http
    class Cases
      include ActiveSupport::Testing::TimeHelpers
      include ProgressCases

      PREFIX = "/api/consumer/v1"
      FORMATS_HEADER = "X-Shelfarr-Reader-Formats"
      FEATURES_HEADER = "X-Shelfarr-Reader-Features"
      IGNORED_HEADERS = %w[date server-timing x-request-id x-runtime set-cookie].freeze
      EXTRA_TITLES = [
        "alpha", "Alpha", "ALPHA beta", "100% Cotton", "snake_case title", "back\\slash", "Zed & Co", "ünïcode Éclair",
        "<script>&amp;</script>", "quote\"d", "emoji \u{1F4DA} book", "tie", "Tie", "TIE", "line one two", "  padded title  ",
        "Mix_ed % Chars", "Zebra", "apple", "Banana", "cherry", "Date", "elder", "Fig", "grape", "Honeydew", "iris", "Juniper",
        "kiwi", "Lemon", "mango", "Nectarine", "olive", "Papaya", "quince", "Raspberry"
      ].freeze

      def initialize(paths:, bundle:)
        @paths = paths
        @bundle = bundle
        @cases = []
        @books = {}
        @tokens = {}
      end

      def call
        load_bundle
        reset_database
        configure_encryption
        seed_extra_library
        seed_extra_tokens
        seed_extra_progress
        seed_progress_library
        checkpoint_and_copy
        @session = ActionDispatch::Integration::Session.new(Rails.application)
        run_scenarios
        write_outputs
      end

      private

      def load_bundle
        @manifest = JSON.parse(File.read(File.join(@bundle, "manifest.json")))
        credentials = JSON.parse(File.read(File.join(@bundle, "secrets", "credentials.json")))
        @raw = credentials.fetch("tokens").dup
        @encryption = credentials.fetch("encryption")
        @bundle_db = File.join(@bundle, "db", "primary.sqlite3")
        @bundle_media = @manifest.fetch("media_root")
      end

      def reset_database
        ActiveRecord::Base.connection_handler.clear_all_connections!
        Dir.glob("#{@paths.primary_db}*").each { |file| FileUtils.rm_f(file) }
        FileUtils.cp(@bundle_db, @paths.primary_db)
        File.chmod(0o600, @paths.primary_db)
      end

      def configure_encryption
        ActiveRecord::Encryption.configure(
          primary_key: @encryption["primary_key"], deterministic_key: @encryption["deterministic_key"],
          key_derivation_salt: @encryption["key_derivation_salt"], hash_digest_class: OpenSSL::Digest::SHA256,
          support_sha1_for_non_deterministic_encryption: true
        )
      end

      def users
        @users ||= User.where(username: %w[alice bob carol]).index_by(&:username)
      end

      def write_epub(path, label, time)
        FileUtils.mkdir_p(File.dirname(path))
        files = {
          "mimetype" => "application/epub+zip",
          "META-INF/container.xml" => '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
          "OEBPS/content.opf" => %(<package version="3.0" unique-identifier="id" xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:uuid:#{label}</dc:identifier></metadata><manifest><item id="one" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="one"/></spine></package>),
          "OEBPS/chapter.xhtml" => %(<html xmlns="http://www.w3.org/1999/xhtml"><body><p>#{label}</p></body></html>)
        }
        Zip::File.open(path, create: true) { |zip| files.each { |name, content| zip.get_output_stream(name) { |out| out.write(content) } } }
        File.utime(time, time, path)
        path
      end

      def write_bytes(path, bytes, time)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, bytes)
        File.utime(time, time, path)
        path
      end

      def deterministic_bytes(seed, length)
        Random.new(seed).bytes(length)
      end

      def create_book(title, type, path, **extra)
        Book.create!({ title: title, book_type: type, file_path: path }.merge(extra))
      end

      def seed_extra_library
        root = @paths.media
        SettingsService.set(:comicbook_output_path, root)
        base_time = Time.at(1_700_000_000, 111_222_333, :nsec)
        EXTRA_TITLES.each_with_index do |title, index|
          time = base_time + (index * 3600)
          author = index % 5 == 0 ? nil : "Author #{index % 7}"
          if index % 6 == 5
            bytes = deterministic_bytes(index, 2048 + index)
            path = write_bytes(File.join(root, "audio-#{index}", "Track #{index}.mp3"), bytes, time)
            create_book(title, :audiobook, File.dirname(path), author: author, description: "Audio #{index}", cover_url: "https://covers.example.test/#{index}.jpg")
          else
            path = write_epub(File.join(root, "book-#{index}.epub"), "extra-#{index}", time)
            create_book(title, :ebook, path, author: author, description: index.even? ? "Description #{index}" : nil)
          end
        end
        @big_audio = write_bytes(File.join(root, "Big Listening.mp3"), deterministic_bytes(7, 300 * 1024 + 17), base_time)
        @books["big-audio"] = create_book("Big Listening", :audiobook, @big_audio, author: "B. Streamer")
        multi = File.join(root, "Serial Audio")
        3.times { |index| write_bytes(File.join(multi, "Part #{index + 1}.m4b"), deterministic_bytes(20 + index, 1500 + index), base_time + index) }
        @books["serial-audio"] = create_book("Serial Audio", :audiobook, multi, author: "C. Serial")
        mixed = File.join(root, "Mixed Formats")
        write_epub(File.join(mixed, "Mixed Formats.epub"), "mixed", base_time)
        write_bytes(File.join(mixed, "Mixed Formats.pdf"), "%PDF-1.4\n#{'x' * 600}", base_time)
        zip_path = File.join(mixed, "Mixed Formats.cbz")
        Zip::File.open(zip_path, create: true) { |zip| zip.get_output_stream("1.png") { |out| out.write("png") } }
        @books["mixed"] = create_book("Mixed Formats", :ebook, mixed, author: "D. Mixed")
        empty = write_bytes(File.join(root, "Empty File.epub"), "", base_time)
        @books["empty"] = create_book("Empty File", :ebook, empty)
        sparse = File.join(root, "Too Large.epub")
        File.open(sparse, "wb") { |file| file.truncate(251 * 1024 * 1024) }
        @books["too-large"] = create_book("Too Large", :ebook, sparse)
        comic_dir = File.join(root, "Comic Record.epub")
        write_epub(comic_dir, "comic-record", base_time)
        @books["comic-epub"] = create_book("Comic Record", :comicbook, comic_dir)
      end

      def seed_extra_progress
        books = Book.acquired.where.not(book_type: :comicbook).order(:id).to_a
        alice, bob = users.fetch("alice"), users.fetch("bob")
        stamp = Time.utc(2026, 11, 10, 12, 0, 0, 500_000)
        books.each_with_index do |book, index|
          next unless (index % 4).zero? || index % 7 == 3

          asset = listed_assets(book, formats: Consumer::ReaderFormats::DEFAULT).first
          next unless asset

          owner = index.even? ? alice : bob
          next if ConsumerProgress.exists?(user: owner, book: book)

          ConsumerProgress.create!(user: owner, book: book, asset_id: index % 9 == 0 ? "stale-#{asset.id}" : asset.id, locator: book.audiobook? ? nil : { "href" => "chapter#{index}.xhtml" },
            position_seconds: book.audiobook? ? index * 1.5 : nil, version: 1 + index, client_mutation_id: "extra-#{index}", observed_at: index % 5 == 0 ? nil : stamp + (index * 60),
            created_at: stamp, updated_at: stamp + (index * 30))
        end
        books.last(6).each_with_index do |book, index|
          ConsumerReadingState.create!(user: alice, book: book, status: %i[unread in_progress finished][index % 3], created_at: stamp, updated_at: stamp + (index * 45)) unless ConsumerReadingState.exists?(user: alice, book: book)
        end
      end

      def issue(label, user, scopes, **options)
        token, raw = APIToken.issue!(name: label, user: user, scopes: scopes, issued_via: APIToken::CONSUMER_DEVICE, **options)
        @raw[label] = raw
        @tokens[label] = token
      end

      def direct_token(label, user, scopes:, replaces: nil, expires_at: nil, connection_key: nil)
        raw = "shf_#{SecureRandom.alphanumeric(40)}"
        @raw[label] = raw
        @tokens[label] = APIToken.create!(name: label, user: user, scopes: scopes, token_digest: APIToken.digest(raw), token_prefix: raw.first(12),
          replaces_api_token_id: replaces, expires_at: expires_at, connection_key: connection_key || SecureRandom.uuid, issued_via: APIToken::CONSUMER_DEVICE)
      end

      def seed_extra_tokens
        admin = User.create!(username: "admin_http", name: "Admin Http", password: "Synthetic-#{SecureRandom.hex(8)}-Aa1", role: :admin)
        member = User.create!(username: "member_http", name: "Member Http", password: "Synthetic-#{SecureRandom.hex(8)}-Aa1")
        issue("admin-full", admin, %w[library:read progress:write requests:admin users:write])
        issue("alice-read-only", users.fetch("alice"), %w[library:read])
        issue("bob-read-only", users.fetch("bob"), %w[library:read])
        issue("member-privileged-scopes", member, %w[library:read requests:admin users:write])
        direct_token("member-string-scopes", member, scopes: %w[library:read].to_json).update_columns(scopes: "\"library:read,progress:write\"")
        direct_token("member-spaced-scopes", member, scopes: %w[library:read].to_json).update_columns(scopes: "[\"library:read progress:write\", \"search:read\"]")
        direct_token("member-no-scopes", member, scopes: "[]")
        direct_token("member-garbage-scopes", member, scopes: "[]").update_columns(scopes: "not json")
        direct_token("ownerless-library", nil, scopes: %w[library:read].to_json)
        previous = users.fetch("alice")
        direct_token("adopt-previous-revoked", previous, scopes: %w[library:read].to_json).update_columns(revoked_at: Time.utc(2026, 11, 1))
        direct_token("adopt-previous-expired", previous, scopes: %w[library:read].to_json).update_columns(expires_at: Time.utc(2020, 1, 1))
        direct_token("adopt-previous-other-user", users.fetch("bob"), scopes: %w[library:read].to_json)
        direct_token("adopt-previous-live", previous, scopes: %w[library:read].to_json)
        direct_token("adopt-revoked-parent", previous, scopes: %w[library:read].to_json, replaces: @tokens.fetch("adopt-previous-revoked").id)
        direct_token("adopt-expired-parent", previous, scopes: %w[library:read].to_json, replaces: @tokens.fetch("adopt-previous-expired").id)
        direct_token("adopt-foreign-parent", previous, scopes: %w[library:read].to_json, replaces: @tokens.fetch("adopt-previous-other-user").id)
        direct_token("adopt-dangling-parent", previous, scopes: %w[library:read].to_json, replaces: 987_654)
        direct_token("adopt-live-parent", previous, scopes: %w[library:read].to_json, replaces: @tokens.fetch("adopt-previous-live").id)
      end

      def checkpoint_and_copy
        ActiveRecord::Base.with_connection { |connection| connection.execute("PRAGMA wal_checkpoint(TRUNCATE)") }
        ActiveRecord::Base.connection_handler.clear_all_connections!
        @pre_scenario = File.join(@paths.out, "db", "pre-scenario.sqlite3")
        FileUtils.cp(@paths.primary_db, @pre_scenario)
        @token_state_before = token_state
      end

      def token_state
        ActiveRecord::Base.with_connection do |connection|
          connection.select_all("SELECT id, user_id, scopes, expires_at, replaces_api_token_id, connection_key, revoked_at IS NOT NULL AS revoked, last_used_at IS NOT NULL AS used, updated_at FROM api_tokens ORDER BY id").to_a
        end
      end

      def request(name, path, bearer: nil, method: "GET", headers: {}, authorization: nil, go: nil, body: nil, at: nil, track: nil)
        sent = headers.dup
        sent["Authorization"] = authorization if authorization
        sent["Authorization"] = "Bearer #{@raw.fetch(bearer)}" if bearer
        before = track && { "state" => progress_state(track), "tokens" => token_marks }
        recorded = body&.dup
        perform = -> { @session.process(method.downcase.to_sym, path, params: body, headers: sent) }
        at ? travel_to(at, with_usec: true, &perform) : perform.call
        response = @session.response
        text = response.body.to_s
        entry = { "name" => name, "method" => method, "path" => path, "bearer" => bearer, "authorization" => authorization, "headers" => headers,
                  "status" => response.status, "response_headers" => normalized(response.headers), "body_bytes" => text.bytesize, "body_sha256" => Digest::SHA256.hexdigest(text) }
        entry["json"] = JSON.parse(text) if response.media_type == "application/json" && !text.empty?
        entry["go"] = go if go
        record_write(entry, recorded, at, track, before) if body || at || track
        @cases << entry
        entry
      end

      def normalized(headers)
        headers.to_h.transform_keys(&:downcase).reject { |key, _| IGNORED_HEADERS.include?(key) }
      end

      def run_scenarios
        server_scenarios
        authentication_scenarios
        catalogue_scenarios
        continue_scenarios
        publication_scenarios
        asset_scenarios
        adoption_scenarios
        progress_scenarios
        @token_state_after = token_state
      end

      def server_scenarios
        %w[GET HEAD].each { |method| request("server-#{method.downcase}", "#{PREFIX}/server.json", method: method) }
        request("server-ignores-bearer", "#{PREFIX}/server.json", bearer: "alice-full")
        request("server-without-suffix", "#{PREFIX}/server")
      end

      def authentication_scenarios
        labels = @raw.keys.reject { |label| label.start_with?("adopt-") || label == "alice-adopting" || label == "alice-previous" }
        labels.each { |label| %w[GET HEAD].each { |method| request("me-#{label}-#{method.downcase}", "#{PREFIX}/me", bearer: label, method: method) } }
        {
          "no-header" => nil, "bearer-only" => "Bearer", "bearer-blank" => "Bearer    ", "basic" => "Basic YWxpY2U6eA==", "token-only" => @raw.fetch("alice-full"),
          "lower-scheme" => "bearer #{@raw.fetch('alice-full')}", "upper-scheme" => "BEARER #{@raw.fetch('alice-full')}", "extra-spaces" => "Bearer    #{@raw.fetch('alice-full')}",
          "tab-separator" => "Bearer\t#{@raw.fetch('alice-full')}", "wrong-token" => "Bearer shf_#{'x' * 40}"
        }.each { |name, value| request("me-header-#{name}", "#{PREFIX}/me", authorization: value) }
      end

      def catalogue_scenarios
        %w[alice-full bob-full alice-progress-only carol-deleted-user admin-full member-string-scopes member-spaced-scopes member-no-scopes member-privileged-scopes ownerless-library].each do |label|
          %w[GET HEAD].each { |method| request("library-#{label}-#{method.downcase}", "#{PREFIX}/library", bearer: label, method: method) }
        end
        filters = {
          "type-ebook" => "type=ebook", "type-audiobook" => "type=audiobook", "type-blank" => "type=", "type-whitespace" => "type=%20", "type-unknown" => "type=comic",
          "status-blank" => "status=%20", "status-unread" => "status=unread", "status-in-progress" => "status=in_progress", "status-finished" => "status=finished", "status-unknown" => "status=nope",
          "query-title" => "q=quiet", "query-percent" => "q=%25", "query-underscore" => "q=_", "query-backslash" => "q=%5C", "query-unicode" => "q=%C3%A9", "query-upper" => "q=ALPHA",
          "query-blank" => "q=", "query-spaces" => "q=%20%20", "query-too-long" => "q=#{'a' * 201}", "query-200-bytes" => "q=#{'a' * 200}", "query-array" => "q%5B%5D=x",
          "sort-title" => "sort=title", "sort-recent" => "sort=recent", "sort-unknown" => "sort=zzz", "sort-blank" => "sort=",
          "limit-1" => "limit=1", "limit-0" => "limit=0", "limit-50" => "limit=50", "limit-999" => "limit=999", "limit-1000" => "limit=1000", "limit-text" => "limit=abc", "limit-negative" => "limit=-1", "limit-array" => "limit%5B%5D=2",
          "combined" => "type=ebook&sort=title&limit=7&status=unread", "duplicate-limit" => "limit=2&limit=3", "unknown-parameter" => "zzz=1"
        }
        filters.each { |name, query| request("library-filter-#{name}", "#{PREFIX}/library?#{query}", bearer: "alice-full") }
        request("library-bob-types", "#{PREFIX}/library?type=audiobook&limit=3", bearer: "bob-full")
        pagination_chain("recent", "alice-full", "limit=5")
        pagination_chain("title", "alice-full", "limit=6&sort=title")
        pagination_chain("title-bob", "bob-full", "limit=9&sort=title&type=ebook")
        pagination_chain("query", "alice-full", "limit=3&q=a")
        pagination_chain("status", "alice-full", "limit=2&status=unread")
        cursor_scenarios
        format_header_scenarios
      end

      def pagination_chain(name, bearer, query)
        cursor = nil
        10.times do |page|
          path = "#{PREFIX}/library?#{query}#{cursor ? "&cursor=#{CGI.escape(cursor)}" : ''}"
          entry = request("library-page-#{name}-#{page + 1}", path, bearer: bearer)
          cursor = entry.dig("json", "next_cursor")
          break unless cursor
        end
      end

      def cursor_scenarios
        first = @cases.find { |entry| entry["name"] == "library-page-recent-1" }
        cursor = first.dig("json", "next_cursor")
        title_cursor = @cases.find { |entry| entry["name"] == "library-page-title-1" }.dig("json", "next_cursor")
        escaped = CGI.escape(cursor)
        request("cursor-other-account", "#{PREFIX}/library?limit=5&cursor=#{escaped}", bearer: "bob-full")
        request("cursor-other-query", "#{PREFIX}/library?limit=5&q=a&cursor=#{escaped}", bearer: "alice-full")
        request("cursor-other-sort", "#{PREFIX}/library?limit=5&sort=title&cursor=#{escaped}", bearer: "alice-full")
        request("cursor-other-type", "#{PREFIX}/library?limit=5&type=ebook&cursor=#{escaped}", bearer: "alice-full")
        request("cursor-title-for-recent", "#{PREFIX}/library?limit=6&cursor=#{CGI.escape(title_cursor)}", bearer: "alice-full")
        request("cursor-tampered", "#{PREFIX}/library?limit=5&cursor=#{CGI.escape(cursor[0...-2])}AA", bearer: "alice-full")
        request("cursor-garbage", "#{PREFIX}/library?cursor=not-a-cursor", bearer: "alice-full")
        request("cursor-blank", "#{PREFIX}/library?cursor=", bearer: "alice-full")
        request("cursor-spaces", "#{PREFIX}/library?cursor=%20", bearer: "alice-full")
        request("cursor-oversized", "#{PREFIX}/library?cursor=#{'a' * 4100}", bearer: "alice-full")
        request("cursor-array", "#{PREFIX}/library?cursor%5B%5D=a", bearer: "alice-full")
        request("cursor-same-limit-different", "#{PREFIX}/library?limit=7&cursor=#{escaped}", bearer: "alice-full")
        request("cursor-formats-bound", "#{PREFIX}/library?limit=5&cursor=#{escaped}", bearer: "alice-full", headers: { FORMATS_HEADER => "epub" })
      end

      def format_header_scenarios
        { "epub" => "epub", "epub-twice" => "epub,epub", "padded" => " epub ", "empty" => "", "unknown" => "mobi", "trailing-comma" => "epub,", "uppercase" => "EPUB" }.each do |name, value|
          request("formats-library-#{name}", "#{PREFIX}/library?limit=4", bearer: "alice-full", headers: { FORMATS_HEADER => value })
        end
        { "pdf" => "pdf", "cbz" => "cbz", "all" => "epub,pdf,cbz" }.each do |name, value|
          request("formats-library-#{name}", "#{PREFIX}/library?limit=4", bearer: "alice-full", headers: { FORMATS_HEADER => value },
            go: { "status" => 501, "code" => "unsupported_reader_format" })
        end
        request("formats-over-64-bytes", "#{PREFIX}/library", bearer: "alice-full", headers: { FORMATS_HEADER => "epub," * 20 })
      end

      def continue_scenarios
        %w[alice-full bob-full alice-progress-only admin-full].each do |label|
          %w[GET HEAD].each { |method| request("continue-#{label}-#{method.downcase}", "#{PREFIX}/continue", bearer: label, method: method) }
        end
        %w[limit=1 limit=0 limit=21 limit=100 limit=1000 limit=abc limit=%20 limit%5B%5D=2].each { |query| request("continue-#{query}", "#{PREFIX}/continue?#{query}", bearer: "alice-full") }
        request("continue-formats-epub", "#{PREFIX}/continue", bearer: "alice-full", headers: { FORMATS_HEADER => "epub" })
        request("continue-formats-pdf", "#{PREFIX}/continue", bearer: "alice-full", headers: { FORMATS_HEADER => "pdf" }, go: { "status" => 501, "code" => "unsupported_reader_format" })
        request("continue-formats-invalid", "#{PREFIX}/continue", bearer: "alice-full", headers: { FORMATS_HEADER => "zzz" })
      end

      def acquired_books
        @acquired_books ||= Book.acquired.order(:id).to_a
      end

      def publication_scenarios
        acquired_books.each do |book|
          %w[alice-full bob-full].each { |label| request("publication-#{book.id}-#{label}", "#{PREFIX}/library/#{book.id}", bearer: label) }
        end
        request("publication-head", "#{PREFIX}/library/#{acquired_books.first.id}", bearer: "alice-full", method: "HEAD")
        %w[0 01 999999 abc 9223372036854775807 9223372036854775808 99999999999999999999 1%20].each do |id|
          request("publication-id-#{id}", "#{PREFIX}/library/#{id}", bearer: "alice-full")
        end
        request("publication-format-suffix", "#{PREFIX}/library/#{acquired_books.first.id}.json", bearer: "alice-full", go: { "status" => 404, "code" => "not_found" })
        unacquired = Book.where(file_path: [ nil ]).first
        request("publication-unacquired", "#{PREFIX}/library/#{unacquired.id}", bearer: "alice-full") if unacquired
        request("publication-no-scope", "#{PREFIX}/library/#{acquired_books.first.id}", bearer: "alice-progress-only")
        request("publication-unauthenticated", "#{PREFIX}/library/#{acquired_books.first.id}")
        first = acquired_books.first.id
        request("publication-formats-epub", "#{PREFIX}/library/#{first}", bearer: "alice-full", headers: { FORMATS_HEADER => "epub" })
        request("publication-formats-invalid", "#{PREFIX}/library/#{first}", bearer: "alice-full", headers: { FORMATS_HEADER => "zzz" })
        request("publication-formats-pdf", "#{PREFIX}/library/#{first}", bearer: "alice-full", headers: { FORMATS_HEADER => "pdf" }, go: { "status" => 501, "code" => "unsupported_reader_format" })
        request("publication-features-unknown", "#{PREFIX}/library/#{first}", bearer: "alice-full", headers: { FEATURES_HEADER => "something-new" })
        request("publication-features-invalid", "#{PREFIX}/library/#{first}", bearer: "alice-full", headers: { FEATURES_HEADER => "Bad Feature" })
        request("publication-features-read-along", "#{PREFIX}/library/#{first}", bearer: "alice-full", headers: { FEATURES_HEADER => "read-along" }, go: { "status" => 501, "code" => "unsupported_reader_feature" })
        comic = Book.find_by(book_type: :comicbook)
        request("publication-comic-default-formats", "#{PREFIX}/library/#{comic.id}", bearer: "alice-full") if comic
        request("publication-comic-pdf-formats", "#{PREFIX}/library/#{comic.id}", bearer: "alice-full", headers: { FORMATS_HEADER => "pdf" }, go: { "status" => 501, "code" => "unsupported_reader_format" }) if comic
      end

      def listed_assets(book, formats: Consumer::ReaderFormats::SUPPORTED)
        Consumer::LibraryAssets.new(book, formats: formats).list
      rescue Consumer::LibraryAssets::Unavailable
        []
      end

      def asset_path(book, asset_id)
        "#{PREFIX}/library/#{book.id}/assets/#{asset_id}"
      end

      def asset_scenarios
        acquired_books.each do |book|
          next if book.comicbook?

          listed_assets(book).each_with_index do |asset, index|
            graphic = %w[pdf cbz].include?(asset.format)
            go = graphic ? { "status" => 501, "code" => "unsupported_asset_format" } : nil
            request("asset-#{book.id}-#{index}-get", asset_path(book, asset.id), bearer: "alice-full", go: go)
            request("asset-#{book.id}-#{index}-head", asset_path(book, asset.id), bearer: "alice-full", method: "HEAD", go: go)
          end
        end
        detailed_asset_scenarios
        failure_asset_scenarios
      end

      def asset_for(key)
        book = @books.fetch(key)
        [ book, listed_assets(book).first ]
      end

      def detailed_asset_scenarios
        book, asset = asset_for("big-audio")
        path = asset_path(book, asset.id)
        size = asset.size_bytes
        ranges = {
          "first-byte" => "bytes=0-0", "prefix" => "bytes=0-1023", "middle" => "bytes=1000-5000", "open-ended" => "bytes=#{size - 100}-", "suffix" => "bytes=-100",
          "suffix-whole" => "bytes=-#{size + 50}", "past-end-clamped" => "bytes=#{size - 10}-#{size + 1000}", "last-byte" => "bytes=#{size - 1}-#{size - 1}",
          "start-at-size" => "bytes=#{size}-", "reversed" => "bytes=9-3", "suffix-zero" => "bytes=-0", "bare-dash" => "bytes=-", "multiple" => "bytes=0-1,5-6",
          "wrong-unit" => "items=0-1", "uppercase-unit" => "BYTES=0-1", "garbage" => "bytes=abc", "huge-first" => "bytes=99999999999999999999-", "huge-last" => "bytes=5-99999999999999999999",
          "huge-suffix" => "bytes=-99999999999999999999", "leading-zero" => "bytes=007-9", "space" => "bytes= 1-2", "blank" => " "
        }
        ranges.each { |name, value| request("asset-range-#{name}", path, bearer: "alice-full", headers: { "Range" => value }) }
        request("asset-range-head", path, bearer: "alice-full", method: "HEAD", headers: { "Range" => "bytes=0-9" })
        etag = %("#{asset.id}")
        conditional = {
          "match" => etag, "weak" => "W/#{etag}", "star" => "*", "list" => %("zzz", #{etag}), "other" => '"zzz"', "unquoted" => asset.id, "blank" => ""
        }
        conditional.each { |name, value| request("asset-if-none-match-#{name}", path, bearer: "alice-full", headers: { "If-None-Match" => value }) }
        request("asset-if-none-match-head", path, bearer: "alice-full", method: "HEAD", headers: { "If-None-Match" => etag })
        request("asset-if-none-match-beats-range", path, bearer: "alice-full", headers: { "If-None-Match" => etag, "Range" => "bytes=0-9" })
        request("asset-if-range-match", path, bearer: "alice-full", headers: { "Range" => "bytes=0-9", "If-Range" => etag })
        request("asset-if-range-other", path, bearer: "alice-full", headers: { "Range" => "bytes=0-9", "If-Range" => '"zzz"' })
        request("asset-if-range-date", path, bearer: "alice-full", headers: { "Range" => "bytes=0-9", "If-Range" => "Wed, 21 Oct 2015 07:28:00 GMT" })
        request("asset-if-range-blank", path, bearer: "alice-full", headers: { "Range" => "bytes=0-9", "If-Range" => "" })
        request("asset-if-range-invalid-range", path, bearer: "alice-full", headers: { "Range" => "bytes=9-3", "If-Range" => etag })
        request("asset-other-user", path, bearer: "bob-full")
        request("asset-wrong-scope", path, bearer: "alice-progress-only")
        request("asset-unauthenticated", path)
        request("asset-revoked", path, bearer: "alice-revoked")
        request("asset-expired", path, bearer: "alice-expired")
        empty_book, empty_asset = asset_for("empty")
        request("asset-empty-get", asset_path(empty_book, empty_asset.id), bearer: "alice-full")
        request("asset-empty-range", asset_path(empty_book, empty_asset.id), bearer: "alice-full", headers: { "Range" => "bytes=0-0" })
        request("asset-empty-head", asset_path(empty_book, empty_asset.id), bearer: "alice-full", method: "HEAD")
      end

      def failure_asset_scenarios
        book, asset = asset_for("big-audio")
        other, other_asset = asset_for("serial-audio")
        request("asset-unknown-id", asset_path(book, "0" * 64), bearer: "alice-full")
        request("asset-uppercase-id", asset_path(book, asset.id.upcase), bearer: "alice-full")
        request("asset-short-id", asset_path(book, asset.id[0, 63]), bearer: "alice-full")
        request("asset-long-id", asset_path(book, "#{asset.id}0"), bearer: "alice-full")
        request("asset-id-of-another-book", asset_path(book, other_asset.id), bearer: "alice-full")
        request("asset-unknown-book", "#{PREFIX}/library/99999/assets/#{asset.id}", bearer: "alice-full")
        request("asset-bad-book-id", "#{PREFIX}/library/abc/assets/#{asset.id}", bearer: "alice-full")
        request("asset-with-suffix", "#{asset_path(book, asset.id)}.mp3", bearer: "alice-full", go: { "status" => 404, "code" => "not_found" })
        mixed, = asset_for("mixed")
        listed_assets(mixed).each { |candidate| request("asset-mixed-#{candidate.format}", asset_path(mixed, candidate.id), bearer: "alice-full", go: %w[pdf cbz].include?(candidate.format) ? { "status" => 501, "code" => "unsupported_asset_format" } : nil) }
        too_large = @books.fetch("too-large")
        request("asset-too-large-publication", "#{PREFIX}/library/#{too_large.id}", bearer: "alice-full")
        comic = @books.fetch("comic-epub")
        comic_asset = listed_assets(comic).first
        request("asset-comic-record", asset_path(comic, comic_asset.id), bearer: "alice-full", go: { "status" => 501, "code" => "unsupported_publication_kind" }) if comic_asset
      end

      def adoption_scenarios
        step = lambda do |name, bearer|
          request("adoption-#{name}", "#{PREFIX}/me", bearer: bearer)
        end
        step.call("revoked-parent", "adopt-revoked-parent")
        step.call("expired-parent", "adopt-expired-parent")
        step.call("foreign-parent", "adopt-foreign-parent")
        step.call("dangling-parent", "adopt-dangling-parent")
        step.call("live-parent-first-use", "adopt-live-parent")
        step.call("live-parent-second-use", "adopt-live-parent")
        step.call("retired-parent-after-adoption", "adopt-previous-live")
        step.call("alice-adopting-first-use", "alice-adopting")
        step.call("alice-previous-after-adoption", "alice-previous")
        step.call("alice-adopting-second-use", "alice-adopting")
        request("adoption-adopted-catalogue", "#{PREFIX}/library?limit=2", bearer: "alice-adopting")
      end

      def write_outputs
        FileUtils.mkdir_p(File.join(@paths.out, "secrets"), mode: 0o700)
        File.write(File.join(@paths.out, "secrets", "secret_key_base"), ENV.fetch("SECRET_KEY_BASE"), perm: 0o600)
        File.write(File.join(@paths.out, "secrets", "tokens.json"), JSON.pretty_generate(@raw), perm: 0o600)
        server = @cases.find { |entry| entry["name"] == "server-get" }
        document = {
          "format" => 1, "bundle_media_root" => @bundle_media, "extra_media_root" => @paths.media, "database" => "db/pre-scenario.sqlite3",
          "server_version" => server.dig("json", "server_version"), "schema_revision" => @manifest.dig("schema", "revision"),
          "origin" => @manifest.fetch("origin"), "token_state_before" => @token_state_before, "token_state_after" => @token_state_after,
          "progress_rows_after" => progress_rows, "reading_rows_after" => reading_rows, "cases" => @cases
        }
        File.write(File.join(@paths.out, "cases.json"), JSON.pretty_generate(document), perm: 0o600)
        ActiveRecord::Base.connection_handler.clear_all_connections!
        Dir.glob("#{@paths.primary_db}*").each { |file| FileUtils.rm_f(file) }
        FileUtils.rm_rf(File.join(@paths.out, "scratch"))
      end
    end
  end
end
