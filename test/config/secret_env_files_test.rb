# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"

class SecretEnvFilesTest < ActiveSupport::TestCase
  SECRET = "shelfarr-test-secret"

  test "boot loads a credential from NAME_FILE and strips one trailing newline" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "oidc_client_secret")
      File.write(path, "#{SECRET}\n")

      output, error, status = boot(env_for("SHELFARR_SETTING_OIDC_CLIENT_SECRET_FILE" => path))

      assert status.success?, error
      assert_equal SECRET, output
    end
  end

  test "boot fails when a credential and its file are both set" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "secret_key_base")
      File.write(path, "#{SECRET}\n")

      _output, error, status = boot(
        env_for(
          "SECRET_KEY_BASE" => "inline-secret",
          "SECRET_KEY_BASE_FILE" => path
        )
      )

      assert_not status.success?
      assert_match(/Both SECRET_KEY_BASE and SECRET_KEY_BASE_FILE are set/, error)
    end
  end

  test "boot fails when the secret file is missing" do
    _output, error, status = boot(
      env_for("SECRET_KEY_BASE_FILE" => "/tmp/shelfarr-missing-secret-#{Process.pid}")
    )

    assert_not status.success?
    assert_match(/SECRET_KEY_BASE_FILE .+ is unreadable/, error)
  end

  test "load copies the file into the credential and removes the file variable" do
    with_secret_file("#{SECRET}\r\n") do |path|
      env = { "SECRET_KEY_BASE_FILE" => path }

      Shelfarr::SecretEnvFiles.load!(env)

      assert_equal SECRET, env["SECRET_KEY_BASE"]
      assert_not env.key?("SECRET_KEY_BASE_FILE")
    end
  end

  test "load keeps internal newlines and a secret that has no trailing newline" do
    with_secret_file("line1\nline2\n") do |path|
      env = { "RAILS_MASTER_KEY_FILE" => path }
      Shelfarr::SecretEnvFiles.load!(env)
      assert_equal "line1\nline2", env["RAILS_MASTER_KEY"]
    end

    with_secret_file("  #{SECRET}  ") do |path|
      env = { "RAILS_MASTER_KEY_FILE" => path }
      Shelfarr::SecretEnvFiles.load!(env)
      assert_equal "  #{SECRET}  ", env["RAILS_MASTER_KEY"]
    end
  end

  test "load follows a symlink to the secret file" do
    with_secret_file("#{SECRET}\n") do |path|
      Dir.mktmpdir do |dir|
        link = File.join(dir, "linked-secret")
        File.symlink(path, link)
        env = { "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY_FILE" => link }

        Shelfarr::SecretEnvFiles.load!(env)

        assert_equal SECRET, env["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"]
      end
    end
  end

  test "an empty credential does not conflict with its file" do
    with_secret_file("#{SECRET}\n") do |path|
      env = { "SECRET_KEY_BASE" => "", "SECRET_KEY_BASE_FILE" => path }

      Shelfarr::SecretEnvFiles.load!(env)

      assert_equal SECRET, env["SECRET_KEY_BASE"]
    end
  end

  test "a blank file variable is left unset" do
    env = { "SECRET_KEY_BASE_FILE" => "" }

    Shelfarr::SecretEnvFiles.load!(env)

    assert_equal "", env["SECRET_KEY_BASE_FILE"]
    assert_nil env["SECRET_KEY_BASE"]
  end

  test "both a credential and its file set fails without changing either" do
    with_secret_file("from-file\n") do |path|
      env = {
        "SHELFARR_SETTING_WEBHOOK_TOKEN" => "inline",
        "SHELFARR_SETTING_WEBHOOK_TOKEN_FILE" => path
      }

      error = assert_raises(Shelfarr::SecretEnvFiles::Error) do
        Shelfarr::SecretEnvFiles.load!(env)
      end

      assert_match(/Both SHELFARR_SETTING_WEBHOOK_TOKEN and SHELFARR_SETTING_WEBHOOK_TOKEN_FILE are set/, error.message)
      assert_equal "inline", env["SHELFARR_SETTING_WEBHOOK_TOKEN"]
      assert_equal path, env["SHELFARR_SETTING_WEBHOOK_TOKEN_FILE"]
    end
  end

  test "a missing secret file fails clearly" do
    path = File.join(Dir.tmpdir, "shelfarr-missing-#{Process.pid}-#{SecureRandom.hex(4)}")
    env = { "SHELFARR_SETTING_OIDC_CLIENT_SECRET_FILE" => path }

    error = assert_raises(Shelfarr::SecretEnvFiles::Error) do
      Shelfarr::SecretEnvFiles.load!(env)
    end

    assert_match(/SHELFARR_SETTING_OIDC_CLIENT_SECRET_FILE #{Regexp.escape(path)} is unreadable/, error.message)
    assert_nil env["SHELFARR_SETTING_OIDC_CLIENT_SECRET"]
    assert_equal path, env["SHELFARR_SETTING_OIDC_CLIENT_SECRET_FILE"]
  end

  test "a directory secret path fails clearly" do
    Dir.mktmpdir do |dir|
      env = { "SHELFARR_SETTING_HARDCOVER_OAUTH_CLIENT_SECRET_FILE" => dir }

      error = assert_raises(Shelfarr::SecretEnvFiles::Error) do
        Shelfarr::SecretEnvFiles.load!(env)
      end

      assert_match(/SHELFARR_SETTING_HARDCOVER_OAUTH_CLIENT_SECRET_FILE #{Regexp.escape(dir)}/, error.message)
      assert_nil env["SHELFARR_SETTING_HARDCOVER_OAUTH_CLIENT_SECRET"]
    end
  end

  test "an unreadable secret file fails clearly" do
    with_secret_file("#{SECRET}\n") do |path|
      File.chmod(0o000, path)
      env = { "SHELFARR_SETTING_OIDC_CLIENT_SECRET_FILE" => path }
      # Root ignores mode bits, so this process cannot observe EACCES.
      next if Process.uid.zero?

      error = assert_raises(Shelfarr::SecretEnvFiles::Error) do
        Shelfarr::SecretEnvFiles.load!(env)
      end

      assert_match(/SHELFARR_SETTING_OIDC_CLIENT_SECRET_FILE #{Regexp.escape(path)} is unreadable/, error.message)
      assert_nil env["SHELFARR_SETTING_OIDC_CLIENT_SECRET"]
      assert_equal path, env["SHELFARR_SETTING_OIDC_CLIENT_SECRET_FILE"]
    end
  end

  test "a secret file that is not valid UTF-8 fails clearly" do
    with_secret_file("secret\xff\n".b) do |path|
      env = { "SECRET_KEY_BASE_FILE" => path }

      error = assert_raises(Shelfarr::SecretEnvFiles::Error) do
        Shelfarr::SecretEnvFiles.load!(env)
      end

      assert_match(/SECRET_KEY_BASE_FILE #{Regexp.escape(path)} is not valid UTF-8/, error.message)
      assert_nil env["SECRET_KEY_BASE"]
    end
  end

  test "loading does not consume unrelated file variables" do
    env = {
      "SHELFARR_LIBATION_TOKEN_FILE" => "/run/shelfarr-libation/token",
      "SHELFARR_SETTING_OIDC_ENABLED_FILE" => "/run/secrets/enabled",
      "TZ_FILE" => "/etc/timezone"
    }

    Shelfarr::SecretEnvFiles.load!(env)

    assert_equal "/run/shelfarr-libation/token", env["SHELFARR_LIBATION_TOKEN_FILE"]
    assert_nil env["SHELFARR_LIBATION_TOKEN"]
    assert_equal "/run/secrets/enabled", env["SHELFARR_SETTING_OIDC_ENABLED_FILE"]
    assert_nil env["SHELFARR_SETTING_OIDC_ENABLED"]
    assert_equal "/etc/timezone", env["TZ_FILE"]
    assert_nil env["TZ"]
  end

  test "a loaded credential becomes the settings env override" do
    with_secret_file("#{SECRET}\n") do |path|
      env = {}
      env["SHELFARR_SETTING_OIDC_CLIENT_SECRET_FILE"] = path
      Shelfarr::SecretEnvFiles.load!(env)

      with_env(env) do
        assert_equal SECRET, SettingsService.get(:oidc_client_secret)
        assert SettingsService.env_managed?(:oidc_client_secret)
        assert_not_includes SettingsService.unrecognized_env_override_names, "SHELFARR_SETTING_OIDC_CLIENT_SECRET_FILE"
      end
    end
  end

  test "credential file names cover rails secrets and every env-overridable secret setting" do
    setting_names = SettingsService::DEFINITIONS.filter_map do |key, definition|
      next unless definition[:env_overridable]
      next unless SettingsService.secret_setting_key?(key)

      SettingsService.env_override_name(key)
    end

    assert_equal setting_names.sort, Shelfarr::SecretEnvFiles::SETTING_SECRETS.sort
    assert_equal ShelfarrEncryptionKeys::REQUIRED, Shelfarr::SecretEnvFiles::ENCRYPTION_KEYS
    assert_includes Shelfarr::SecretEnvFiles::NAMES, "SECRET_KEY_BASE"
    assert_includes Shelfarr::SecretEnvFiles::NAMES, "RAILS_MASTER_KEY"
  end

  test "docker entrypoint treats a secret file as configured and skips generation" do
    source = Rails.root.join("bin/docker-entrypoint").read
    function = source[/^env_configured\(\) \{\n(?:.*\n)*?\}/]
    assert function, "docker entrypoint must define env_configured"
    secret_condition = "if ! env_configured RAILS_MASTER_KEY && ! env_configured SECRET_KEY_BASE; then"
    assert_includes source, secret_condition

    assert_equal "keep", entrypoint_decision(function, secret_condition, "SECRET_KEY_BASE_FILE" => "/run/secrets/secret_key_base")
    assert_equal "keep", entrypoint_decision(function, secret_condition, "RAILS_MASTER_KEY_FILE" => "/run/secrets/master")
    assert_equal "keep", entrypoint_decision(function, secret_condition, "SECRET_KEY_BASE" => "inline")
    assert_equal "keep", entrypoint_decision(
      function,
      secret_condition,
      "SECRET_KEY_BASE" => "",
      "SECRET_KEY_BASE_FILE" => "/run/secrets/secret_key_base"
    )
    assert_equal "generate", entrypoint_decision(function, secret_condition)
    assert_equal "generate", entrypoint_decision(function, secret_condition, "SECRET_KEY_BASE" => "", "SECRET_KEY_BASE_FILE" => "")

    persisted = persisted_encryption_keys
    exports = encryption_key_exports(persisted)
    loaded, contents = run_entrypoint_encryption({}, persisted: persisted)
    assert_equal persisted, loaded
    assert_equal exports, contents

    loaded, contents = run_entrypoint_encryption(
      { "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "inline-primary" },
      persisted: persisted
    )
    assert_equal "inline-primary", loaded["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"]
    assert_nil loaded["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"]
    assert_nil loaded["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"]
    assert_equal exports, contents

    [
      { "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY_FILE" => "/run/secrets/primary" },
      { "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT_FILE" => "/run/secrets/salt" }
    ].each do |env|
      loaded, contents = run_entrypoint_encryption(env, persisted: persisted)
      assert_nil loaded["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"], env.inspect
      assert_equal exports, contents
    end

    loaded, contents = run_entrypoint_encryption({})
    assert loaded.values.all?(&:present?)
    assert_equal loaded.size, loaded.values.uniq.size
    loaded.each do |name, value|
      assert_includes contents, %(export #{name}="#{value}")
    end
  end

  test "docker entrypoint loads persisted encryption keys when only the salt is inline" do
    keys = persisted_encryption_keys
    loaded, contents = run_entrypoint_encryption(
      { "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => "inline-salt" },
      persisted: keys
    )

    assert_equal keys, loaded
    assert_equal encryption_key_exports(keys), contents
  end

  test "docker entrypoint loads persisted encryption keys when only the deterministic key is inline" do
    keys = persisted_encryption_keys
    loaded, contents = run_entrypoint_encryption(
      { "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" => "inline-deterministic" },
      persisted: keys
    )

    assert_equal keys, loaded
    assert_equal encryption_key_exports(keys), contents
  end

  private

  def with_secret_file(contents)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "secret")
      File.binwrite(path, contents)
      yield path
    end
  end

  def env_for(overrides)
    {
      "COVERAGE" => nil,
      "BUNDLE_GEMFILE" => Rails.root.join("Gemfile").to_s,
      "SECRET_KEY_BASE" => nil,
      "SECRET_KEY_BASE_FILE" => nil,
      "SHELFARR_SETTING_OIDC_CLIENT_SECRET" => nil,
      "SHELFARR_SETTING_OIDC_CLIENT_SECRET_FILE" => nil
    }.merge(overrides)
  end

  def boot(env)
    Open3.capture3(
      env,
      RbConfig.ruby,
      "-e",
      'require "./config/boot"; STDOUT.write(ENV.fetch("SHELFARR_SETTING_OIDC_CLIENT_SECRET", ENV["SECRET_KEY_BASE"].to_s))',
      chdir: Rails.root.to_s
    )
  end

  def persisted_encryption_keys
    {
      "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "persisted-primary",
      "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" => "persisted-deterministic",
      "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => "persisted-salt"
    }
  end

  def encryption_key_exports(keys)
    ShelfarrEncryptionKeys::REQUIRED.map { |name| %(export #{name}="#{keys.fetch(name)}"\n) }.join
  end

  def run_entrypoint_encryption(env, persisted: nil)
    source = Rails.root.join("bin/docker-entrypoint").read
    functions = source[/^env_configured\(\) \{\n(?:.*\n)*?\}/]
    block = source[/^ENCRYPTION_FILE="\/rails\/storage\/\.encryption_keys"\n(?:.*\n)*?^fi\n/]
    assert functions, "docker entrypoint must define env_configured"
    assert_includes block.to_s, 'source "$ENCRYPTION_FILE"'

    Dir.mktmpdir do |dir|
      path = File.join(dir, ".encryption_keys")
      File.write(path, encryption_key_exports(persisted)) if persisted
      script = <<~BASH
        set -e
        #{functions}
        #{block.sub(/\AENCRYPTION_FILE="[^"]*"/, "ENCRYPTION_FILE=#{Shellwords.escape(path)}")}
        for name in \
          ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY \
          ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY \
          ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT
        do
          if [ -n "${!name+x}" ]; then
            printf '%s=%s\\n' "$name" "${!name}"
          else
            printf '%s=<UNSET>\\n' "$name"
          fi
        done
      BASH
      output, status = Open3.capture2e(entrypoint_env(env), "bash", "-c", script)
      assert status.success?, output
      keys = output.lines.filter_map do |line|
        match = line.match(/\A(ACTIVE_RECORD_ENCRYPTION_[A-Z_]+)=(.*)\n\z/)
        next unless match
        next unless ShelfarrEncryptionKeys::REQUIRED.include?(match[1])

        [ match[1], match[2] == "<UNSET>" ? nil : match[2] ]
      end.to_h
      assert_equal ShelfarrEncryptionKeys::REQUIRED.sort, keys.keys.sort, output
      [ keys, File.exist?(path) ? File.read(path) : nil ]
    end
  end

  def entrypoint_decision(function, condition, env = {})
    script = <<~BASH
      set -e
      #{function}
      #{condition}
        echo generate
      else
        echo keep
      fi
    BASH
    output, status = Open3.capture2e(entrypoint_env(env), "bash", "-c", script)
    assert status.success?, output
    output.strip
  end

  def entrypoint_env(overrides)
    {
      "SECRET_KEY_BASE" => nil,
      "RAILS_MASTER_KEY" => nil,
      "SECRET_KEY_BASE_FILE" => nil,
      "RAILS_MASTER_KEY_FILE" => nil,
      "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => nil,
      "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" => nil,
      "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => nil,
      "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY_FILE" => nil,
      "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY_FILE" => nil,
      "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT_FILE" => nil
    }.merge(overrides)
  end
end
