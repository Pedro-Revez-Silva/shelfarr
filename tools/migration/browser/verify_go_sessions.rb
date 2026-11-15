# frozen_string_literal: true

require "optparse"
require "json"
require "fileutils"
require "base64"
require "cgi"
require_relative "../lib/producer_boot"

REPO_ROOT = File.expand_path("../../..", __dir__)
PREVIEW = "/preview/api/v1"

options = {}
OptionParser.new do |parser|
  parser.banner = "Usage: verify_go_sessions.rb --bundle PATH --cases PATH --database PATH --cookies PATH --out NEW_PATH"
  %w[bundle cases database cookies out].each { |name| parser.on("--#{name} PATH") { |value| options[name.to_sym] = value } }
end.parse!
%i[bundle cases database cookies out].each { |name| abort "refused: --#{name} is required" unless options[name] }

begin
  paths = Migration::ProducerBoot.call(out: options[:out], repo_root: REPO_ROOT)
rescue Migration::FixtureIsolation::Refused => error
  warn "refused: #{error.message}"
  exit 2
end

class Verifier
  def initialize(paths:, bundle:, cases:, database:, cookies:)
    @paths = paths
    @encryption = JSON.parse(File.read(File.join(bundle, "secrets", "credentials.json"))).fetch("encryption")
    document = JSON.parse(File.read(File.join(cases, "cases.json")))
    @cases = cases
    @users = document.fetch("users")
    @allowed = document.fetch("preview_user_ids")
    @personas = JSON.parse(File.read(File.join(cases, "secrets", "personas.json")))
    @cookies = JSON.parse(File.read(cookies))
    @database = database
    @failures = []
    @checks = 0
  end

  def call
    install_capture_key
    install_database
    ENV[WebPreview::Access::VARIABLE] = @allowed
    verify_go_cookies
    verify_rails_logout_and_lock_state
    verify_rails_continues
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
    expect(application.key_generator.generate_key("signed cookie") == ActiveSupport::KeyGenerator.new(key, iterations: 1000, hash_digest_class: OpenSSL::Digest::SHA256).generate_key("signed cookie"), "the capture key is not in force")
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

  def get(path, cookie, account)
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! "www.example.com"
    headers = { "Accept" => "application/json", "Cookie" => "session_id=#{cookie}" }
    headers["X-Shelfarr-Account"] = account.to_s if account
    session.get(path, headers: headers)
    [ session.response.status, (JSON.parse(session.response.body) rescue nil), session ]
  end

  def verify_go_cookies
    expect(@cookies.size >= 2, "the Go run issued too few cookies to verify")
    owners = { "login-clean" => "browser_lockable", "login-after-lock" => "browser_lockable", "login-padded-uppercase-username" => "browser_member" }
    expect(@cookies.keys.sort == owners.keys.sort, "the Go run issued an unexpected set of cookies: #{@cookies.keys.sort}")
    @cookies.each do |name, cookie|
      user_id = @users.fetch(owners.fetch(name))

      status, body, = get("#{PREVIEW}/session", cookie, user_id)
      expect(status == 200 && body.dig("account", "id") == user_id.to_s, "Rails refused the session Go issued for #{name} (#{status})")
      expect(Session.where(user_id: user_id).count >= 1, "Rails does not see a session row for #{name}")
      expect(Session.find(Integer(Base64.strict_decode64(CGI.unescape(cookie).rpartition("--").first).then { |text| JSON.parse(text).dig("_rails", "message") }.then { |text| Base64.strict_decode64(text) })).user_id == user_id, "the cookie of #{name} points at another account's row")
      status, = get("#{PREVIEW}/library", cookie, user_id)
      expect(status == 200, "Rails could not list a library with the cookie Go issued for #{name}")
      status, body, = get("#{PREVIEW}/session", cookie, @users.fetch("alice"))
      expect(status == 401 && body["error"] == "account_changed", "Rails accepted the Go cookie of #{name} for another account")
    end
    Session.find_each do |row|
      expect(row.created_at.is_a?(Time) && row.updated_at.is_a?(Time) && row.user_id.is_a?(Integer), "Rails cannot load session row #{row.id}")
    end
  end

  def verify_rails_logout_and_lock_state
    logged_out = @personas.fetch("personas").fetch("login-member")
    status, body, = get("#{PREVIEW}/session", logged_out.fetch("cookie"), logged_out.fetch("user_id"))
    expect(status == 401 && body["error"] == "signed_out", "Rails still accepts a session Go revoked at logout (#{status})")
    expect(Session.where(id: logged_out.fetch("session_id")).none?, "the session row Go revoked is back")
    user = User.find(@users.fetch("browser_lockable"))
    expect(user.failed_login_count.zero? && !user.locked? && user.locked_until.nil?, "Rails reads a lock state Go did not leave")
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.post "/session", params: { username: "browser_lockable", password: @personas.fetch("passwords").fetch("browser_lockable") }
    expect(session.response.location == "http://www.example.com/", "Rails refuses a password after Go reset the counters")
    expect(User.find(@users.fetch("browser_member")).failed_login_count.zero?, "a successful sign-in did not clear the counters Go recorded")
  end

  def verify_rails_continues
    cookie = @cookies.values.first
    lockable = @users.fetch("browser_lockable")
    book = Book.acquired.where(book_type: %i[ebook audiobook]).order(:id).first
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! "www.example.com"
    session.put "#{PREVIEW}/library/#{book.id}/reading_status", params: { status: "finished" }.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json", "Cookie" => "session_id=#{cookie}", "X-Shelfarr-Account" => lockable.to_s }
    expect(session.response.status == 200, "Rails could not write on top of a Go session (#{session.response.status})")
    expect(ConsumerReadingState.where(user_id: lockable, book_id: book.id, status: :finished).exists?, "the status Rails wrote is missing")
  end
end

Verifier.new(paths: paths, bundle: options[:bundle], cases: options[:cases], database: options[:database], cookies: options[:cookies]).call
