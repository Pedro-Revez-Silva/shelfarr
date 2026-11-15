# frozen_string_literal: true

require "optparse"
require "json"
require "fileutils"
require "securerandom"
require_relative "../lib/producer_boot"

REPO_ROOT = File.expand_path("../../..", __dir__)
PREFIX = "/api/consumer/v1"

options = {}
OptionParser.new do |parser|
  parser.banner = "Usage: verify_go_rows.rb --bundle PATH --cases PATH --database PATH --out NEW_PATH"
  %w[bundle cases database out].each { |name| parser.on("--#{name} PATH") { |value| options[name.to_sym] = value } }
end.parse!
%i[bundle cases database out].each { |name| abort "refused: --#{name} is required" unless options[name] }

begin
  paths = Migration::ProducerBoot.call(out: options[:out], repo_root: REPO_ROOT)
rescue Migration::FixtureIsolation::Refused => error
  warn "refused: #{error.message}"
  exit 2
end

class Verifier
  def initialize(paths:, bundle:, cases:, database:)
    @paths = paths
    credentials = JSON.parse(File.read(File.join(bundle, "secrets", "credentials.json")))
    @encryption = credentials.fetch("encryption")
    @tokens = JSON.parse(File.read(File.join(cases, "secrets", "tokens.json")))
    @database = database
    @failures = []
    @counts = Hash.new(0)
  end

  def call
    install_database
    @session = ActionDispatch::Integration::Session.new(Rails.application)
    verify_models
    verify_api_reads
    verify_rails_writes_on_top
    report
  end

  private

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

  def expect(condition, message)
    @counts[:checks] += 1
    @failures << message unless condition
  end

  def label_for(user)
    { "alice" => "alice-full", "bob" => "bob-full" }[user.username]
  end

  def get(path, label)
    @session.get(path, headers: { "Authorization" => "Bearer #{@tokens.fetch(label)}" })
    [ @session.response.status, JSON.parse(@session.response.body) ]
  end

  def verify_models
    ConsumerProgress.find_each do |row|
      @counts[:progress_rows] += 1
      representation = row.representation
      expect(row.version >= 1 && row.user && row.book, "progress row #{row.id} has no owner or book")
      expect(representation[:updated_at].match?(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/), "progress row #{row.id} has an unreadable time")
      expect(row.observed_at.nil? || representation[:observed_at].match?(/\.\d{3}Z\z/), "progress row #{row.id} has an unreadable activity time")
      expect(row.client_mutation_id.present?, "progress row #{row.id} lost its mutation id")
    end
    ConsumerReadingState.find_each do |row|
      @counts[:status_rows] += 1
      expect(ConsumerReadingState.statuses.key?(row.status) && row.user && row.book, "reading state #{row.id} is not a Rails status")
    end
  end

  def verify_api_reads
    ConsumerProgress.includes(:user, :book).find_each do |row|
      label = label_for(row.user)
      next unless label

      status, body = get("#{PREFIX}/library/#{row.book_id}/progress", label)
      expected = JSON.parse(JSON.generate(row.representation))
      expect(status == 200 && body == { "progress" => expected }, "Rails does not project progress row #{row.id} for its owner")
      @counts[:owner_reads] += 1
      status, publication = get("#{PREFIX}/library/#{row.book_id}", label)
      state = ConsumerReadingState.find_by(user: row.user, book: row.book)
      wanted = state ? state.status : "in_progress"
      expect(status == 200 && publication["progress"] == expected && publication["reading_status"] == wanted, "Rails publication disagrees with progress row #{row.id}")
      other = label == "alice-full" ? "bob-full" : "alice-full"
      other_user = User.find_by(username: other.split("-").first)
      mine = ConsumerProgress.find_by(user: other_user, book_id: row.book_id)
      status, foreign = get("#{PREFIX}/library/#{row.book_id}/progress", other)
      expect(status == 200 && foreign["progress"] == (mine && JSON.parse(JSON.generate(mine.representation))), "Rails leaked progress row #{row.id} to another account")
      @counts[:isolation_reads] += 1
    end
    ConsumerReadingState.includes(:user).find_each do |row|
      label = label_for(row.user)
      next unless label

      status, publication = get("#{PREFIX}/library/#{row.book_id}", label)
      expect(status == 200 && publication["reading_status"] == row.status, "Rails publication disagrees with reading state #{row.id}")
      @counts[:status_reads] += 1
    end
  end

  def verify_rails_writes_on_top
    row = ConsumerProgress.joins(:book).where(books: { book_type: Book.book_types.fetch("audiobook") }).order(:id).includes(:user, :book).detect { |candidate| label_for(candidate.user) }
    return unless row

    asset = Consumer::LibraryAssets.new(row.book, formats: Consumer::ReaderFormats::SUPPORTED).list.first
    return unless asset

    label = label_for(row.user)
    body = JSON.generate(asset_id: asset.id, expected_version: row.version, client_mutation_id: SecureRandom.uuid, position_seconds: 5.5)
    @session.put("#{PREFIX}/library/#{row.book_id}/progress", params: body, headers: { "Authorization" => "Bearer #{@tokens.fetch(label)}", "Content-Type" => "application/json" })
    parsed = JSON.parse(@session.response.body)
    expect(@session.response.status == 200 && parsed.dig("progress", "version") == row.version + 1, "Rails could not continue a Go-written place")
    @session.put("#{PREFIX}/library/#{row.book_id}/reading_status", params: JSON.generate(status: "finished"), headers: { "Authorization" => "Bearer #{@tokens.fetch(label)}", "Content-Type" => "application/json" })
    expect(@session.response.status == 200, "Rails could not set a status on a Go-written book")
    @counts[:rails_writes] += 2
  end

  def report
    puts JSON.generate("failures" => @failures, "counts" => @counts)
    exit(@failures.empty? && @counts[:progress_rows].positive? ? 0 : 1)
  end
end

Verifier.new(paths: paths, bundle: options[:bundle], cases: options[:cases], database: options[:database]).call
