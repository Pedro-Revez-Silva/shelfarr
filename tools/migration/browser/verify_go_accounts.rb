# frozen_string_literal: true

require "optparse"
require "json"
require "fileutils"
require "securerandom"
require_relative "../lib/producer_boot"

REPO_ROOT = File.expand_path("../../..", __dir__)
PREVIEW = "/preview/api/v1"

options = {}
OptionParser.new do |parser|
  parser.banner = "Usage: verify_go_accounts.rb --bundle PATH --cases PATH --database PATH --state PATH --out NEW_PATH"
  %w[bundle cases database state out].each { |name| parser.on("--#{name} PATH") { |value| options[name.to_sym] = value } }
end.parse!
%i[bundle cases database state out].each { |name| abort "refused: --#{name} is required" unless options[name] }

begin
  paths = Migration::ProducerBoot.call(out: options[:out], repo_root: REPO_ROOT)
rescue Migration::FixtureIsolation::Refused => error
  warn "refused: #{error.message}"
  exit 2
end

class AccountVerifier
  def initialize(bundle:, cases:, database:, state:, paths:)
    @paths = paths
    @encryption = JSON.parse(File.read(File.join(bundle, "secrets", "credentials.json"))).fetch("encryption")
    document = JSON.parse(File.read(File.join(cases, "cases.json")))
    @cases = cases
    @users = document.fetch("users")
    @allowed = document.fetch("preview_user_ids")
    @personas = JSON.parse(File.read(File.join(cases, "secrets", "personas.json"))).fetch("personas")
    @state = JSON.parse(File.read(state))
    @database = database
    @failures = []
    @checks = 0
  end

  def call
    install_capture_key
    install_database
    ENV[WebPreview::Access::VARIABLE] = @allowed
    verify_rows
    verify_sessions
    verify_sign_in
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

  def account
    User.find(@users.fetch("browser_account"))
  end

  def legacy
    User.find(@users.fetch("browser_legacy"))
  end

  def session_status(cookie, user_id)
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! "www.example.com"
    session.get("#{PREVIEW}/session", headers: { "Accept" => "application/json", "Cookie" => "session_id=#{cookie}", "X-Shelfarr-Account" => user_id.to_s })
    [ session.response.status, (JSON.parse(session.response.body) rescue nil) ]
  end

  def rails_sign_in(username, password)
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.post "/session", params: { username: username, password: password }
    session.response.location == "http://www.example.com/"
  end

  def verify_rows
    expect(account.name == @state.fetch("name"), "Rails reads a different display name than Go saved")
    expect(account.valid?, "Rails finds the account Go saved invalid: #{account.errors.full_messages}")
    expect(account.password_digest.start_with?("$2a$12$"), "Go did not store a production-cost bcrypt digest")
    expect(account.authenticate(@state.fetch("password")).present?, "Rails cannot authenticate the password Go set")
    expect(!account.authenticate(@state.fetch("old_password")), "Rails still accepts the password Go replaced")
    expect(legacy.password_digest.start_with?("$2a$12$") && legacy.authenticate(@state.fetch("legacy_password")).present?, "Rails cannot authenticate the password Go set over a legacy digest")
    expect(!legacy.authenticate(@state.fetch("legacy_old_password")), "Rails still accepts the legacy password Go replaced")
    expect(account.updated_at.is_a?(Time) && Session.where(user_id: account.id).all? { |row| row.created_at.is_a?(Time) }, "Rails cannot load the rows Go wrote")
  end

  def verify_sessions
    status, body = session_status(@state.fetch("cookie"), account.id)
    expect(status == 200 && body.dig("account", "id") == account.id.to_s && body.dig("account", "name") == @state.fetch("name"), "Rails refuses the Go session that changed the password (#{status})")
    %w[account-elsewhere account-elsewhere-b legacy-elsewhere].each do |name|
      persona = @personas.fetch(name)
      status, body = session_status(persona.fetch("cookie"), persona.fetch("user_id"))
      expect(status == 401 && body["error"] == "signed_out", "Rails still accepts #{name}, which the password change ended (#{status})")
    end
    %w[alice bob member].each do |name|
      persona = @personas.fetch(name)
      status, = session_status(persona.fetch("cookie"), persona.fetch("user_id"))
      expect(status == 200, "#{name} lost its session to another account's password change (#{status})")
    end
  end

  def verify_sign_in
    expect(!rails_sign_in("browser_account", @state.fetch("old_password")), "Rails signs in with the password Go replaced")
    expect(rails_sign_in("browser_account", @state.fetch("password")), "Rails refuses to sign in with the password Go set")
    expect(rails_sign_in("browser_legacy", @state.fetch("legacy_password")), "Rails refuses the password Go set over a legacy digest")
  end

  def verify_rails_continues
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! "www.example.com"
    cookie = { "Cookie" => "session_id=#{@state.fetch('cookie')}" }
    session.patch "/profile", params: { user: { name: "Rails After Go" } }, headers: cookie
    expect(session.response.status == 302 && account.name == "Rails After Go", "Rails cannot edit the profile Go saved (#{session.response.status})")
    replacement = "Rails-After-Go-#{SecureRandom.hex(4)}-Aa1"
    session.patch "/profile/update_password", params: { current_password: @state.fetch("password"), user: { password: replacement, password_confirmation: replacement } }, headers: cookie
    expect(session.response.status == 302 && account.authenticate(replacement).present?, "Rails cannot change the password Go set (#{session.response.status})")
  end
end

AccountVerifier.new(bundle: options[:bundle], cases: options[:cases], database: options[:database], state: options[:state], paths: paths).call
