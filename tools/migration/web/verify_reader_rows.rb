# frozen_string_literal: true

require "optparse"
require "json"
require "fileutils"
require "securerandom"
require_relative "../lib/producer_boot"

REPO_ROOT = File.expand_path("../../..", __dir__)

options = {}
OptionParser.new do |parser|
  parser.banner = "Usage: verify_reader_rows.rb --bundle PATH --cases PATH --database PATH --rows PATH --out NEW_PATH"
  %w[bundle cases database rows out].each { |name| parser.on("--#{name} PATH") { |value| options[name.to_sym] = value } }
end.parse!
%i[bundle cases database rows out].each { |name| abort "refused: --#{name} is required" unless options[name] }

begin
  paths = Migration::ProducerBoot.call(out: options[:out], repo_root: REPO_ROOT)
rescue Migration::FixtureIsolation::Refused => error
  warn "refused: #{error.message}"
  exit 2
end

class ReaderRowsVerifier
  def initialize(paths:, bundle:, cases:, database:, rows:)
    @paths = paths
    @encryption = JSON.parse(File.read(File.join(bundle, "secrets", "credentials.json"))).fetch("encryption")
    @cases = cases
    @personas = JSON.parse(File.read(File.join(cases, "secrets", "personas.json"))).fetch("personas")
    @allowed = JSON.parse(File.read(File.join(cases, "cases.json"))).fetch("preview_user_ids")
    @written = JSON.parse(File.read(rows))
    @database = database
    @failures = []
    @checks = 0
  end

  def call
    install_capture_key
    install_database
    ENV[WebPreview::Access::VARIABLE] = @allowed
    user = User.find(@written.fetch("user_id"))
    @written.fetch("rows").each do |book_id, row|
      book = Book.find(Integer(book_id))
      stored = verify_rails_reads(user, book, row)
      verify_rails_replays(user, book, row) if stored
      verify_rails_continues(user, book, row) if stored
    end
    puts JSON.generate("failures" => @failures, "checks" => @checks)
    exit(@failures.empty? && @checks.positive? ? 0 : 1)
  end

  private

  def expect(condition, message)
    @checks += 1
    @failures << message unless condition
  end

  def install_capture_key
    key = File.read(File.join(@cases, "secrets", "secret_key_base"))
    ENV["SECRET_KEY_BASE"] = key
    application = Rails.application
    application.config.secret_key_base = key
    %i[@caching_key_generator @app_env_config @message_verifiers @key_generator].each do |name|
      application.remove_instance_variable(name) if application.instance_variable_defined?(name)
    end
  end

  def install_database
    ActiveRecord::Base.connection_handler.clear_all_connections!
    Dir.glob("#{@paths.primary_db}*").each { |file| FileUtils.rm_f(file) }
    FileUtils.cp(@database, @paths.primary_db)
    File.chmod(0o600, @paths.primary_db)
    ActiveRecord::Encryption.configure(
      primary_key: @encryption["primary_key"], deterministic_key: @encryption["deterministic_key"],
      key_derivation_salt: @encryption["key_derivation_salt"], hash_digest_class: OpenSSL::Digest::SHA256,
      support_sha1_for_non_deterministic_encryption: true
    )
  end

  def milliseconds(text)
    text && Time.iso8601(text.sub(" ", "T") + "Z").strftime("%Y-%m-%dT%H:%M:%S.%LZ")
  end

  def bearer(user)
    @bearer ||= {}
    @bearer[user.id] ||= APIToken.issue!(name: "reader rows verifier", user: user, scopes: %w[library:read progress:write], issued_via: APIToken::CONSUMER_DEVICE).last
  end

  def native(method, path, user, body = nil)
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! "www.example.com"
    headers = { "Accept" => "application/json", "Authorization" => "Bearer #{bearer(user)}" }
    headers["Content-Type"] = "application/json" if body
    session.process(method, path, params: body&.to_json, headers: headers)
    [ session.response.status, (JSON.parse(session.response.body) rescue nil) ]
  end

  def browser_put(path, user, body)
    persona = @personas.fetch("member")
    expect(persona.fetch("user_id") == user.id, "the member persona belongs to another account")
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! "www.example.com"
    session.put path, params: body.to_json, headers: { "Content-Type" => "application/json", "Accept" => "application/json", "Cookie" => "session_id=#{persona.fetch('cookie')}", "X-Shelfarr-Account" => user.id.to_s }
    [ session.response.status, (JSON.parse(session.response.body) rescue nil) ]
  end

  def request_body(row)
    body = { "asset_id" => row.fetch("asset_id"), "observed_at" => milliseconds(row.fetch("observed_at")), "client_mutation_id" => row.fetch("client_mutation_id"), "expected_version" => row.fetch("version") - 1 }
    if row["locator"]
      body["locator"] = JSON.parse(row["locator"])
    else
      body["position_seconds"] = row.fetch("position_seconds")
    end
    body
  end

  def verify_rails_reads(user, book, row)
    stored = ConsumerProgress.find_by(user: user, book: book)
    expect(stored, "Rails does not see the place Go saved for book #{book.id}")
    return nil unless stored

    expect(stored.version == row.fetch("version") && stored.asset_id == row.fetch("asset_id") && stored.client_mutation_id == row.fetch("client_mutation_id"), "Rails reads a different version, asset or mutation for book #{book.id}")
    expect(stored.observed_at&.utc&.strftime("%Y-%m-%dT%H:%M:%S.%LZ") == milliseconds(row.fetch("observed_at")), "Rails reads a different activity time for book #{book.id}: #{stored.observed_at.inspect}")
    status, body = native(:get, "/api/consumer/v1/library/#{book.id}/progress", user)
    progress = body&.fetch("progress", nil) || {}
    expect(status == 200 && progress["version"] == row.fetch("version") && progress["observed_at"] == milliseconds(row.fetch("observed_at")) && progress["client_mutation_id"] == row.fetch("client_mutation_id"),
      "the Rails API answers a different place for book #{book.id}: #{status} #{body.inspect}")
    expect(row["locator"].nil? || progress["locator"] == JSON.parse(row["locator"]), "Rails changed the locator Go stored for book #{book.id}")
    stored
  end

  def verify_rails_replays(user, book, row)
    before = ConsumerProgress.find_by!(user: user, book: book).attributes
    status, body = native(:put, "/api/consumer/v1/library/#{book.id}/progress", user, request_body(row).merge("expected_version" => 0))
    expect(status == 200 && body&.dig("progress", "version") == row.fetch("version"), "Rails did not replay Go's mutation for book #{book.id} unchanged: #{status} #{body.inspect}")
    expect(ConsumerProgress.find_by!(user: user, book: book).attributes == before, "replaying Go's mutation changed the Rails row for book #{book.id}")
  end

  def verify_rails_continues(user, book, row)
    later = (Time.now.utc + 1).strftime("%Y-%m-%dT%H:%M:%S.%LZ")
    body = request_body(row).merge("expected_version" => row.fetch("version"), "client_mutation_id" => SecureRandom.uuid, "observed_at" => later)
    if row["locator"]
      locator = JSON.parse(row["locator"])
      locator["locations"] = locator.fetch("locations").merge("progression" => 0.5)
      locator["locations"].delete("cfi")
      body["locator"] = locator
      status, answer = browser_put("/read/#{book.id}/progress", user, body)
    else
      body["position_seconds"] = row.fetch("position_seconds") + 30
      status, answer = native(:put, "/api/consumer/v1/library/#{book.id}/progress", user, body)
    end
    expect(status == 200 && answer&.dig("progress", "version") == row.fetch("version") + 1 && answer&.dig("progress", "observed_at") == later, "Rails could not continue from Go's place for book #{book.id}: #{status} #{answer.inspect}")
    stored = ConsumerProgress.find_by!(user: user, book: book)
    expect(stored.version == row.fetch("version") + 1, "Rails did not store the continued place for book #{book.id}")
  end
end

ReaderRowsVerifier.new(paths: paths, bundle: options[:bundle], cases: options[:cases], database: options[:database], rows: options[:rows]).call
