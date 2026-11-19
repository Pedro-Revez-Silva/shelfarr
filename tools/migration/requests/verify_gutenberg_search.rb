# frozen_string_literal: true

require "optparse"
require "json"
require "fileutils"
require "sqlite3"
require "uri"
require_relative "../lib/producer_boot"

REPO_ROOT = File.expand_path("../../..", __dir__)

options = {}
OptionParser.new do |parser|
  parser.banner = "Usage: verify_gutenberg_search.rb --bundle PATH --name NAME --evidence PATH --out NEW_PATH"
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
require "active_support/testing/time_helpers"
WebMock.enable!
WebMock.disable_net_connect!

class GutenbergSearchVerifier
  include ActiveSupport::Testing::TimeHelpers

  SEARCH_TABLES = %w[requests search_results downloads store_offers request_events notifications].freeze
  TIMESTAMPS = %w[created_at updated_at].freeze
  CLAIM_TIMES = %w[search_claimed_at next_retry_at].freeze
  UNSCORED = %w[confidence_score score_breakdown].freeze
  RESCORED = %w[confidence_score score_breakdown detected_language].freeze
  TIMESTAMP = /\A\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{6}\z/
  SELECTION = "Search results found. Please review and select a result to download."
  FAILURE = "Search failed before any source returned results."
  DOCUMENTED_OUTCOMES = {
    "malformed" => { go: "failed", rails: "candidates" },
    "withheld" => { go: "released", rails: "candidates" }
  }.freeze

  def initialize(paths:, bundle:, name:, evidence:)
    @paths = paths
    @encryption = JSON.parse(File.read(File.join(bundle, "secrets", "credentials.json"))).fetch("encryption")
    @cases = Dir.glob(File.join(evidence, "*", "case.json")).sort.filter_map do |path|
      entry = JSON.parse(File.read(path))
      entry.merge("dir" => File.dirname(path)) if entry["bundle"] == name
    end
    @failures = []
    @checks = 0
    @report = { "bundle" => name, "cases" => {} }
  end

  def call
    expect(@cases.any? { |entry| entry["name"] == "candidates" }, "no candidates evidence for this bundle")
    ActiveJob::Base.queue_adapter = :test
    @cases.each do |entry|
      case entry["name"]
      when "killed" then verify_recovery(entry)
      else verify_case(entry)
      end
    end
    finish
  end

  private

  def expect(condition, message)
    @checks += 1
    @failures << message unless condition
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
    GutenbergClient.reset_connection!
  end

  def stub_catalogue(entry)
    routes = entry.fetch("routes").to_h { |route| [ [ route["path"], route["query"].to_s ], route ] }
    seen = []
    WebMock.reset!
    WebMock.stub_request(:any, /\A#{Regexp.escape(entry.fetch('origin'))}\//).to_return do |request|
      path = request.uri.path
      query = path == "/ebooks/search.opds/" ? URI.decode_www_form(request.uri.query.to_s).to_h.fetch("query", "") : ""
      seen << "#{path}?#{query}"
      route = routes[[ path, query ]]
      next { status: 418, body: "unexpected" } unless route && request.method == :get

      headers = route["status"].between?(300, 399) ? { "Location" => route["body"] } : {}
      { status: route["status"], body: route["body"], headers: headers }
    end
    seen
  end

  def outcome_of(request)
    case [ request.status, request.attention_needed, request.issue_description ]
    in [ "searching", true, SELECTION ] then "candidates"
    in [ "searching", true, FAILURE ] then "failed"
    in [ "not_found", false, nil ] then "no_results"
    in [ "not_found", true, String => issue ] if issue.start_with?("Maximum retry attempts") then "retries_exhausted"
    in [ "pending", false, nil ] then "released"
    else "unexpected #{request.status} #{request.attention_needed} #{request.issue_description.inspect}"
    end
  end

  def verify_case(entry)
    name = entry.fetch("name")
    id = entry.fetch("request_id")
    install_database(File.join(entry["dir"], "before.sqlite3"))
    seen = stub_catalogue(entry)
    SearchJob.perform_now(id)
    rails = outcome_of(Request.find(id))
    report = { "go" => entry["outcome"], "rails" => rails, "rails_requests" => seen.size, "go_requests" => entry["requests"].size }

    if (documented = DOCUMENTED_OUTCOMES[name])
      expect(entry["outcome"] == documented[:go] && rails == documented[:rails], "#{name}: Go #{entry['outcome']}, Rails #{rails}; documented Go #{documented[:go]}, Rails #{documented[:rails]}")
      report["rails_results"] = Request.find(id).search_results.order(:id).map { |result| result.slice("guid", "title", "download_url") }
      verify_handback(entry) if name == "withheld"
    else
      expect(rails == entry["outcome"], "#{name}: Rails #{rails}, Go #{entry['outcome']}")
      expect(seen == entry["requests"], "#{name}: Rails asked the catalogue #{seen}, Go #{entry['requests']}")
      report["differences"] = compare_rows(name, id, entry)
    end
    expect(no_other_network?, "#{name}: a request outside the synthetic catalogue was attempted")
    verify_rails_reads_go_rows(entry) if entry["outcome"] == "candidates"
    @report["cases"][name] = report
  end

  def no_other_network?
    WebMock::RequestRegistry.instance.requested_signatures.hash.keys.all? { |signature| signature.uri.host == "127.0.0.1" }
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

  def compare_rows(name, id, entry)
    ActiveRecord::Base.connection_handler.clear_all_connections!
    before = table_rows(File.join(entry["dir"], "before.sqlite3"))
    go = table_rows(File.join(entry["dir"], "after.sqlite3"))
    rails = table_rows(@paths.primary_db)
    differences = Hash.new { |hash, key| hash[key] = [] }
    (rails.keys | go.keys).each do |table|
      unless SEARCH_TABLES.include?(table)
        expect(rails[table] == go[table], "#{name}: #{table} differs outside the search tables")
        next
      end
      by_id = ->(rows) { rows.to_h { |row| [ row.fetch("id"), row ] } }
      original, rails_rows, go_rows = by_id.(before.fetch(table)), by_id.(rails.fetch(table)), by_id.(go.fetch(table))
      expect(rails_rows.keys == go_rows.keys, "#{name}: #{table} ids Rails #{rails_rows.keys - original.keys}/#{original.keys - rails_rows.keys}, Go #{go_rows.keys - original.keys}/#{original.keys - go_rows.keys}")
      rails_rows.each do |row_id, rails_row|
        go_row = go_rows[row_id] or next
        rails_row.each_key do |column|
          next if TIMESTAMPS.include?(column) || CLAIM_TIMES.include?(column)

          if table == "search_results" && (original[row_id] ? RESCORED : UNSCORED).include?(column)
            expected = original[row_id] ? original[row_id][column] : nil
            expect(go_row[column] == expected, "#{name}: Go scored search_results[#{row_id}].#{column}")
            differences["#{original[row_id] ? 'rescored' : 'unscored'} #{column}"] << row_id if rails_row[column] != go_row[column]
            next
          end
          expect(rails_row[column] == go_row[column], "#{name}: #{table}[#{row_id}].#{column}: Rails #{rails_row[column].inspect}, Go #{go_row[column].inspect}")
        end
        compare_times(name, table, row_id, original[row_id], rails_row, go_row)
      end
    end
    verify_retry_delay(name, id, rails.fetch("requests"), go.fetch("requests")) if entry["outcome"] == "no_results"
    differences.transform_values(&:sort)
  end

  def compare_times(name, table, row_id, original, rails_row, go_row)
    (TIMESTAMPS + CLAIM_TIMES).each do |column|
      next unless rails_row.key?(column)

      expect(rails_row[column].nil? == go_row[column].nil?, "#{name}: #{table}[#{row_id}].#{column} is set by one side only")
      expect(go_row[column].nil? || go_row[column].match?(TIMESTAMP), "#{name}: #{table}[#{row_id}].#{column} is not a Rails time")
      next unless original

      rails_moved = rails_row[column] != original[column]
      go_moved = go_row[column] != original[column]
      next if table == "search_results" && column == "updated_at" && rails_moved && !go_moved && original["status"] == go_row["status"]

      expect(rails_moved == go_moved, "#{name}: #{table}[#{row_id}].#{column}: Rails moved it #{rails_moved}, Go #{go_moved}")
    end
  end

  def verify_retry_delay(name, id, rails_requests, go_requests)
    [ [ "Rails", rails_requests ], [ "Go", go_requests ] ].each do |side, rows|
      row = rows.find { |candidate| candidate["id"] == id }
      delay = Time.zone.parse("#{row['next_retry_at']} UTC") - Time.zone.parse("#{row['updated_at']} UTC")
      expect((delay - 24.hours).abs < 5, "#{name}: #{side} retries after #{delay} seconds")
    end
  end

  def verify_handback(entry)
    id = entry.fetch("request_id")
    install_database(File.join(entry["dir"], "after.sqlite3"))
    stub_catalogue(entry)
    request = Request.find(id)
    expect(request.pending? && request.search_claimed_at.nil? && request.search_generation == 2, "withheld: Go did not hand the request back")
    RequestQueueJob.perform_now
    jobs = search_jobs
    expect(jobs.count { |job| job["arguments"] == [ id ] } == 1, "withheld: RequestQueueJob dispatched the handed-back request #{jobs.count { |job| job['arguments'] == [ id ] }} times")
    jobs.select { |job| job["arguments"] == [ id ] }.each { |job| ActiveJob::Base.execute(job) }
    expect(outcome_of(Request.find(id)) == "candidates" && Request.find(id).search_generation == 3, "withheld: Rails did not search the handed-back request")
  end

  def search_jobs
    ActiveJob::Base.queue_adapter.enqueued_jobs.select { |job| job["job_class"] == "SearchJob" }.map { |job| job.select { |key, _value| key.is_a?(String) } }
  end

  def verify_rails_reads_go_rows(entry)
    name = entry.fetch("name")
    id = entry.fetch("request_id")
    seeded = table_rows(File.join(entry["dir"], "before.sqlite3")).fetch("search_results").map { |row| row["id"] }
    install_database(File.join(entry["dir"], "after.sqlite3"))
    WebMock.reset!
    request = Request.find(id)
    expect(request.valid? && request.searching? && request.attention_needed? && request.search_claimed_at.nil?, "#{name}: Rails does not read the published request as awaiting selection")
    written = request.search_results.where.not(id: seeded).order(:id).to_a
    expect(written.any? && written.all? { |result| result.from_gutenberg? && entry.fetch("candidates").include?(result.guid) }, "#{name}: Rails finds #{written.map(&:guid)} as Go candidates")
    written.each do |result|
      expect(result.valid? && result.downloadable? && result.direct_download? && result.download_type == "direct", "#{name}: #{result.guid} is not a downloadable direct result for Rails")
      expect(result.source_display_name == "Project Gutenberg" && result.confidence_level == :unknown && result.safe_info_url == result.info_url, "#{name}: #{result.guid} reads differently")
      expect(URI(result.download_url).host == "127.0.0.1" && result.download_url.start_with?(entry.fetch("origin") + "/"), "#{name}: #{result.guid} links outside the catalogue")
      html = Current.set(api_user: User.where(role: User.roles.fetch("admin"), deleted_at: nil).first) do
        ApplicationController.render(partial: "requests/search_result_row", locals: { result: result, request: request })
      end
      expect(html.include?(ERB::Util.html_escape(result.title)) && html.include?("Project Gutenberg") && !html.include?("Score:"), "#{name}: the result row renders wrongly")
    end
    chosen = written.find(&:pending?)
    return expect(false, "#{name}: no selectable Go candidate") unless chosen

    request.select_result!(chosen)
    request.reload
    download = request.downloads.order(:id).last
    downloads = ActiveJob::Base.queue_adapter.enqueued_jobs.select { |job| job["job_class"] == "DownloadJob" }
    expect(chosen.reload.selected? && request.downloading? && download&.queued? && download.search_result_id == chosen.id, "#{name}: Rails did not select the Go candidate")
    expect(downloads.map { |job| job["arguments"] } == [ [ download&.id ] ], "#{name}: selection enqueued #{downloads.size} downloads")
    expect(ActiveJob::Base.queue_adapter.performed_jobs.empty? && WebMock::RequestRegistry.instance.requested_signatures.hash.empty?, "#{name}: selection performed work or contacted the network")
    (@report["selected"] ||= {})[name] = chosen.guid
  end

  def verify_recovery(entry)
    id = entry.fetch("request_id")
    install_database(File.join(entry["dir"], "before.sqlite3"))
    stub_catalogue(entry)
    claimed = Request.find(id)
    expect(claimed.searching? && claimed.search_claimed_at.present? && claimed.search_generation == 1, "killed: the evidence does not hold a live Go claim")
    RequestQueueJob.perform_now
    expect(Request.find(id).search_generation == 1 && search_jobs.none? { |job| job["arguments"] == [ id ] }, "killed: Rails took over a live claim")
    travel_to(claimed.search_claimed_at + RequestQueueJob::STALE_SEARCH_LEASE + 1.minute) do
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      RequestQueueJob.perform_now
      recovered = Request.find(id)
      jobs = search_jobs.select { |job| job["arguments"] == [ id ] }
      expect(recovered.pending? && recovered.search_generation == 2 && recovered.search_claimed_at.nil? && jobs.size == 1, "killed: Rails did not recover the abandoned Go claim once")
      jobs.each { |job| ActiveJob::Base.execute(job) }
    end
    finished = Request.find(id)
    expect(outcome_of(finished) == "candidates" && finished.search_generation == 3 && finished.search_results.pluck(:guid).sort == %w[gutenberg:1342 gutenberg:37431], "killed: Rails did not finish the recovered search")
    @report["cases"]["killed"] = { "rails_recovered_generation" => finished.search_generation }
  end

  def finish
    puts JSON.generate(@report.merge("checks" => @checks, "failures" => @failures))
    exit(@failures.empty? && @checks.positive? ? 0 : 1)
  end
end

GutenbergSearchVerifier.new(paths: paths, bundle: options[:bundle], name: options[:name], evidence: options[:evidence]).call
