# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "json"
require "securerandom"
require "shellwords"
require "time"
require "zlib"
require_relative "fixture_media"

module Migration
  class FixtureBuilder
    FORMAT_VERSION = 1
    LONG_DESCRIPTION_LENGTH = 20_005
    PROGRESS_UPDATED_AT = Time.utc(2026, 11, 13, 8, 30, 15, 123_987)
    PROGRESS_OBSERVED_AT = Time.utc(2026, 11, 13, 8, 29, 59, 999_500)
    PRE_EPOCH_OBSERVED_AT = Time.utc(1969, 12, 31, 23, 59, 59, 999_500)
    STATE_UPDATED_AT = Time.utc(2026, 11, 14, 1, 2, 3)
    EXPIRED_AT = Time.utc(2020, 1, 1)
    DISTANT_EXPIRY = Time.utc(2099, 1, 1)
    StatDouble = Struct.new(:dev, :ino, :size, :mtime, :ctime)

    def initialize(paths:, repo_root:)
      @paths = paths
      @repo_root = repo_root
      @users = {}
      @credentials = { "users" => {}, "tokens" => {} }
      @expected = {}
    end

    def call
      ActiveJob::Base.queue_adapter = :test
      configure_encryption
      load_schema
      @media = FixtureMedia.new(@paths).build
      seed_settings
      seed_users
      seed_books
      seed_progress
      seed_encrypted_rows
      seed_tokens
      record_identity_vectors
      record_assets
      record_accounts
      record_encryption
      record_responses
      seed_adopting_token
      finalize_database
      write_outputs
    end

    private

    def configure_encryption
      @keys = {
        "primary_key" => SecureRandom.base64(32),
        "deterministic_key" => SecureRandom.base64(32),
        "key_derivation_salt" => SecureRandom.base64(32)
      }
      ActiveRecord::Encryption.configure(
        primary_key: @keys["primary_key"], deterministic_key: @keys["deterministic_key"],
        key_derivation_salt: @keys["key_derivation_salt"], hash_digest_class: OpenSSL::Digest::SHA256,
        support_sha1_for_non_deterministic_encryption: true
      )
      @credentials["encryption"] = @keys.merge("hash_digest" => "sha256", "legacy_hash_digest" => "sha1")
    end

    def load_schema
      ActiveRecord::Migration.verbose = false
      load File.join(@repo_root, "db", "schema.rb")
      @schema_version = ActiveRecord::Base.connection_pool.migration_context.current_version
    end

    def seed_settings
      %i[ebook_output_path audiobook_output_path comicbook_output_path].each { |key| SettingsService.set(key, @paths.media) }
      @root = File.realpath(@paths.media)
    end

    def random_password(suffix)
      "#{SecureRandom.alphanumeric(14)}Aa1-#{suffix}"
    end

    def seed_users
      ActiveModel::SecurePassword.min_cost = false
      definitions = {
        "alice" => { name: "Alice Reader", suffix: "Pässwörd-日本語" },
        "bob" => { name: "Bob Listener", suffix: "plain" },
        "carol" => { name: "Carol Departed", suffix: "gone" }
      }
      definitions.each do |username, definition|
        password = random_password(definition[:suffix])
        @users[username] = User.create!(username: username, name: definition[:name], password: password)
        @credentials["users"][username] = { "password" => password, "candidates" => password_candidates(password) }
      end
      @users["carol"].update_columns(deleted_at: Time.utc(2026, 11, 1))
    end

    def password_candidates(password)
      [
        { "label" => "correct", "value" => password },
        { "label" => "other-random", "value" => random_password("wrong") },
        { "label" => "empty", "value" => "" },
        { "label" => "trailing-space", "value" => "#{password} " },
        { "label" => "swapped-case", "value" => password.swapcase },
        { "label" => "nfd-form", "value" => password.unicode_normalize(:nfd) }
      ]
    end

    def create_book(key, **attributes)
      @books[key] = Book.create!(attributes)
    end

    def seed_books
      @books = {}
      m = @media
      create_book("quiet", title: "The Quiet Library", author: "A. Reader", book_type: :ebook, file_path: m.path("quiet"),
        description: "A plain EPUB.", cover_url: "https://covers.example.test/quiet.jpg")
      create_book("audio", title: "A Listening Life", author: "A. Listener", book_type: :audiobook, file_path: m.path("audio"),
        description: nil, cover_url: "http://insecure.example.test/audio.jpg")
      create_book("tracks", title: "Many Voices", author: "B. Narrator", book_type: :audiobook, file_path: m.path("multi-track-directory"),
        cover_url: "https://user:secret@covers.example.test/private.jpg")
      create_book("unicode", title: "Café \u{1F4DA} <b>&amp;</b>   \"quoted\"", author: "日本語 Author", book_type: :ebook,
        file_path: m.path("unicode"), description: long_description, cover_url: "not a url")
      create_book("indirect", title: "Through A Symlink", author: "C. Path", book_type: :ebook, file_path: m.stored_path("indirect"))
      create_book("missing", title: "Gone Missing", author: "D. Absent", book_type: :ebook, file_path: File.join(@root, "absent.epub"))
      create_book("outside", title: "Outside The Library", author: "E. Elsewhere", book_type: :ebook, file_path: m.path("outside"))
      create_book("unacquired", title: "Not Yet Acquired", author: "F. Pending", book_type: :ebook, file_path: nil)
      create_book("blank-path", title: "Blank Path", author: "G. Blank", book_type: :ebook, file_path: "   ")
      create_book("comic", title: "A Comic", author: "H. Panel", book_type: :comicbook, file_path: m.path("comic"))
      create_book("uppercase", title: "Loud Extension", author: "I. Shout", book_type: :ebook, file_path: m.path("uppercase"))
      create_book("library-root", title: "Shares The Root", author: "J. Root", book_type: :audiobook, file_path: @root)
    end

    def long_description
      "\u{1F4D6}é" * (LONG_DESCRIPTION_LENGTH / 2) + "tail!"
    end

    def asset_id(key)
      Consumer::LibraryAssets.new(@books.fetch(key)).list.first.id
    end

    def seed_progress
      alice = @users["alice"]
      bob = @users["bob"]
      locator = { "href" => "OEBPS/chapter.xhtml", "type" => "application/xhtml+xml", "locations" => { "progression" => 0.5, "position" => 3 } }
      ConsumerProgress.create!(user: alice, book: @books["quiet"], asset_id: asset_id("quiet"), locator: locator, position_seconds: nil,
        version: 3, client_mutation_id: "alice-quiet-3", observed_at: PROGRESS_OBSERVED_AT, created_at: PROGRESS_UPDATED_AT, updated_at: PROGRESS_UPDATED_AT)
      ConsumerProgress.create!(user: alice, book: @books["audio"], asset_id: asset_id("audio"), locator: nil, position_seconds: 17.5,
        version: 1, client_mutation_id: "alice-audio-1", observed_at: nil, created_at: PROGRESS_UPDATED_AT, updated_at: PROGRESS_UPDATED_AT)
      ConsumerProgress.create!(user: bob, book: @books["quiet"], asset_id: asset_id("quiet"),
        locator: { "href" => "OEBPS/chapter.xhtml", "locations" => { "progression" => 0.125 } }, position_seconds: nil,
        version: 7, client_mutation_id: "bob-quiet-7", observed_at: PRE_EPOCH_OBSERVED_AT, created_at: PROGRESS_UPDATED_AT, updated_at: Time.utc(1969, 12, 31, 23, 59, 59, 250_000))
      ConsumerProgress.create!(user: bob, book: @books["unicode"], asset_id: asset_id("unicode"), locator: { "href" => "OEBPS/chapter.xhtml", "locations" => { "position" => 1 } },
        position_seconds: nil, version: 2, client_mutation_id: "bob-unicode-2", observed_at: nil, created_at: PROGRESS_UPDATED_AT, updated_at: PROGRESS_UPDATED_AT)
      ConsumerReadingState.create!(user: alice, book: @books["tracks"], status: :finished, created_at: STATE_UPDATED_AT, updated_at: STATE_UPDATED_AT)
      ConsumerReadingState.create!(user: alice, book: @books["audio"], status: :unread, created_at: STATE_UPDATED_AT, updated_at: STATE_UPDATED_AT)
      ConsumerReadingState.create!(user: bob, book: @books["quiet"], status: :in_progress, created_at: STATE_UPDATED_AT, updated_at: STATE_UPDATED_AT)
    end

    def legacy_context
      generator = ActiveRecord::Encryption::KeyGenerator.new(hash_digest_class: OpenSSL::Digest::SHA1)
      provider = ActiveRecord::Encryption::DerivedSecretKeyProvider.new(@keys["primary_key"], key_generator: generator)
      ActiveRecord::Encryption.with_encryption_context(key_provider: provider) { yield }
    end

    def seed_encrypted_rows
      @encrypted_plain = {}
      codes = Array.new(10) { SecureRandom.alphanumeric(16) }
      @users["alice"].update!(otp_required: true, otp_secret: SecureRandom.alphanumeric(32), backup_codes: codes.to_json)
      legacy_context do
        @users["bob"].update!(otp_required: true, otp_secret: SecureRandom.alphanumeric(32), backup_codes: Array.new(10) { SecureRandom.alphanumeric(16) }.to_json)
      end
      @users["carol"].update!(otp_secret: "#{SecureRandom.alphanumeric(8)}-ünicöde-日本")
      @client = DownloadClient.create!(name: "Synthetic Client", client_type: "sabnzbd", url: "http://127.0.0.1:9", username: "synthetic",
        password: "", api_key: "#{SecureRandom.alphanumeric(40)}-#{'é日'.then { |text| text * 80 }}")
    end

    def seed_tokens
      scopes = ConsumerDeviceGrant::SCOPES
      @raw = {}
      issue("alice-full", @users["alice"], scopes)
      issue("alice-progress-only", @users["alice"], [ "progress:write" ])
      issue("alice-revoked", @users["alice"], scopes)
      @tokens["alice-revoked"].revoke!
      issue("alice-expired", @users["alice"], scopes, expires_at: EXPIRED_AT)
      issue("alice-future-expiry", @users["alice"], scopes, expires_at: DISTANT_EXPIRY)
      issue("bob-full", @users["bob"], scopes)
      issue("carol-deleted-user", @users["carol"], scopes)
      issue("alice-previous", @users["alice"], scopes)
      @credentials["tokens"] = @raw
    end

    def issue(label, user, scopes, expires_at: nil, replaces: nil)
      @tokens ||= {}
      token, raw = APIToken.issue!(name: label, user: user, scopes: scopes, expires_at: expires_at, issued_via: APIToken::CONSUMER_DEVICE, replaces: replaces)
      @tokens[label] = token
      @raw[label] = raw
    end

    def seed_adopting_token
      issue("alice-adopting", @users["alice"], ConsumerDeviceGrant::SCOPES, replaces: @tokens["alice-previous"])
      @credentials["tokens"] = @raw
      @expected["responses"]["refusals"] = [
        { "name" => "me-alice-adopting-token", "path" => "/api/consumer/v1/me", "token" => "alice-adopting", "go_outcome" => "unsupported_token_adoption" }
      ]
    end

    def record_identity_vectors
      vectors = identity_vector_inputs.map do |input|
        book = Book.new(id: input[:book_id], file_path: input[:file_path])
        stat = StatDouble.new(input[:dev], input[:ino], input[:size], Time.at(input[:mtime]), Time.at(input[:ctime]))
        id = Consumer::LibraryAssets.new(book).send(:identity, stat, input[:path])
        {
          "name" => input[:name], "book_id" => input[:book_id].to_s, "file_path" => input[:file_path], "path" => input[:path],
          "device" => input[:dev].to_s, "inode" => input[:ino].to_s, "size" => input[:size].to_s,
          "mtime" => input[:mtime].to_s, "ctime" => input[:ctime].to_s, "id" => id
        }
      end
      @expected["identity_vectors"] = { "vectors" => vectors }
    end

    def identity_vector_inputs
      base = { book_id: 42, file_path: "/lib/A.epub", path: "/lib/A.epub", dev: 2049, ino: 131_077, size: 1024, mtime: Rational(1_700_000_000), ctime: Rational(1_700_000_100) }
      [
        base.merge(name: "whole-second-times"),
        base.merge(name: "nanosecond-fraction", mtime: Rational(1_700_000_000_123_456_789, 1_000_000_000), ctime: Rational(1_700_000_100_000_000_001, 1_000_000_000)),
        base.merge(name: "pre-epoch-half-second", mtime: Rational(-3, 2), ctime: Rational(-1, 1_000_000_000)),
        base.merge(name: "pre-epoch-third", mtime: Rational(-7, 3), ctime: Rational(1, 3)),
        base.merge(name: "zero-times", mtime: Rational(0), ctime: Rational(0)),
        base.merge(name: "unsigned-high-bit-device-inode", dev: 2**63, ino: 2**64 - 1),
        base.merge(name: "unsigned-just-below-high-bit", dev: 2**63 - 1, ino: 2**63 - 1),
        base.merge(name: "zero-size-and-large-size", size: 0),
        base.merge(name: "size-above-32-bit", size: 5_000_000_000),
        base.merge(name: "maximum-book-id", book_id: 2**63 - 1),
        base.merge(name: "stored-path-differs-from-canonical", file_path: "/lib//alias/./x/../A.epub"),
        base.merge(name: "unicode-paths", file_path: "/lib/Café 日本.epub", path: "/lib/real/Café 日本.epub"),
        base.merge(name: "path-with-spaces-and-newline", file_path: "/lib/a b\nc.epub", path: "/lib/a b\nc.epub")
      ]
    end

    def record_assets
      records = @books.map do |key, book|
        assets = begin
          Consumer::LibraryAssets.new(book).list
        rescue Consumer::LibraryAssets::Unavailable
          nil
        end
        { "key" => key, "book_id" => book.id.to_s, "unavailable" => assets.nil?, "assets" => Array(assets).map { |asset| asset_record(book, asset) } }
      end
      @expected["library_assets"] = { "books" => records }
    end

    def asset_record(book, asset)
      stat = File.stat(asset.path)
      recomputed = Consumer::LibraryAssets.new(book).send(:identity, StatDouble.new(stat.dev, stat.ino, stat.size, stat.mtime, stat.ctime), asset.path)
      raise "recorded stat disagrees with the Rails identity for book #{book.id}" unless recomputed == asset.id

      {
        "id" => asset.id, "path" => asset.path, "root" => asset.root, "filename" => asset.filename, "format" => asset.format,
        "media_type" => asset.media_type, "size_bytes" => asset.size_bytes, "position" => asset.position,
        "device" => stat.dev.to_s, "inode" => stat.ino.to_s, "size" => stat.size.to_s,
        "mtime" => stat.mtime.to_r.to_s, "ctime" => stat.ctime.to_r.to_s
      }
    end

    def record_accounts
      accounts = @users.map do |username, user|
        results = @credentials["users"][username]["candidates"].to_h { |candidate| [ candidate["label"], user.authenticate(candidate["value"]) ? true : false ] }
        { "username" => username, "id" => user.id.to_s, "name" => user.name, "deleted" => !user.deleted_at.nil?, "digest_prefix" => user.password_digest[0, 4], "authenticate" => results }
      end
      @expected["accounts"] = { "accounts" => accounts }
    end

    def plaintext_record(model, column, record, scheme)
      fresh = model.find(record.id)
      value = fresh.public_send(column)
      raw = fresh.public_send(:"#{column}_before_type_cast")
      entry = { "table" => model.table_name, "column" => column.to_s, "id" => record.id.to_s, "scheme" => scheme }
      return entry.merge("null" => true) if raw.nil?

      headers = JSON.parse(raw)["h"]
      entry.merge("null" => false, "compressed" => headers["c"] == true, "plaintext_sha256" => Digest::SHA256.hexdigest(value), "plaintext_bytes" => value.bytesize)
    end

    def record_encryption
      columns = [
        plaintext_record(User, :otp_secret, @users["alice"], "current"),
        plaintext_record(User, :backup_codes, @users["alice"], "current"),
        plaintext_record(User, :otp_secret, @users["bob"], "legacy-sha1"),
        plaintext_record(User, :backup_codes, @users["bob"], "legacy-sha1"),
        plaintext_record(User, :otp_secret, @users["carol"], "current"),
        plaintext_record(User, :backup_codes, @users["carol"], "current"),
        plaintext_record(DownloadClient, :password, @client, "current"),
        plaintext_record(DownloadClient, :api_key, @client, "current")
      ]
      @expected["encryption"] = { "columns" => columns, "tampered" => tampered_cases }
    end

    def tampered_cases
      fresh = User.find(@users["alice"].id)
      plain = JSON.parse(fresh.otp_secret_before_type_cast)
      compressed = JSON.parse(fresh.backup_codes_before_type_cast)
      variants = {
        "payload-bit-flip" => mutate(plain) { |m| m["p"] = flip_base64(m["p"]) },
        "iv-bit-flip" => mutate(plain) { |m| m["h"]["iv"] = flip_base64(m["h"]["iv"]) },
        "auth-tag-bit-flip" => mutate(plain) { |m| m["h"]["at"] = flip_base64(m["h"]["at"]) },
        "auth-tag-missing" => mutate(plain) { |m| m["h"].delete("at") },
        "auth-tag-short" => mutate(plain) { |m| m["h"]["at"] = Base64.strict_encode64(Base64.strict_decode64(m["h"]["at"])[0, 8]) },
        "payload-truncated" => mutate(plain) { |m| m["p"] = Base64.strict_encode64(Base64.strict_decode64(m["p"])[0..-2]) },
        "compressed-payload-bit-flip" => mutate(compressed) { |m| m["p"] = flip_base64(m["p"]) },
        "compression-flag-forced-on-plain-payload" => mutate(plain) { |m| m["h"]["c"] = true },
        "compression-flag-removed-from-compressed-payload" => mutate(compressed) { |m| m["h"].delete("c") },
        "invalid-base64-payload" => mutate(plain) { |m| m["p"] = "!!!not-base64!!!" },
        "envelope-truncated-json" => JSON.generate(plain)[0, 40],
        "not-an-envelope" => "plain text in an encrypted column",
        "json-without-payload" => '{"h":{}}',
        "empty-string" => ""
      }
      variants.map { |name, envelope| tamper_record(name, envelope) }
    end

    def mutate(message)
      copy = JSON.parse(JSON.generate(message))
      yield copy
      JSON.generate(copy)
    end

    def flip_base64(value)
      bytes = Base64.strict_decode64(value).bytes
      bytes[0] ^= 0x01
      Base64.strict_encode64(bytes.pack("C*"))
    end

    def tamper_record(name, envelope)
      type = User.type_for_attribute("otp_secret")
      result = begin
        value = type.deserialize(envelope)
        { "outcome" => "ok", "plaintext_sha256" => Digest::SHA256.hexdigest(value.to_s) }
      rescue ActiveRecord::Encryption::Errors::Base, Zlib::Error, EncodingError => error
        { "outcome" => "error", "rails_class" => error.class.name, "category" => category(error) }
      end
      { "name" => name, "envelope" => envelope }.merge(result)
    end

    def category(error)
      case error
      when ActiveRecord::Encryption::Errors::Encoding then "encoding"
      when ActiveRecord::Encryption::Errors::Decryption, ActiveRecord::Encryption::Errors::EncryptedContentIntegrity then "decryption"
      when Zlib::Error then "decompression"
      else "other"
      end
    end

    def http
      @http ||= ActionDispatch::Integration::Session.new(Rails.application)
    end

    def capture(name, path, token)
      headers = token ? { "Authorization" => "Bearer #{@raw.fetch(token)}" } : {}
      http.get(path, headers: headers)
      status = http.response.status
      body = http.response.body
      compare = case status
      when 401 then "empty"
      when 404 then "status"
      else "json"
      end
      { "name" => name, "path" => path, "token" => token, "status" => status, "cache_control" => http.response.headers["Cache-Control"],
        "compare" => compare, "body" => compare == "json" ? JSON.parse(body) : nil, "body_bytes" => body.bytesize }
    end

    def record_responses
      cases = []
      prefix = "/api/consumer/v1"
      %w[alice-full alice-future-expiry bob-full alice-progress-only alice-revoked alice-expired carol-deleted-user].each do |label|
        cases << capture("me-#{label}", "#{prefix}/me", label)
      end
      cases << capture("me-no-token", "#{prefix}/me", nil)
      %w[alice-full bob-full alice-progress-only carol-deleted-user].each do |label|
        cases << capture("library-#{label}", "#{prefix}/library", label)
      end
      %w[alice-full bob-full].each do |label|
        @books.each { |key, book| cases << capture("publication-#{key}-#{label}", "#{prefix}/library/#{book.id}", label) }
        %w[0 01 999999 abc].each { |id| cases << capture("publication-id-#{id}-#{label}", "#{prefix}/library/#{id}", label) }
      end
      @expected["responses"] = { "cases" => cases }
    end

    def finalize_database
      @expected["now"] = Time.now.utc.iso8601
      ActiveRecord::Base.with_connection { |connection| connection.execute("PRAGMA wal_checkpoint(TRUNCATE)") }
      ActiveRecord::Base.connection_handler.clear_all_connections!
      leftovers = Dir.glob("#{@paths.primary_db}-*")
      raise "database sidecars remain: #{leftovers.map { |file| File.basename(file) }.join(', ')}" unless leftovers.empty?
    end

    def write_json(path, value, mode: 0o600)
      File.write(path, JSON.pretty_generate(value) << "\n", perm: mode)
      File.chmod(mode, path)
    end

    def write_outputs
      write_json(File.join(@paths.secrets, "credentials.json"), @credentials)
      FileUtils.chmod(0o700, @paths.secrets)
      @expected.slice("identity_vectors", "library_assets", "accounts", "encryption", "responses").each do |name, value|
        write_json(File.join(@paths.expected, "#{name.tr('_', '-')}.json"), value, mode: 0o640)
      end
      FileUtils.rm_rf(File.join(@paths.out, "scratch"))
      write_json(File.join(@paths.out, "manifest.json"), manifest, mode: 0o640)
    end

    def case_names
      names = []
      names += @expected["identity_vectors"]["vectors"].map { |vector| "identity:#{vector['name']}" }
      names += @expected["library_assets"]["books"].map { |book| "assets:#{book['key']}" }
      @expected["accounts"]["accounts"].each do |account|
        names += account["authenticate"].keys.map { |label| "password:#{account['username']}:#{label}" }
      end
      names += @expected["encryption"]["columns"].map { |column| "column:#{column['table']}.#{column['column']}.#{column['id']}" }
      names += @expected["encryption"]["tampered"].map { |entry| "tamper:#{entry['name']}" }
      names += @expected["responses"]["cases"].map { |entry| "response:#{entry['name']}" }
      names += @expected["responses"]["refusals"].map { |entry| "refusal:#{entry['name']}" }
      names.sort
    end

    def manifest
      {
        "fixture_format" => FORMAT_VERSION,
        "origin" => "current-schema",
        "producer" => { "ruby" => RUBY_VERSION, "rails" => Rails.version, "repository_head" => repository_head },
        "schema" => { "revision" => @schema_version.to_s, "path" => "db/schema.rb" },
        "media_root" => @root,
        "database" => { "path" => "db/primary.sqlite3" },
        "now_at_capture" => @expected["now"],
        "coverage" => coverage,
        "files" => file_hashes,
        "external_trees" => external_trees
      }
    end

    def coverage
      names = case_names
      {
        "cases" => names,
        "digest" => Digest::SHA256.hexdigest(names.join("\n")),
        "gaps" => [
          { "id" => "stable-volume-upgrade", "status" => "missing", "detail" => "fixture is built from the current schema, not migrated from a released stable volume" },
          { "id" => "catalogue-pagination", "status" => "missing", "detail" => "cursor encoding is not read" },
          { "id" => "token-adoption", "status" => "missing", "detail" => "replacement tokens are refused, not adopted" },
          { "id" => "reference-imports", "status" => "missing", "detail" => "symbolic-link library entries are refused" },
          { "id" => "pdf-cbz-assets", "status" => "missing", "detail" => "only the default EPUB and audio asset listing is covered" }
        ]
      }
    end

    def repository_head
      `git -C #{Shellwords.escape(@repo_root)} rev-parse HEAD 2>/dev/null`.strip
    end

    def file_hashes
      root = @paths.out
      external = external_roots
      Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.filter_map do |path|
        next unless File.file?(path) && !File.symlink?(path)
        next if external.any? { |tree| path.start_with?("#{tree}/") }

        relative = path.delete_prefix("#{root}/")
        next if relative == "manifest.json"

        [ relative, hash_entry(path) ]
      end.to_h
    end

    def external_roots
      [ @paths.media, File.join(@paths.out, "outside") ]
    end

    def external_trees
      external_roots.map do |root|
        entries = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.reject { |path| %w[. ..].include?(File.basename(path)) }
        files = entries.select { |path| File.file?(path) && !File.symlink?(path) }.to_h { |path| [ path.delete_prefix("#{root}/"), hash_entry(path) ] }
        symlinks = entries.select { |path| File.symlink?(path) }.to_h { |path| [ path.delete_prefix("#{root}/"), File.readlink(path) ] }
        { "name" => File.basename(root), "root" => root, "files" => files, "symlinks" => symlinks }
      end
    end

    def hash_entry(path)
      { "sha256" => Digest::SHA256.file(path).hexdigest, "size" => File.size(path) }
    end
  end
end
