# frozen_string_literal: true

require "optparse"
require "json"
require "fileutils"
require "time"
require "active_support/testing/time_helpers"
require_relative "../lib/producer_boot"

REPO_ROOT = File.expand_path("../../..", __dir__)

options = {}
OptionParser.new do |parser|
  parser.banner = "Usage: verify_go_pairing.rb --bundle PATH --cases PATH --database PATH --handoff PATH --out NEW_PATH"
  %w[bundle cases database handoff out].each { |name| parser.on("--#{name} PATH") { |value| options[name.to_sym] = value } }
end.parse!
%i[bundle cases database handoff out].each { |name| abort "refused: --#{name} is required" unless options[name] }

begin
  paths = Migration::ProducerBoot.call(out: options[:out], repo_root: REPO_ROOT)
rescue Migration::FixtureIsolation::Refused => error
  warn "refused: #{error.message}"
  exit 2
end

class Verifier
  include ActiveSupport::Testing::TimeHelpers

  def initialize(paths:, bundle:, cases:, database:, handoff:)
    @paths = paths
    @encryption = JSON.parse(File.read(File.join(bundle, "secrets", "credentials.json"))).fetch("encryption")
    @secrets = JSON.parse(File.read(File.join(cases, "secrets", "pairing.json"))).fetch("handoff")
    @users = JSON.parse(File.read(File.join(cases, "cases.json"))).fetch("users")
    @go = JSON.parse(File.read(handoff))
    @database = database
    @failures = []
    @checks = 0
  end

  def call
    install_database
    travel_to(Time.iso8601(@go.fetch("clock")).utc) do
      verify_rails_reads_what_go_left_of_rails_state
      verify_rails_continues_go_grants
      verify_rails_authenticates_and_adopts_go_tokens
    end
    puts JSON.generate("failures" => @failures, "checks" => @checks)
    exit(@failures.empty? && @checks.positive? ? 0 : 1)
  end

  private

  def expect(condition, message)
    @checks += 1
    @failures << message unless condition
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

  def owner
    User.find(@users.fetch("pair_one"))
  end

  def rails_token(label)
    APIToken.find_by!(token_digest: APIToken.digest(@secrets.fetch(label)))
  end

  def verify_rails_reads_what_go_left_of_rails_state
    pending = ConsumerDeviceGrant.for_user_code(@secrets.fetch("pending_user"))
    expect(pending&.approved_at && pending.consumed_at && pending.user_id == owner.id, "Go decided and exchanged the Rails pending grant, and Rails reads it as approved by the Go session account and consumed")
    token = APIToken.where(issued_via: APIToken::CONSUMER_DEVICE, name: "Rails pending").first
    expect(token && token.user_id == owner.id && token.scope_list == %w[library:read progress:write] && token.connection_key.present?, "Rails reads the token Go issued for a Rails grant")
    expect(ConsumerDeviceGrant.for_device_code(@secrets.fetch("denied_device")).then { |grant| grant.denied_at && grant.consumed_at.nil? }, "a Rails-denied grant stays denied and unconsumed after Go answered access_denied")
    %w[plain family_a family_b chain_first upgrade_origin].each { |label| expect(rails_token(label).revoked?, "Rails sees #{label} revoked by Go") }
    expect(!rails_token("chain_second").revoked? && rails_token("chain_second").replaces_api_token_id.nil?, "Rails sees the chain adopted by Go")
    replacement = APIToken.where(name: "Rails upgrade").first
    expect(replacement && replacement.replaces_api_token_id.nil? && replacement.connection_key == rails_token("upgrade_origin").connection_key && replacement.scope_list.size == 5, "Rails sees the Go-issued upgrade adopted into the same connection with the whole bundle")
    expect(ConsumerDeviceGrant.for_device_code(@secrets.fetch("family_upgrade_device")).denied_at.present?, "Rails sees the pending family upgrade denied by Go's revoke")
  end

  def go_grant(key)
    entry = @go.fetch(key)
    ConsumerDeviceGrant.for_device_code(entry.fetch("device"))
  end

  def verify_rails_continues_go_grants
    pending = go_grant("go_pending")
    entry = @go.fetch("go_pending")
    expect(pending && pending.pending? && pending.client_name == "Go pending" && pending.scopes.nil? && pending.poll_interval == 5, "Rails reads a Go-created pending grant")
    expect(ConsumerDeviceGrant.for_user_code(entry.fetch("user")) == pending && ConsumerDeviceGrant.for_user_code(entry.fetch("user").downcase) == pending, "Rails finds the Go grant by the displayed user code in any case")
    expect(pending.expires_at - pending.created_at == 600 && pending.device_code_digest == ConsumerDeviceGrant.digest(entry.fetch("device")), "the Go grant lives ten minutes and stores only the digest of the device code")
    expect(pending.decide!(actor: owner, allow: true), "Rails approves a Go-created grant")
    issued = pending.exchange!
    expect(issued[:access_token].to_s.start_with?("shf_") && issued[:scope] == "library:read progress:write", "Rails exchanges a Go-created grant it approved: #{issued.keys}")
    approved = go_grant("go_approved").exchange!
    expect(approved[:scope] == "library:read progress:write search:read requests:read requests:write" && APIToken.authenticate(approved[:access_token])&.user == owner, "Rails exchanges the Go-approved requesting grant")
    denied = go_grant("go_denied").exchange!
    expect(denied == { error: "access_denied" }, "Rails refuses the Go-denied grant")
  end

  def verify_rails_authenticates_and_adopts_go_tokens
    raw = @go.fetch("go_token")
    token = rails_token_for(raw)
    expect(token.token_prefix == raw.first(12) && token.issued_via == "consumer_device" && token.consumer_device? && token.user == owner, "Rails reads the Go token row")
    expect(token.expires_at - token.created_at == 30.days.to_i && token.scopes == %w[library:read progress:write].to_json && token.connection_key.match?(/\A\h{8}-\h{4}-4\h{3}-[89ab]\h{3}-\h{12}\z/), "the Go token has the Rails lifetime, scope JSON and connection key")
    expect(APIToken.authenticate(raw)&.id == token.id && token.has_scope?("library:read") && !token.has_scope?("requests:admin"), "Rails authenticates a Go-issued token")
    origin = rails_token_for(@go.fetch("go_origin"))
    replacement = rails_token_for(@go.fetch("go_replacement"))
    expect(replacement.replaces_api_token_id == origin.id && replacement.connection_key == origin.connection_key && !origin.revoked?, "the Go replacement waits to be used")
    expect(APIToken.authenticate(@go.fetch("go_origin"))&.id == origin.id, "the origin works in Rails before the replacement is used")
    expect(APIToken.authenticate(@go.fetch("go_replacement"))&.id == replacement.id && origin.reload.revoked? && replacement.reload.replaces_api_token_id.nil?, "Rails adopts a Go-issued replacement and retires the origin")
    expect(APIToken.authenticate(@go.fetch("go_origin")).nil?, "the retired Go origin no longer works in Rails")
    replacement.revoke!
    expect(replacement.reload.revoked? && APIToken.authenticate(@go.fetch("go_replacement")).nil?, "Rails revokes a Go-issued connection")
    expect(!token.reload.revoked?, "another connection of the same account is untouched by the revoke")
  end

  def rails_token_for(raw)
    APIToken.find_by!(token_digest: APIToken.digest(raw))
  end
end

Verifier.new(paths: paths, bundle: options[:bundle], cases: options[:cases], database: options[:database], handoff: options[:handoff]).call
