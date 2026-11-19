# frozen_string_literal: true

require "optparse"
require "json"
require "fileutils"
require "sqlite3"
require_relative "../lib/producer_boot"

REPO_ROOT = File.expand_path("../../..", __dir__)
CREATE_PATH = "/api/consumer/v1/requests"

options = {}
OptionParser.new do |parser|
  parser.banner = "Usage: verify_request_admission.rb --bundle PATH --evidence PATH --out NEW_PATH"
  %w[bundle evidence out].each { |name| parser.on("--#{name} PATH") { |value| options[name.to_sym] = value } }
end.parse!
%i[bundle evidence out].each { |name| abort "refused: --#{name} is required" unless options[name] }

begin
  paths = Migration::ProducerBoot.call(out: options[:out], repo_root: REPO_ROOT)
rescue Migration::FixtureIsolation::Refused => error
  warn "refused: #{error.message}"
  exit 2
end

require "webmock"
WebMock.enable!
WebMock.disable_net_connect!

class AdmissionVerifier
  ADMISSION_TABLES = %w[books requests activity_logs].freeze
  RAILS_ONLY_TABLES = %w[api_tokens].freeze
  TIMESTAMP_COLUMNS = %w[created_at updated_at].freeze
  TIMESTAMP = /\A\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{6}\z/
  REPRESENTATION_TIMES = %w[created_at updated_at].freeze

  def initialize(paths:, bundle:, evidence:)
    @paths = paths
    @encryption = JSON.parse(File.read(File.join(bundle, "secrets", "credentials.json"))).fetch("encryption")
    @evidence = evidence
    @recorded = JSON.parse(File.read(File.join(evidence, "cases.json")))
    @cases = @recorded.fetch("cases")
    @failures = []
    @checks = 0
    @report = { "bundle" => @recorded.fetch("bundle") }
  end

  def call
    lookups = count_metadata_lookups
    ActiveJob::Base.queue_adapter = :test
    install_database(File.join(@evidence, "before.sqlite3"))
    rails_answers = run_oracle
    @report["rails_metadata_lookups_replaced"] = lookups.call
    @report["rails_immediate_search_jobs"] = enqueued_search_ids.size
    rails_rows = table_rows(@paths.primary_db)
    compare_answers(rails_answers)
    compare_rows(rails_rows)

    install_database(File.join(@evidence, "after.sqlite3"))
    verify_rails_reads_go_rows(rails_answers)
    verify_rails_answers_repeats
    verify_dispatch
    expect(WebMock::RequestRegistry.instance.requested_signatures.hash.empty?, "a network request was attempted")
    finish
  end

  private

  def expect(condition, message)
    @checks += 1
    @failures << message unless condition
  end

  def count_metadata_lookups
    count = 0
    BookMetadataLookupService.singleton_class.define_method(:call) do |*_arguments, **_options|
      count += 1
      {}
    end
    -> { count }
  end

  def install_database(source)
    ActiveRecord::Base.connection_handler.clear_all_connections!
    Dir.glob("#{@paths.primary_db}*").each { |file| FileUtils.rm_f(file) }
    FileUtils.cp(source, @paths.primary_db)
    File.chmod(0o600, @paths.primary_db)
    ActiveRecord::Encryption.configure(
      primary_key: @encryption["primary_key"], deterministic_key: @encryption["deterministic_key"],
      key_derivation_salt: @encryption["key_derivation_salt"], hash_digest_class: OpenSSL::Digest::SHA256,
      support_sha1_for_non_deterministic_encryption: true
    )
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    @session = ActionDispatch::Integration::Session.new(Rails.application)
    @tokens = {}
  end

  def token_for(account_id)
    @tokens[account_id] ||= APIToken.issue!(name: "admission oracle", user: User.find(account_id), scopes: %w[requests:read requests:write]).last
  end

  def submit(account_id, body)
    headers = { "Authorization" => "Bearer #{token_for(account_id)}", "Content-Type" => "application/json" }
    @session.post(CREATE_PATH, params: body, headers: headers)
    parsed = begin
      JSON.parse(@session.response.body)
    rescue JSON::ParserError
      nil
    end
    [ @session.response.status, parsed ]
  rescue StandardError => error
    [ "raised #{error.class}", nil ]
  end

  def outcome_of(status, body)
    body ||= {}
    case [ status, body["error"] ]
    in [ 201, _ ] then { "outcome" => "created", "request_id" => body.dig("request", "id"), "warnings" => body["warnings"] }
    in [ 200, _ ] if body["existing"] == true then { "outcome" => "existing", "request_id" => body.dig("request", "id") }
    in [ 409, "already_in_library" ] then { "outcome" => "already_in_library", "publication_id" => body["publication_id"] }
    in [ 409, "already_requested" ] then { "outcome" => "already_requested", "keys" => body.keys.sort }
    in [ 422, "invalid_request" ] then { "outcome" => "invalid_request" }
    in [ 401, _ ] then { "outcome" => "account_unavailable" }
    else { "outcome" => "rails_refused #{status}" }
    end
  end

  def run_oracle
    @cases.select { |entry| entry["oracle"] }.to_h do |entry|
      status, body = submit(entry.fetch("account_id"), JSON.generate(entry.fetch("body")))
      [ entry.fetch("name"), outcome_of(status, body).merge("representation" => body&.dig("request")) ]
    end
  end

  def compare_answers(rails_answers)
    rails_answers.each do |name, rails|
      go = @cases.find { |entry| entry["name"] == name }
      wanted = go.fetch("outcome")
      if wanted == "unsupported_stored_value"
        expect(rails["outcome"].start_with?("rails_refused"), "#{name}: Rails answered #{rails['outcome']} where Go refused a stored value")
        next
      end
      expect(rails["outcome"] == wanted, "#{name}: Rails answered #{rails['outcome']}, Go #{wanted}")
      %w[request_id publication_id].each do |key|
        next unless rails.key?(key)

        expect(rails[key] == go[key], "#{name}: Rails #{key} #{rails[key].inspect}, Go #{go[key].inspect}")
      end
      expect(rails["warnings"] == go["warnings"], "#{name}: Rails warnings #{rails['warnings'].inspect}, Go #{go['warnings'].inspect}") if wanted == "created"
      expect(rails["keys"] == %w[error message], "#{name}: Rails disclosed #{rails['keys'].inspect}") if wanted == "already_requested"
    end
    @report["oracle_cases"] = rails_answers.transform_values { |answer| answer["outcome"] }
  end

  def table_rows(path)
    database = SQLite3::Database.new(path, readonly: true)
    tables = database.execute("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'").flatten
    tables.to_h do |table|
      columns = database.execute("SELECT name FROM pragma_table_info(?)", [ table ]).flatten
      rows = database.execute("SELECT * FROM \"#{table}\" ORDER BY rowid").map { |row| columns.zip(row).to_h }
      [ table, rows ]
    rescue SQLite3::SQLException
      [ table, database.execute("SELECT * FROM \"#{table}\"").sort_by(&:to_s).map { |row| columns.zip(row).to_h } ]
    end
  ensure
    database&.close
  end

  def compare_rows(rails_rows)
    before = table_rows(File.join(@evidence, "before.sqlite3"))
    go_rows = table_rows(File.join(@evidence, "after.sqlite3"))
    (rails_rows.keys | go_rows.keys).each do |table|
      next if RAILS_ONLY_TABLES.include?(table)

      if ADMISSION_TABLES.include?(table)
        compare_admission_table(table, before.fetch(table), rails_rows.fetch(table), go_rows.fetch(table))
      else
        expect(rails_rows[table] == go_rows[table], "#{table}: Rails and Go disagree outside the admission tables")
      end
    end
  end

  def compare_admission_table(table, before, rails, go)
    by_id = ->(rows) { rows.to_h { |row| [ row.fetch("id"), row ] } }
    before, rails, go = by_id.(before), by_id.(rails), by_id.(go)
    expect(rails.keys == go.keys, "#{table}: Rails ids #{rails.keys - before.keys}, Go ids #{go.keys - before.keys}")
    rails.each do |id, rails_row|
      go_row = go[id]
      next unless go_row

      difference = known_difference(table, rails_row)
      rails_row.each_key do |column|
        next if TIMESTAMP_COLUMNS.include?(column)
        next if difference && difference[:column] == column && go_row[column] == difference[:go] && rails_row[column] == difference[:rails]

        expect(rails_row[column] == go_row[column], "#{table}[#{id}].#{column}: Rails #{rails_row[column].inspect}, Go #{go_row[column].inspect}")
      end
      compare_timestamps(table, id, before[id], rails_row, go_row)
    end
    @report["#{table}_added"] = (go.keys - before.keys).size
  end

  def compare_timestamps(table, id, original, rails_row, go_row)
    if original
      TIMESTAMP_COLUMNS.each do |column|
        rails_moved = rails_row[column] != original[column]
        go_moved = go_row[column] != original[column]
        expect(rails_moved == go_moved, "#{table}[#{id}].#{column}: Rails moved it #{rails_moved}, Go #{go_moved}")
        expect(!go_moved || go_row[column].match?(TIMESTAMP), "#{table}[#{id}].#{column}: unreadable Go time")
      end
    else
      expect(go_row.values_at(*TIMESTAMP_COLUMNS).all? { |value| value.is_a?(String) && value.match?(TIMESTAMP) }, "#{table}[#{id}]: unreadable Go times")
      expect((go_row["created_at"] == go_row["updated_at"]) == (rails_row["created_at"] == rails_row["updated_at"]), "#{table}[#{id}]: insert times differ in shape")
    end
  end

  def known_difference(table, rails_row)
    return unless table == "books"

    entry = @cases.find { |candidate| candidate["difference"] == "cover_normalised_by_rails" }
    work = entry && entry.dig("body", "work_id").to_s.delete_prefix("openlibrary:")
    return unless work && rails_row["open_library_work_id"] == work

    { column: "cover_url", go: nil, rails: entry.dig("body", "cover_url").sub(/\AHTTPS:/, "https:") }
  end

  def go_requests
    @cases.select { |entry| %w[created existing].include?(entry["outcome"]) }
  end

  def verify_rails_reads_go_rows(rails_answers)
    go_requests.each do |entry|
      request = Request.find(Integer(entry.fetch("request_id")))
      expect(request.valid? && request.book.valid?, "#{entry['name']}: Rails finds the Go request or its book invalid")
      expect(request.user_id == entry.fetch("account_id"), "#{entry['name']}: Go request belongs to another account")
      next unless entry["oracle"] && rails_answers.dig(entry["name"], "representation")

      ours = Consumer::RequestView.new(request).representation.stringify_keys.except(*REPRESENTATION_TIMES)
      theirs = rails_answers.dig(entry["name"], "representation").except(*REPRESENTATION_TIMES)
      theirs = theirs.merge("cover_url" => nil) if entry["difference"] == "cover_normalised_by_rails"
      expect(ours == theirs, "#{entry['name']}: Rails shows the Go request as #{ours}, its own as #{theirs}")
    end
    @report["go_requests_read_by_rails"] = go_requests.size
  end

  def verify_rails_answers_repeats
    users = @recorded.fetch("users")
    @cases.select { |entry| entry["outcome"] == "created" }.each do |entry|
      status, body = submit(entry.fetch("account_id"), JSON.generate(entry.fetch("body")))
      expect(status == 200 && body&.dig("request", "id") == entry["request_id"] && body["existing"] == true, "#{entry['name']}: Rails did not recognise its owner's repeat of a Go request")
      other = entry["account"] == "alice" ? users.fetch("bob") : users.fetch("alice")
      status, body = submit(other, JSON.generate(entry.fetch("body")))
      expect(status == 409 && body&.dig("error") == "already_requested" && body.keys.sort == %w[error message], "#{entry['name']}: Rails answered another account #{status}")
    end
  end

  def enqueued_search_ids
    ActiveJob::Base.queue_adapter.enqueued_jobs
      .select { |job| job[:job] == SearchJob || job["job_class"] == "SearchJob" }
      .map { |job| job[:args]&.first || job["arguments"]&.first }
  end

  def search_sources
    {
      "indexer" => IndexerClient.configured?, "anna" => AnnaArchiveClient.configured?, "zlibrary" => ZLibraryClient.configured?,
      "gutenberg" => GutenbergClient.configured?,
      "custom" => AcquisitionProvider.enabled.for_book_type("ebook").exists?, "stores" => StoreProviderRegistry.enabled_for("ebook").any?
    }
  end

  def verify_dispatch
    @report["custom_providers_disabled_in_copy"] = AcquisitionProvider.enabled.update_all(enabled: false)
    expect(search_sources.values.none?, "a search source is configured in the fixture: #{search_sources.select { |_name, on| on }.keys}")
    SettingsService.set(:queue_batch_size, RequestQueueJob::MAX_PROCESS_BATCH_SIZE)
    pending = Request.processable.limit(RequestQueueJob::MAX_PROCESS_BATCH_SIZE).pluck(:id)
    expect(pending.size < RequestQueueJob::MAX_PROCESS_BATCH_SIZE, "more pending requests than one queue run takes")
    created = @cases.select { |entry| entry["outcome"] == "created" }.map { |entry| Integer(entry["request_id"]) }
    expect((created - pending).empty?, "Rails does not see Go requests #{created - pending} as pending")

    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    RequestQueueJob.perform_now
    dispatched = enqueued_search_ids
    reconciled = Request.processable.limit(RequestQueueJob::MAX_PROCESS_BATCH_SIZE).pluck(:id)
    expect(dispatched == reconciled && (pending - reconciled).empty?, "RequestQueueJob dispatched #{dispatched}, pending #{reconciled}")
    created.each { |id| expect(dispatched.count(id) == 1, "request #{id} dispatched #{dispatched.count(id)} times") }
    job = ActiveJob::Base.queue_adapter.enqueued_jobs.find { |candidate| candidate[:job] == SearchJob && candidate[:args] == [ created.first ] }
    @report["captured_job"] = job && { "job_class" => job[:job].name, "arguments" => job[:args], "queue" => job[:queue] }

    created.each do |id|
      SearchJob.perform_now(id)
      claimed = Request.find(id)
      SearchJob.perform_now(id)
      again = Request.find(id)
      expect(!claimed.pending? && claimed.search_generation == 1, "request #{id}: SearchJob did not claim it once (#{claimed.status}, generation #{claimed.search_generation})")
      expect(again.search_generation == 1 && again.updated_at == claimed.updated_at && again.status == claimed.status, "request #{id}: a second SearchJob acted on a claimed request")
    end
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    RequestQueueJob.perform_now
    expect((enqueued_search_ids & created).empty?, "RequestQueueJob dispatched claimed Go requests again")
    @report["dispatched_go_requests"] = created.size
    @report["dispatched_total"] = dispatched.size
  end

  def finish
    puts JSON.generate(@report.merge("checks" => @checks, "failures" => @failures))
    exit(@failures.empty? && @checks.positive? ? 0 : 1)
  end
end

AdmissionVerifier.new(paths: paths, bundle: options[:bundle], evidence: options[:evidence]).call
