# frozen_string_literal: true

require "optparse"
require "json"
require "fileutils"
require "digest"
require "sqlite3"
require "uri"
require_relative "../lib/producer_boot"

REPO_ROOT = File.expand_path("../../..", __dir__)

options = {}
OptionParser.new do |parser|
  parser.banner = "Usage: verify_gutenberg_download.rb --bundle PATH --name NAME --evidence PATH --out NEW_PATH"
  %w[bundle name evidence out].each { |name| parser.on("--#{name} VALUE") { |value| options[name.to_sym] = value } }
end.parse!
%i[bundle name evidence out].each { |name| abort "refused: --#{name} is required" unless options[name] }

begin
  paths = Migration::ProducerBoot.call(out: options[:out], repo_root: REPO_ROOT)
rescue Migration::FixtureIsolation::Refused => error
  warn "refused: #{error.message}"
  exit 2
end

require "webmock"
WebMock.enable!
WebMock.disable_net_connect!

module LoopbackCatalogue
  def validate!(url, allow_private: false)
    super(url, allow_private: allow_private || URI.parse(url.to_s).host == "127.0.0.1")
  end
end
OutboundUrlGuard.singleton_class.prepend(LoopbackCatalogue)

class GutenbergDownloadVerifier
  WRITTEN_TABLES = %w[requests search_results downloads request_events notifications books activity_logs].freeze
  TIMESTAMPS = %w[created_at updated_at completed_at].freeze
  LIBRARY_PATHS = { "downloads" => "download_path", "books" => "file_path" }.freeze
  TIMESTAMP = /\A\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{6}\z/
  REQUIRED_CASES = { "current" => %w[completed interrupted], "upgrade" => %w[completed] }.freeze

  def initialize(paths:, bundle:, name:, evidence:)
    @paths = paths
    @encryption = JSON.parse(File.read(File.join(bundle, "secrets", "credentials.json"))).fetch("encryption")
    @name = name
    @cases = Dir.glob(File.join(evidence, "*", "case.json")).sort.filter_map do |path|
      entry = JSON.parse(File.read(path))
      entry.merge("dir" => File.dirname(path)) if entry["bundle"] == name
    end
    @failures = []
    @checks = 0
    @report = { "bundle" => name, "cases" => {} }
  end

  def call
    names = @cases.map { |entry| entry["name"] }.sort
    expect(names == REQUIRED_CASES.fetch(@name, []).sort, "evidence for #{names}, required #{REQUIRED_CASES.fetch(@name, [])}")
    ActiveJob::Base.queue_adapter = :test
    @cases.each do |entry|
      report = { "rails_download" => rails_download(entry) }
      report["go_read_by_rails"] = rails_reads_go(entry) if entry["name"] == "completed"
      @report["cases"][entry["name"]] = report
    end
    @report.merge("checks" => @checks, "failures" => @failures)
  end

  private

  def expect(condition, message)
    @checks += 1
    @failures << "#{@name}: #{message}" unless condition
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
    ActiveJob::Base.queue_adapter.performed_jobs.clear
    SettingsService.clear_cache if SettingsService.respond_to?(:clear_cache)
  end

  def stub_catalogue(entry)
    book = File.binread(entry.fetch("book_file"))
    seen = []
    WebMock.reset!
    WebMock.stub_request(:any, /\A#{Regexp.escape(entry.fetch('origin'))}\//).to_return do |request|
      seen << request.uri.path
      next { status: 418, body: "unexpected" } unless request.method == :get && request.uri.path == entry.fetch("book_link")

      { status: 200, body: book, headers: { "Content-Type" => "application/epub+zip" } }
    end
    seen
  end

  def table_rows(path)
    database = SQLite3::Database.new(path, readonly: true)
    tables = database.execute("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'wf_%'").flatten
    tables.to_h do |table|
      columns = database.execute("SELECT name FROM pragma_table_info(?)", [ table ]).flatten
      [ table, database.execute("SELECT * FROM \"#{table}\" ORDER BY rowid").map { |row| columns.zip(row).to_h } ]
    rescue SQLite3::SQLException
      [ table, database.execute("SELECT * FROM \"#{table}\"").sort_by(&:to_s).map { |row| columns.zip(row).to_h } ]
    end
  ensure
    database&.close
  end

  def rails_download(entry)
    name = entry.fetch("name")
    install_database(File.join(entry["dir"], "before.sqlite3"))
    library = File.join(@paths.tmp, "rails-library-#{@name}-#{name}")
    FileUtils.rm_rf(library)
    FileUtils.mkdir_p(library, mode: 0o755)
    Setting.find_by!(key: "ebook_output_path").update!(value: library)
    seen = stub_catalogue(entry)
    request = Request.find(entry.fetch("request_id"))
    result = request.search_results.find(entry.fetch("result_id"))
    expect(request.searching? && request.attention_needed? && result.pending? && result.downloadable?, "#{name}: Rails does not read the Go-searched request as awaiting this selection")
    request.select_result!(result)
    jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.select { |job| job["job_class"] == "DownloadJob" }.map { |job| job.select { |key, _| key.is_a?(String) } }
    expect(jobs.size == 1, "#{name}: Rails enqueued #{jobs.size} downloads")
    jobs.each { |job| ActiveJob::Base.execute(job) }
    request.reload
    download = request.downloads.order(:id).last
    rails_path = request.book.reload.file_path
    expect(request.completed? && download&.completed? && rails_path.present?, "#{name}: Rails did not complete the download (#{request.status}, #{download&.status})")
    expect(seen == [ entry.fetch("book_link") ], "#{name}: Rails asked the catalogue #{seen}")
    files = Dir.glob(File.join(library, "**", "*.epub"))
    expect(files.size == 1 && Digest::SHA256.file(files.first).hexdigest == entry.fetch("sha256"), "#{name}: Rails stored #{files.size} files or different bytes")
    differences = compare_with_go(entry, library)
    { "rails_book_path_under_its_root" => rails_path.to_s.delete_prefix(library), "differences" => differences }
  end

  def compare_with_go(entry, library)
    name = entry.fetch("name")
    ActiveRecord::Base.connection_handler.clear_all_connections!
    before = table_rows(File.join(entry["dir"], "before.sqlite3"))
    go = table_rows(File.join(entry["dir"], "after.sqlite3"))
    rails = table_rows(@paths.primary_db)
    differences = Hash.new { |hash, key| hash[key] = [] }
    (rails.keys | go.keys).each do |table|
      unless WRITTEN_TABLES.include?(table)
        rails_rows = rails[table]
        go_rows = go[table]
        if table == "settings"
          rails_rows = rails_rows.reject { |row| row["key"] == "ebook_output_path" }
          go_rows = go_rows.reject { |row| row["key"] == "ebook_output_path" }
        end
        expect(rails_rows == go_rows, "#{name}: #{table} differs outside the written tables")
        next
      end
      by_id = ->(rows) { rows.to_h { |row| [ row.fetch("id"), row ] } }
      original, rails_rows, go_rows = by_id.(before.fetch(table)), by_id.(rails.fetch(table)), by_id.(go.fetch(table))
      expect(rails_rows.keys == go_rows.keys, "#{name}: #{table} ids Rails +#{rails_rows.keys - original.keys}/-#{original.keys - rails_rows.keys}, Go +#{go_rows.keys - original.keys}/-#{original.keys - go_rows.keys}")
      rails_rows.each do |row_id, rails_row|
        go_row = go_rows[row_id] or next
        rails_row.each_key do |column|
          next if TIMESTAMPS.include?(column)

          if LIBRARY_PATHS[table] == column && rails_row[column] != original.dig(row_id, column)
            expect(rails_row[column].to_s.start_with?(library + "/") && go_row[column] == entry.fetch("book_path"), "#{name}: #{table}[#{row_id}].#{column} Rails #{rails_row[column].inspect}, Go #{go_row[column].inspect}")
            differences["library path #{table}.#{column}"] << row_id
            next
          end
          expect(rails_row[column] == go_row[column], "#{name}: #{table}[#{row_id}].#{column}: Rails #{rails_row[column].inspect}, Go #{go_row[column].inspect}")
        end
        compare_times(name, table, row_id, original[row_id], rails_row, go_row)
      end
    end
    differences.transform_values(&:sort)
  end

  def compare_times(name, table, row_id, original, rails_row, go_row)
    TIMESTAMPS.each do |column|
      next unless rails_row.key?(column)

      expect(rails_row[column].nil? == go_row[column].nil?, "#{name}: #{table}[#{row_id}].#{column} is set by one side only")
      expect(go_row[column].nil? || go_row[column].match?(TIMESTAMP), "#{name}: #{table}[#{row_id}].#{column} is not a Rails time")
      next unless original

      rails_moved = rails_row[column] != original[column]
      go_moved = go_row[column] != original[column]
      expect(rails_moved == go_moved, "#{name}: #{table}[#{row_id}].#{column}: Rails moved it #{rails_moved}, Go #{go_moved}")
    end
  end

  def rails_reads_go(entry)
    install_database(File.join(entry["dir"], "after.sqlite3"))
    WebMock.reset!
    request = Request.find(entry.fetch("request_id"))
    book = request.book
    download = Download.find(entry.fetch("download_id"))
    expect(request.valid? && request.completed? && request.completed_at.present? && !request.attention_needed?, "Rails does not read the Go request as completed")
    expect(book.valid? && book.acquired? && book.file_path == entry.fetch("book_path") && !book.acquisition_reserved?, "Rails does not read the Go book as acquired")
    expect(download.valid? && download.completed? && download.download_type == "direct" && download.search_result_id == entry.fetch("result_id"), "Rails does not read the Go download as a completed direct download")
    expect(request.search_results.find(entry.fetch("result_id")).selected? && request.search_results.where.not(id: entry.fetch("result_id")).all?(&:rejected?), "Rails does not read the selection")
    expect(!request.direct_acquisition_recovery_pending? && !DirectDownloadFileService.live_recovery_lease?(download), "Rails sees a pending direct recovery")

    session = ActionDispatch::Integration::Session.new(Rails.application)
    token = APIToken.issue!(name: "download oracle", user: request.user, scopes: %w[library:read]).last
    headers = { "Authorization" => "Bearer #{token}" }
    session.get("/api/consumer/v1/library/#{book.id}", headers: headers)
    assets = session.response.successful? ? JSON.parse(session.response.body).fetch("assets", []) : []
    expect(assets.size == 1 && assets.first["id"] == entry.fetch("asset_id") && assets.first["format"] == "epub", "Rails lists #{assets.map { |asset| asset['id'] }} for the Go book, Go listed #{entry.fetch('asset_id')}")
    session.get("/api/consumer/v1/library/#{book.id}/assets/#{entry.fetch('asset_id')}", headers: headers)
    delivered = session.response.body.to_s.b
    expect(session.response.status == 200 && Digest::SHA256.hexdigest(delivered) == entry.fetch("sha256"), "Rails delivered #{session.response.status} with different bytes")

    before = table_rows(@paths.primary_db).slice(*WRITTEN_TABLES)
    ActiveRecord::Base.connection_handler.clear_all_connections!
    DirectDownloadRecoveryJob.perform_now
    ActiveRecord::Base.connection_handler.clear_all_connections!
    after = table_rows(@paths.primary_db).slice(*WRITTEN_TABLES)
    expect(before == after, "Rails' direct-download recovery changed a Go completion")
    expect(Digest::SHA256.file(entry.fetch("book_path")).hexdigest == entry.fetch("sha256"), "Rails' recovery touched the Go file")
    { "asset_id" => assets.first&.fetch("id", nil), "delivered_bytes" => delivered.bytesize }
  end
end

result = GutenbergDownloadVerifier.new(paths: paths, bundle: options[:bundle], name: options[:name], evidence: options[:evidence]).call
puts JSON.generate(result)
