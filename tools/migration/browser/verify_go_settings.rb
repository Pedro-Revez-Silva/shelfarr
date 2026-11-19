# frozen_string_literal: true

require "optparse"
require "json"
require "fileutils"
require "cgi"
require_relative "../lib/producer_boot"

REPO_ROOT = File.expand_path("../../..", __dir__)

options = {}
OptionParser.new do |parser|
  parser.banner = "Usage: verify_go_settings.rb --bundle PATH --cases PATH --database PATH --state PATH --out NEW_PATH"
  %w[bundle cases database state out].each { |name| parser.on("--#{name} PATH") { |value| options[name.to_sym] = value } }
end.parse!
%i[bundle cases database state out].each { |name| abort "refused: --#{name} is required" unless options[name] }

begin
  paths = Migration::ProducerBoot.call(out: options[:out], repo_root: REPO_ROOT)
rescue Migration::FixtureIsolation::Refused => error
  warn "refused: #{error.message}"
  exit 2
end

class SettingsVerifier
  UNRELATED_COLUMNS = %w[key value value_type category description].freeze

  def initialize(bundle:, cases:, database:, state:, paths:)
    @paths = paths
    @encryption = JSON.parse(File.read(File.join(bundle, "secrets", "credentials.json"))).fetch("encryption")
    document = JSON.parse(File.read(File.join(cases, "cases.json")))
    @cases = cases
    @users = document.fetch("users")
    @state = JSON.parse(File.read(state))
    @database = database
    @failures = []
    @checks = 0
  end

  def call
    install_capture_key
    install_database
    verify_typed_reads
    verify_unrelated_rows
    verify_settings_page
    verify_rails_saves_over_go
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

  def verify_typed_reads
    enabled = SettingsService.get(:open_library_enabled)
    limit = SettingsService.get(:open_library_search_limit)
    expect(enabled == @state.fetch("open_library_enabled") && enabled.is_a?(FalseClass), "Rails reads open_library_enabled as #{enabled.inspect}")
    expect(limit == @state.fetch("open_library_search_limit") && limit.is_a?(Integer), "Rails reads open_library_search_limit as #{limit.inspect}")
    expect(!OpenLibraryClient.configured?, "Rails still treats Open Library as configured")
    expect(!SettingsService.enabled_metadata_providers.include?("openlibrary"), "Rails still searches Open Library: #{SettingsService.enabled_metadata_providers.inspect}")
    expect(MetadataService.send(:provider_limit, "openlibrary", nil) == limit, "Rails asks Open Library for a different number of results")
    rows = Setting.where(key: %w[open_library_enabled open_library_search_limit])
    expect(rows.count == 2 && rows.all?(&:valid?), "Rails finds the Go rows invalid or duplicated: #{rows.map(&:attributes)}")
    expect(rows.all? { |row| row.created_at.is_a?(Time) && row.updated_at.is_a?(Time) }, "Rails cannot read the timestamps Go wrote")
  end

  def verify_unrelated_rows
    current = Setting.where.not(key: %w[open_library_enabled open_library_search_limit]).order(:key).map { |row| row.slice(*UNRELATED_COLUMNS) }
    saved = @state.fetch("unrelated").map { |row| row.slice(*UNRELATED_COLUMNS) }
    expect(current == saved && current.any?, "the other settings differ after Go's save")
  end

  def admin_cookie
    row = Session.create!(user: User.find(@users.fetch("browser_admin")), ip_address: "127.0.0.1")
    jar = ActionDispatch::TestRequest.create.cookie_jar
    jar.signed[:session_id] = { value: row.id, expires: 1.day.from_now }
    { "Cookie" => "session_id=#{CGI.escape(jar[:session_id])}" }
  end

  def verify_settings_page
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! "www.example.com"
    session.get "/admin/settings", headers: admin_cookie.merge("Accept" => "text/html")
    page = Nokogiri::HTML(session.response.body)
    checkbox = page.at_css("input[type=checkbox]#settings_open_library_enabled")
    number = page.at_css("input#settings_open_library_search_limit")
    expect(session.response.status == 200, "Rails' settings page answered #{session.response.status}")
    expect(checkbox && checkbox["checked"].nil?, "Rails' settings page shows Open Library switched on")
    expect(number && number["value"] == @state.fetch("open_library_search_limit").to_s, "Rails' settings page shows #{number&.[]('value').inspect} results")
  end

  def verify_rails_saves_over_go
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! "www.example.com"
    session.patch "/admin/settings/bulk_update", params: { settings: { open_library_enabled: "true", open_library_search_limit: "9" } }, headers: admin_cookie
    expect(session.response.status == 302, "Rails' own save over the Go rows answered #{session.response.status}")
    expect(SettingsService.get(:open_library_enabled) == true && SettingsService.get(:open_library_search_limit) == 9, "Rails could not save over the rows Go wrote")
    expect(Setting.where(key: %w[open_library_enabled open_library_search_limit]).count == 2, "Rails' save over the Go rows duplicated them")
  end
end

SettingsVerifier.new(bundle: options[:bundle], cases: options[:cases], database: options[:database], state: options[:state], paths: paths).call
