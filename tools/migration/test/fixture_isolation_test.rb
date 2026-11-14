# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/fixture_isolation"

class FixtureIsolationTest < Minitest::Test
  Isolation = Migration::FixtureIsolation

  class FakeConfigurations
    def initialize(configs)
      @configs = configs
    end

    def configs_for(env_name:)
      env_name == "test" ? @configs : []
    end
  end

  def setup
    @scratch = Dir.mktmpdir("fixture-isolation", ENV.fetch("TMPDIR", Dir.home))
    @repo = File.join(@scratch, "repo")
    FileUtils.mkdir_p(@repo)
    @out = File.join(@scratch, "bundle")
  end

  def teardown
    FileUtils.rm_rf(@scratch)
  end

  def prepare(out: @out, env: {})
    Isolation.prepare!(out: out, repo_root: @repo, env: env)
  end

  def test_creates_a_private_layout_and_points_every_database_inside_it
    env = {}
    paths = prepare(env: env)
    assert_equal 0o700, File.stat(paths.out).mode & 0o777
    assert_equal 0o700, File.stat(paths.secrets).mode & 0o777
    paths.database_files.each { |file| assert File.dirname(file).start_with?(paths.out), file }
    assert_equal "test", env["RAILS_ENV"]
    %w[DATABASE_URL QUEUE_DATABASE_URL CABLE_DATABASE_URL].each do |name|
      assert env.fetch(name).start_with?("sqlite3://#{paths.out}/"), name
    end
    assert env["TMPDIR"].start_with?(paths.out)
    assert env["BOOTSNAP_CACHE_DIR"].start_with?(paths.out)
    refute_empty env["SECRET_KEY_BASE"]
    assert_equal "true", env["BUNDLE_FROZEN"]
  end

  def test_refuses_an_output_directory_inside_the_repository
    assert_refused { prepare(out: File.join(@repo, "storage", "fixture")) }
    assert_refused { prepare(out: File.join(@repo, "fixture")) }
    assert_refused { prepare(out: @repo) }
  end

  def test_refuses_relative_missing_parent_existing_and_symlinked_output
    assert_refused { prepare(out: "relative/bundle") }
    assert_refused { prepare(out: nil) }
    assert_refused { prepare(out: File.join(@scratch, "absent-parent", "bundle")) }
    FileUtils.mkdir_p(@out)
    assert_refused { prepare }
    FileUtils.rm_rf(@out)
    File.symlink(@repo, @out)
    assert_refused { prepare }
  end

  def test_refuses_a_parent_that_resolves_into_the_repository
    link = File.join(@scratch, "link-to-repo")
    File.symlink(@repo, link)
    assert_refused { prepare(out: File.join(link, "bundle")) }
  end

  def test_refuses_inherited_configuration
    forbidden = {
      "RAILS_ENV" => "production", "DATABASE_URL" => "sqlite3:///x", "QUEUE_DATABASE_URL" => "x", "SECRET_KEY_BASE" => "x",
      "SECRET_KEY_BASE_FILE" => "/x", "RAILS_MASTER_KEY" => "x", "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "x",
      "SHELFARR_TEST_DB" => "x", "KOBO_KEPUB_CACHE_PATH" => "/x", "ANY_CREDENTIAL_FILE" => "/x"
    }
    forbidden.each do |name, value|
      assert_refused("#{name} was accepted") { prepare(env: { name => value }) }
      refute File.exist?(@out), "#{name} left a directory behind"
    end
    assert prepare(env: { "RAILS_ENV" => "test" })
  end

  def test_error_messages_never_include_values
    error = assert_raises(Isolation::Refused) { prepare(env: { "SECRET_KEY_BASE" => "hunter2-value" }) }
    refute_includes error.message, "hunter2-value"
  end

  def test_database_verification_rejects_paths_outside_the_bundle
    paths = prepare
    config = Struct.new(:name, :database)
    inside = FakeConfigurations.new(paths.database_files.map { |file| config.new("db", file) })
    Isolation.verify_databases!(inside, paths)
    outside = FakeConfigurations.new([ config.new("primary", File.join(@repo, "storage", "test.sqlite3")) ])
    assert_raises(Isolation::Refused) { Isolation.verify_databases!(outside, paths) }
    assert_raises(Isolation::Refused) { Isolation.verify_databases!(FakeConfigurations.new([]), paths) }
  end

  def test_credentials_are_redirected_inside_the_bundle_and_verified
    paths = prepare
    config = Struct.new(:credentials).new(Struct.new(:content_path, :key_path).new(Pathname.new("#{@repo}/config/credentials.yml.enc"), Pathname.new("#{@repo}/config/master.key")))
    assert_raises(Isolation::Refused) { Isolation.verify_credentials!(config, paths) }
    Isolation.redirect_credentials(config, paths)
    Isolation.verify_credentials!(config, paths)
    assert config.credentials.content_path.to_s.start_with?(paths.out)
    assert config.credentials.key_path.to_s.start_with?(paths.out)
    config.credentials.key_path = Pathname.new("#{@repo}/config/master.key")
    assert_raises(Isolation::Refused) { Isolation.verify_credentials!(config, paths) }
  end

  private

  def assert_refused(message = nil, &block)
    assert_raises(Isolation::Refused, message, &block)
  end
end
