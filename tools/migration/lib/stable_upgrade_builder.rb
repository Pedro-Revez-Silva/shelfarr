# frozen_string_literal: true

require_relative "fixture_builder"
require_relative "stable_upgrade"

module Migration
  class StableUpgradeBuilder < FixtureBuilder
    EVIDENCE_FILE = "stable-upgrade.json"
    LEGACY_TOKEN_LABELS = %w[legacy-alice-search legacy-admin-service legacy-bob-revoked legacy-bob-expired legacy-bob-future-expiry legacy-carol-deleted-user legacy-ownerless legacy-sparse].freeze
    MAX_LISTED_CHANGES = 200

    def prepare_run(**options)
      ActiveJob::Base.queue_adapter = :test
      configure_encryption
      @media = FixtureMedia.new(@paths).build
      @root = File.realpath(@paths.media)
      StableUpgrade::Run.new(paths: @paths, repo_root: @repo_root, root: @root, media: @media, legacy_context: method(:legacy_context), **options)
    end

    def call
      @run = prepare_run
      @upgrade = upgrade
      adopt_preserved_records
      seed_progress
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

    def upgrade
      outcome = @run.call
      @run.repeat_is_safe(outcome.after)
      @schema_version = ActiveRecord::Base.connection_pool.migration_context.current_version
      outcome
    end

    def adopt_preserved_records
      @users = ReleasedRecords::USER_IDS.to_h { |name, id| [ name, User.find(id) ] }
      @books = ReleasedRecords::BOOK_IDS.to_h { |key, id| [ key, Book.find(id) ] }
      @client = DownloadClient.find(ReleasedRecords::DOWNLOAD_CLIENT_IDS.fetch("primary"))
      passwords = @run.records.passwords
      @credentials["users"] = passwords.to_h { |username, password| [ username, { "password" => password, "candidates" => password_candidates(password) } ] }
      @raw = @run.records.raw_tokens.dup
    end

    def record_responses
      super
      prefix = "/api/consumer/v1"
      LEGACY_TOKEN_LABELS.each do |label|
        @expected["responses"]["cases"] << capture("me-#{label}", "#{prefix}/me", label)
        @expected["responses"]["cases"] << capture("library-#{label}", "#{prefix}/library", label)
      end
    end

    def origin
      "stable-upgrade"
    end

    def coverage
      base = super
      base.merge("gaps" => base["gaps"].map { |gap| gap["id"] == "stable-volume-upgrade" ? stable_gap : gap })
    end

    def stable_gap
      { "id" => "stable-volume-upgrade", "status" => "partial", "detail" => "the primary database of #{ReleaseSource::TAG} was upgraded by the shipped migrations; the volume, queue, cable and cache databases, queued jobs, keys and rollback are not covered" }
    end

    def write_outputs
      write_json(File.join(@paths.expected, EVIDENCE_FILE), evidence, mode: 0o640)
      super
    end

    def evidence
      final = DatabaseSnapshot.read(@paths.primary_db)
      {
        "release" => @upgrade.release.provenance,
        "schema" => { "before_revision" => ReleaseSource::SCHEMA_VERSION, "after_revision" => @schema_version.to_s, "released_dump_sha256" => @upgrade.schema_before, "upgraded_dump_sha256" => @upgrade.schema_after },
        "migrations_applied" => @upgrade.applied,
        "source" => { "file" => "db/#{StableUpgrade::SOURCE_FILE}", "sha256" => @upgrade.source_sha256, "snapshot_sha256" => @upgrade.before.digest, "rows" => @upgrade.before.tables.sum { |_, table| table.rows.size } },
        "preserved" => @upgrade.counts,
        "verified_upgrade_sha256" => @upgrade.after.digest,
        "post_upgrade" => post_upgrade(final)
      }
    end

    def post_upgrade(final)
      verified = @upgrade.after
      additions = final.tables.to_h { |name, table| [ name, table.rows.size - (verified.tables[name]&.rows&.size || 0) ] }.reject { |_, added| added.zero? }
      changes = changed_rows(verified, final)
      { "rows_added" => additions, "preserved_rows_changed" => changes.first(MAX_LISTED_CHANGES), "preserved_rows_changed_total" => changes.size }
    end

    def changed_rows(verified, final)
      verified.tables.flat_map do |name, table|
        table.rows.filter_map do |key, row|
          current = final.tables.fetch(name).rows[key]
          columns = row.keys.reject { |column| current && current[column] == row[column] }
          { "table" => name, "key" => key, "columns" => columns } unless columns.empty?
        end
      end
    end
  end
end
