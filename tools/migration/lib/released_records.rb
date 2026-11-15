# frozen_string_literal: true

require "bcrypt"
require "digest"
require "json"
require "securerandom"

module Migration
  class ReleasedRecords
    BASE_TIME = Time.utc(2026, 10, 20, 8, 30, 15, 123_456)
    PASSWORD_COST = 12
    USER_IDS = { "alice" => 11, "bob" => 7, "carol" => 23, "dave" => 41, "erin" => 2 }.freeze
    BOOK_IDS = {
      "quiet" => 5, "audio" => 6, "tracks" => 9, "unicode" => 12, "indirect" => 13, "missing" => 14, "outside" => 15,
      "unacquired" => 17, "blank-path" => 18, "comic" => 21, "uppercase" => 22, "library-root" => 30
    }.freeze
    DOWNLOAD_CLIENT_IDS = { "primary" => 3, "optional-state-absent" => 9 }.freeze
    DELETED_HIGH_IDS = { "books" => 99, "requests" => 50 }.freeze
    LONG_DESCRIPTION_LENGTH = 20_005

    Result = Data.define(:passwords, :raw_tokens, :seeded_tables)

    def initialize(connection:, root:, media:, legacy_context:)
      @connection = connection
      @root = root
      @media = media
      @legacy_context = legacy_context
      @passwords = {}
      @raw_tokens = {}
      @ids = Hash.new { |hash, key| hash[key] = [] }
    end

    def call
      tables = ordered_tables
      explicit = explicit_seeds
      tables.each { |table| (explicit[table] || -> { fill_generic(table) }).call }
      DELETED_HIGH_IDS.each { |table, id| remove_high_id(table, id) }
      Result.new(passwords: @passwords, raw_tokens: @raw_tokens, seeded_tables: tables.select { |table| count(table).positive? })
    end

    private

    def explicit_seeds
      {
        "users" => -> { seed_users },
        "api_tokens" => -> { seed_api_tokens },
        "settings" => -> { seed_settings },
        "books" => -> { seed_books },
        "requests" => -> { seed_requests },
        "downloads" => -> { seed_downloads },
        "uploads" => -> { seed_uploads },
        "download_clients" => -> { seed_download_clients },
        "acquisition_providers" => -> { seed_acquisition_providers },
        "hardcover_connections" => -> { seed_hardcover_connections },
        "owned_library_connections" => -> { seed_owned_library_connections }
      }
    end

    def ordered_tables
      names = @connection.select_values("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT IN ('schema_migrations', 'ar_internal_metadata')").sort
      parents = names.to_h { |name| [ name, foreign_keys(name).map { |key| key[:table] }.uniq - [ name ] ] }
      ordered = []
      until names.empty?
        ready = names.select { |name| (parents.fetch(name) - ordered).empty? }
        raise "foreign key cycle among released tables" if ready.empty?

        ordered.concat(ready)
        names -= ready
      end
      ordered
    end

    def foreign_keys(table)
      @connection.select_rows("PRAGMA foreign_key_list(#{quote(table)})").map { |row| { table: row[2], from: row[3], to: row[4] } }
    end

    def columns(table)
      @connection.select_rows("PRAGMA table_info(#{quote(table)})").map do |_cid, name, type, notnull, default, key|
        { name: name, type: type.downcase, notnull: notnull == 1, default: default, key: key.positive? }
      end
    end

    def quote(identifier)
      "\"#{identifier}\""
    end

    def count(table)
      @connection.select_value("SELECT COUNT(*) FROM #{quote(table)}")
    end

    def stamp(days = 0, seconds = 0)
      (BASE_TIME + (days * 86_400) + seconds).strftime("%Y-%m-%d %H:%M:%S.%6N")
    end

    def insert(table, values)
      names = values.keys
      @connection.exec_query("INSERT INTO #{quote(table)} (#{names.map { |name| quote(name) }.join(', ')}) VALUES (#{Array.new(names.size, '?').join(', ')})", "seed", values.values)
      @ids[table] << values["id"] if values.key?("id")
    end

    def timestamps(values, days)
      { "created_at" => stamp(days), "updated_at" => stamp(days, 90) }.merge(values)
    end

    def serialize(model, attribute, plaintext)
      return nil if plaintext.nil?

      model.type_for_attribute(attribute).serialize(plaintext)
    end

    def password_digest(username, suffix)
      password = "#{SecureRandom.alphanumeric(14)}Aa1-#{suffix}"
      @passwords[username] = password
      BCrypt::Password.create(password, cost: PASSWORD_COST).to_s
    end

    def seed_users
      codes = Array.new(10) { SecureRandom.alphanumeric(16) }.to_json
      legacy_codes = Array.new(10) { SecureRandom.alphanumeric(16) }.to_json
      legacy = @legacy_context.call { [ serialize(User, "otp_secret", SecureRandom.alphanumeric(32)), serialize(User, "backup_codes", legacy_codes) ] }
      insert("users", timestamps({ "id" => USER_IDS["alice"], "username" => "alice", "name" => "Alice Reader", "role" => 1, "password_digest" => password_digest("alice", "Pässwörd-日本語"),
        "otp_required" => 1, "otp_secret" => serialize(User, "otp_secret", SecureRandom.alphanumeric(32)), "backup_codes" => serialize(User, "backup_codes", codes),
        "telegram_user_id" => "700100200", "telegram_username" => "alice_reads", "telegram_link_token_digest" => Digest::SHA256.hexdigest(SecureRandom.hex(16)),
        "telegram_link_token_created_at" => stamp(-3), "failed_login_count" => 2, "last_failed_login_at" => stamp(-1), "last_failed_login_ip" => "203.0.113.7" }, -60))
      insert("users", timestamps({ "id" => USER_IDS["bob"], "username" => "bob", "name" => "Bob Listener", "role" => 0, "password_digest" => password_digest("bob", "plain"),
        "otp_required" => 1, "otp_secret" => legacy[0], "backup_codes" => legacy[1] }, -45))
      insert("users", timestamps({ "id" => USER_IDS["carol"], "username" => "carol", "name" => "Carol Departed", "role" => 0, "password_digest" => password_digest("carol", "gone"),
        "otp_secret" => serialize(User, "otp_secret", "#{SecureRandom.alphanumeric(8)}-ünicöde-日本"), "deleted_at" => stamp(-10) }, -40))
      insert("users", timestamps({ "id" => USER_IDS["dave"], "username" => "dave", "name" => "Dave Federated", "role" => 0, "password_digest" => password_digest("dave", "oidc"),
        "oidc_provider" => "synthetic-idp", "oidc_uid" => SecureRandom.uuid, "failed_login_count" => 6, "locked_until" => "2099-01-01 00:00:00.000000" }, -30))
      insert("users", { "id" => USER_IDS["erin"], "username" => "erin", "password_digest" => password_digest("erin", "sparse"), "created_at" => stamp(-20), "updated_at" => stamp(-20) })
    end

    def raw_token(label)
      @raw_tokens[label] = "shf_#{SecureRandom.alphanumeric(40)}"
    end

    def token_row(id, label, user, scopes, extra = {})
      raw = raw_token(label)
      insert("api_tokens", timestamps({ "id" => id, "name" => label, "token_digest" => Digest::SHA256.hexdigest(raw), "token_prefix" => raw.first(12),
        "scopes" => scopes.to_json, "user_id" => user }.merge(extra), -25 + id))
    end

    def seed_api_tokens
      token_row(4, "legacy-alice-search", USER_IDS["alice"], %w[search:read requests:read], "last_used_at" => stamp(-2))
      token_row(5, "legacy-admin-service", USER_IDS["alice"], %w[requests:read requests:write requests:admin users:write])
      token_row(6, "legacy-bob-revoked", USER_IDS["bob"], %w[search:read], "revoked_at" => stamp(-5))
      token_row(7, "legacy-bob-expired", USER_IDS["bob"], %w[requests:read], "expires_at" => stamp(-30))
      token_row(8, "legacy-bob-future-expiry", USER_IDS["bob"], %w[requests:read], "expires_at" => "2099-01-01 00:00:00.000000")
      token_row(9, "legacy-carol-deleted-user", USER_IDS["carol"], %w[requests:read])
      token_row(10, "legacy-ownerless", nil, %w[search:read])
      insert("api_tokens", { "id" => 12, "name" => "legacy-sparse", "token_digest" => Digest::SHA256.hexdigest(raw_token("legacy-sparse")), "token_prefix" => "shf_sparse", "created_at" => stamp(-9), "updated_at" => stamp(-9) })
    end

    def seed_settings
      synthetic = -> { "synthetic-#{SecureRandom.hex(16)}" }
      rows = [
        [ "ebook_output_path", @root, "string", "paths" ], [ "audiobook_output_path", @root, "string", "paths" ], [ "comicbook_output_path", @root, "string", "paths" ],
        [ "prowlarr_api_key", synthetic.call, "string", "indexer" ], [ "telegram_bot_token", synthetic.call, "string", "telegram" ],
        [ "oidc_client_secret", synthetic.call, "string", "oidc" ], [ "webhook_token", synthetic.call, "string", "webhook" ],
        [ "hardcover_api_token", synthetic.call, "string", "hardcover" ], [ "audiobookshelf_api_key", synthetic.call, "string", "audiobookshelf" ],
        [ "health_check_interval", "300", "integer", "general" ], [ "oidc_enabled", "true", "boolean", "oidc" ],
        [ "preferred_download_types", '["torrent","usenet"]', "json", "downloads" ], [ "default_request_format", "ask", "string", "general" ],
        [ "indexer_provider", nil, "string", "indexer" ], [ "jackett_url", "", "string", "indexer" ]
      ]
      rows.each_with_index do |(key, value, type, category), index|
        insert("settings", timestamps({ "id" => index + 1, "key" => key, "value" => value, "value_type" => type, "category" => category, "description" => "Synthetic #{key}" }, -50))
      end
    end

    def seed_books
      path = ->(key) { @media.path(key) }
      lorem = "\u{1F4D6}é" * (LONG_DESCRIPTION_LENGTH / 2) + "tail!"
      books = [
        [ "quiet", { "title" => "The Quiet Library", "author" => "A. Reader", "book_type" => 1, "file_path" => path.("quiet"), "description" => "A plain EPUB.", "cover_url" => "https://covers.example.test/quiet.jpg",
          "isbn" => "9780000000002", "year" => 2019, "release_date" => "2019-05-17", "series" => "Quiet Shelf", "series_position" => "1", "publisher" => "Synthetic Press", "hardcover_id" => "hc-5" } ],
        [ "audio", { "title" => "A Listening Life", "author" => "A. Listener", "narrator" => "N. Voice", "book_type" => 0, "file_path" => path.("audio"), "cover_url" => "http://insecure.example.test/audio.jpg" } ],
        [ "tracks", { "title" => "Many Voices", "author" => "B. Narrator", "book_type" => 0, "file_path" => path.("multi-track-directory"), "cover_url" => "https://user:secret@covers.example.test/private.jpg" } ],
        [ "unicode", { "title" => "Café \u{1F4DA} <b>&amp;</b>   \"quoted\"", "author" => "日本語 Author", "book_type" => 1, "file_path" => path.("unicode"), "description" => lorem, "cover_url" => "not a url" } ],
        [ "indirect", { "title" => "Through A Symlink", "author" => "C. Path", "book_type" => 1, "file_path" => @media.stored_path("indirect") } ],
        [ "missing", { "title" => "Gone Missing", "author" => "D. Absent", "book_type" => 1, "file_path" => File.join(@root, "absent.epub") } ],
        [ "outside", { "title" => "Outside The Library", "author" => "E. Elsewhere", "book_type" => 1, "file_path" => path.("outside") } ],
        [ "unacquired", { "title" => "Not Yet Acquired", "author" => "F. Pending", "book_type" => 1, "file_path" => nil, "acquisition_reservation_owner_type" => "Request", "acquisition_reservation_owner_id" => 1, "acquisition_reservation_token" => SecureRandom.hex(16) } ],
        [ "blank-path", { "title" => "Blank Path", "author" => "G. Blank", "book_type" => 1, "file_path" => "   " } ],
        [ "comic", { "title" => "A Comic", "author" => "H. Panel", "book_type" => 2, "content_kind" => 1, "file_path" => path.("comic"), "comic_vine_id" => "cv-1", "issue_number" => "3", "series_start_year" => 1999, "reference_target_roots" => [ @root ].to_json } ],
        [ "uppercase", { "title" => "Loud Extension", "author" => "I. Shout", "book_type" => 1, "file_path" => path.("uppercase") } ],
        [ "library-root", { "title" => "Shares The Root", "author" => "J. Root", "book_type" => 0, "file_path" => @root, "metadata_backfill_checked_at" => stamp(-4) } ]
      ]
      books.each { |key, values| insert("books", timestamps({ "id" => BOOK_IDS.fetch(key) }.merge(values), -35)) }
      insert("books", timestamps({ "id" => DELETED_HIGH_IDS["books"], "title" => "Created And Removed", "book_type" => 1 }, -2))
    end

    def seed_requests
      rows = [
        { "id" => 1, "book_id" => BOOK_IDS["quiet"], "user_id" => USER_IDS["alice"], "status" => 0, "created_via" => "web", "notes" => "Please find this", "retry_count" => 1, "attention_needed" => 1, "search_generation" => 4,
          "completed_at" => stamp(-3), "next_retry_at" => stamp(1), "language" => "en", "request_scope" => "single" },
        { "id" => 2, "book_id" => BOOK_IDS["audio"], "user_id" => USER_IDS["bob"], "status" => 3, "created_via" => "telegram", "external_source" => "telegram", "external_user_id" => "700100200", "external_chat_id" => "-100200300",
          "issue_description" => "Wrong narrator" },
        { "id" => 7, "book_id" => BOOK_IDS["unicode"], "user_id" => USER_IDS["alice"], "status" => 5, "collection_source" => "hardcover", "collection_id" => "series-9", "collection_title" => "Café Collection", "request_scope" => "collection" },
        { "id" => 8, "book_id" => BOOK_IDS["tracks"], "user_id" => USER_IDS["dave"] }
      ]
      rows.each { |row| insert("requests", timestamps(row, -28 + row["id"])) }
      insert("requests", timestamps({ "id" => DELETED_HIGH_IDS["requests"], "book_id" => BOOK_IDS["comic"], "user_id" => USER_IDS["erin"] }, -1))
    end

    def seed_downloads
      rows = [
        { "id" => 1, "request_id" => 1, "status" => 2, "progress" => 45, "name" => "Quiet Library [EPUB] 日本語", "download_type" => "torrent", "external_id" => "abc123", "size_bytes" => 5_000_000_000,
          "download_path" => "/downloads/quiet", "direct_output_root" => @root, "direct_output_root_device" => "18446744073709551615", "direct_output_root_inode" => "9223372036854775808",
          "direct_staging_device" => "2049", "direct_staging_inode" => "131077", "direct_staging_parent_device" => "2049", "direct_staging_parent_inode" => "131073", "direct_staging_path" => File.join(@root, ".staging", "quiet"),
          "direct_reservation_token" => SecureRandom.hex(16), "direct_publication_kind" => "file", "direct_destination_path" => File.join(@root, "Quiet.epub"), "not_found_count" => 2,
          "replace_library_file" => 1, "library_replacement_state" => { "phase" => "staged" }.to_json, "post_processing_cleanup_state" => { "pending" => [ "tmp" ] }.to_json, "configuration_failure" => 1,
          "direct_content_manifest" => { "files" => [ "a.epub" ] }.to_json, "external_id_released_at" => stamp(-1) },
        { "id" => 3, "request_id" => 2, "status" => 4, "size_bytes" => (2**62), "download_client_id" => "3", "name" => "A Listening Life" },
        { "id" => 4, "request_id" => 7 }
      ]
      rows.each { |row| insert("downloads", timestamps(row, -20 + row["id"])) }
    end

    def seed_uploads
      rows = [
        { "id" => 1, "user_id" => USER_IDS["alice"], "book_id" => BOOK_IDS["quiet"], "request_id" => 1, "status" => 2, "original_filename" => "Quiet Library.epub", "file_path" => File.join(@root, "Quiet.epub"),
          "file_size" => 4_800_000_000, "content_sha256" => Digest::SHA256.hexdigest("synthetic upload one"), "content_type" => "application/epub+zip", "book_type" => 1, "parsed_title" => "Quiet Library", "parsed_author" => "A. Reader",
          "match_confidence" => 92, "processed_at" => stamp(-6), "destination_path" => File.join(@root, "Quiet.epub"), "library_path" => File.join(@root, "Quiet.epub"), "destination_root" => @root, "destination_configured_root" => @root,
          "manual_match" => 1, "manual_match_created_book" => 1, "book_reservation_created_book" => 1, "book_reservation_token" => SecureRandom.hex(16), "cleanup_source_path" => "/uploads/in/quiet.epub", "error_message" => "No error; synthetic" },
        { "id" => 2, "user_id" => USER_IDS["bob"] }
      ]
      rows.each { |row| insert("uploads", timestamps(row, -15 + row["id"])) }
    end

    def seed_download_clients
      key = "#{SecureRandom.alphanumeric(40)}-#{'é日' * 80}"
      insert("download_clients", timestamps({ "id" => DOWNLOAD_CLIENT_IDS["primary"], "name" => "Synthetic Client", "client_type" => "sabnzbd", "url" => "http://127.0.0.1:9", "username" => "synthetic",
        "password" => serialize(DownloadClient, "password", ""), "api_key" => serialize(DownloadClient, "api_key", key), "category" => "books", "download_path" => "/downloads", "priority" => 3,
        "torrent_verification_max_attempts" => 7, "torrent_verification_wait_time" => 5 }, -55))
      insert("download_clients", timestamps({ "id" => DOWNLOAD_CLIENT_IDS["optional-state-absent"], "name" => "Bare Client", "client_type" => "qbittorrent", "url" => "http://127.0.0.1:10", "enabled" => 0 }, -54))
    end

    def seed_acquisition_providers
      insert("acquisition_providers", timestamps({ "id" => 2, "name" => "Synthetic Provider", "url" => "https://provider.example.test", "api_key" => serialize(AcquisitionProvider, "api_key", SecureRandom.hex(20)),
        "priority" => 1, "timeout_seconds" => 45, "allow_private_network" => 1, "supports_comicbooks" => 1 }, -52))
      insert("acquisition_providers", timestamps({ "id" => 5, "name" => "Keyless Provider", "url" => "https://keyless.example.test" }, -51))
    end

    def seed_hardcover_connections
      insert("hardcover_connections", timestamps({ "id" => 1, "user_id" => USER_IDS["alice"], "auth_method" => "oauth", "hardcover_user_id" => 4242, "hardcover_username" => "alice-hc",
        "access_token" => serialize(HardcoverConnection, "access_token", SecureRandom.hex(24)), "refresh_token" => serialize(HardcoverConnection, "refresh_token", SecureRandom.hex(24)),
        "access_token_expires_at" => stamp(2), "granted_scopes" => "library", "last_verified_at" => stamp(-1), "refreshed_at" => stamp(-1), "lock_version" => 3 }, -40))
      insert("hardcover_connections", timestamps({ "id" => 2, "user_id" => USER_IDS["bob"], "auth_method" => "personal_token", "hardcover_user_id" => 77,
        "access_token" => serialize(HardcoverConnection, "access_token", SecureRandom.hex(24)), "status" => "reauthorization_required", "last_error" => "expired" }, -39))
    end

    def seed_owned_library_connections
      insert("owned_library_connections", timestamps({ "id" => 1, "provider" => "libation", "name" => "Synthetic Libation", "url" => "http://shelfarr-libation:8080",
        "bridge_token" => serialize(OwnedLibraryConnection, "bridge_token", SecureRandom.hex(20)), "auth_session_id" => serialize(OwnedLibraryConnection, "auth_session_id", SecureRandom.hex(20)),
        "auth_login_url" => serialize(OwnedLibraryConnection, "auth_login_url", "https://login.example.test/#{SecureRandom.hex(8)}"), "enabled" => 1, "sync_status" => "failed",
        "last_sync_error" => "synthetic failure", "automatic_backup_user_id" => USER_IDS["alice"] }, -38))
    end

    def fill_generic(table)
      2.times do |index|
        row = generic_row(table, index + 1, sparse: index == 1)
        next if row.nil?

        insert(table, row)
      end
    end

    def generic_row(table, ordinal, sparse:)
      keys = foreign_keys(table).to_h { |key| [ key[:from], key ] }
      row = {}
      columns(table).each do |column|
        name = column[:name]
        next if column[:key] && name != "id"
        next if sparse && !(column[:notnull] && column[:default].nil?) && name != "id"

        row[name] = generic_value(table, column, ordinal, keys[name])
      end
      row
    end

    def generic_value(table, column, ordinal, foreign_key)
      name = column[:name]
      return ordinal + 20 if name == "id"
      return parent_id(foreign_key, ordinal) if foreign_key
      return stamp(-ordinal * 3) if column[:type].start_with?("datetime")
      return "2026-03-0#{ordinal}" if column[:type] == "date"

      case column[:type]
      when "boolean" then column[:default] == "1" ? 0 : 1
      when "integer", "bigint" then ordinal + 1
      when "float", "real" then 12.5 * ordinal
      when "json" then { "synthetic" => true, "table" => table }.to_json
      when "blob", "binary" then "synthetic-#{table}-#{name}-#{ordinal}".b
      else "synthetic #{table} #{name} #{ordinal}"
      end
    end

    def parent_id(foreign_key, ordinal)
      parents = @ids[foreign_key[:table]]
      raise "no seeded parent for a foreign key" if parents.empty?

      parents[(ordinal - 1) % parents.size]
    end

    def remove_high_id(table, id)
      @connection.exec_query("DELETE FROM #{quote(table)} WHERE id = ?", "seed", [ id ])
    end
  end
end
