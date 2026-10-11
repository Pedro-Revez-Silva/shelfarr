# frozen_string_literal: true

require "test_helper"
require "open3"

class ActiveRecordEncryptionTest < ActiveSupport::TestCase
  PROBE = "cross-process-probe"
  LEGACY = "written-with-the-key-file"

  def random_keys
    ShelfarrEncryptionKeys::REQUIRED.index_with { SecureRandom.base64(32) }
  end

  # Encrypts the way an earlier development process configured with `keys`
  # did: Active Record deriving the key from that primary key and salt.
  def encrypt_with(keys, value)
    config = ActiveRecord::Encryption.config
    original_salt = config.key_derivation_salt
    config.key_derivation_salt = keys["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"]
    # A new generator, as in a freshly booted process; the shared one keeps
    # the salt it first read.
    provider = ActiveRecord::Encryption::DerivedSecretKeyProvider.new(keys["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"],
      key_generator: ActiveRecord::Encryption::KeyGenerator.new)
    ActiveRecord::Encryption.encryptor.encrypt(value, key_provider: provider)
  ensure
    config.key_derivation_salt = original_salt
  end

  test "reads the keys of a persisted key file" do
    keys = random_keys
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".encryption_keys")
      File.write(path, keys.map { |name, value| %(export #{name}="#{value}"\n) }.join + %(export OTHER="x"\n))
      assert_equal keys, ShelfarrEncryptionKeys.read(path)
    end
    assert_equal({}, ShelfarrEncryptionKeys.read("/nonexistent/.encryption_keys"))
  end

  test "a value written with the persisted development keys stays readable" do
    keys = random_keys
    connection = HardcoverConnection.create!(user: users(:one), auth_method: "oauth", access_token: "current", hardcover_user_id: 1)
    # The SQL fragment form writes the ciphertext as is, without encrypting it again.
    HardcoverConnection.where(id: connection.id).update_all([ "access_token = ?", encrypt_with(keys, "written-by-a-job") ])
    unreadable = begin
      HardcoverConnection.find(connection.id).access_token
    rescue ActiveRecord::Encryption::Errors::Decryption
      :decryption_error
    end
    assert_not_equal "written-by-a-job", unreadable, "the configured keys alone cannot read it"

    previous = ActiveRecord::Encryption.config.previous_schemes.dup
    begin
      ActiveRecord::Encryption.config.previous = [ ShelfarrEncryptionKeys.previous_scheme(keys) ]
      model = Class.new(ApplicationRecord) do
        self.table_name = "hardcover_connections"
        encrypts :access_token
      end
      record = model.find(connection.id)
      assert_equal "written-by-a-job", record.access_token
      record.update!(access_token: "rewritten")
      assert_equal "rewritten", HardcoverConnection.find(connection.id).access_token, "new writes use the configured keys"
    ensure
      ActiveRecord::Encryption.config.previous_schemes = previous
    end
  end

  # Copies what booting the application needs into `dir`, so a development
  # process can run there with its own key file and database instead of this
  # checkout's.
  def copy_application(dir)
    root = Rails.root
    (%w[app bin config db lib public vendor Gemfile Gemfile.lock Rakefile config.ru .bundle] & Dir.children(root)).each do |entry|
      FileUtils.cp_r(root.join(entry), dir)
    end
    %w[storage tmp log].each { |entry| FileUtils.mkdir_p(File.join(dir, entry)) }
  end

  # Boots the development environment the way `bin/dev` does, in a copy of
  # the application whose key file holds `persisted`, with `env` as the
  # encryption variables. The process reads `legacy` (a value written with
  # the persisted keys) through every encrypted attribute, encrypts a probe,
  # and has a second process started from it (inheriting its environment,
  # like the Solid Queue supervisor Puma spawns) decrypt it. Only booleans
  # are printed, never keys or ciphertext.
  def boot_development(persisted:, env:, legacy:)
    Dir.mktmpdir do |dir|
      copy_application(dir)
      key_file = File.join(dir, "storage", ".encryption_keys")
      File.write(key_file, persisted.map { |name, value| %(export #{name}="#{value}"\n) }.join)
      File.chmod(0o600, key_file)

      scripts = Dir.mktmpdir
      child = File.join(scripts, "child.rb")
      File.write(child, <<~RUBY)
        probe = $stdin.read
        outcome = begin
          ActiveRecord::Encryption.encryptor.decrypt(probe) == #{PROBE.dump}
        rescue StandardError => e
          e.class.name
        end
        puts "RESULT=\#{outcome}"
      RUBY
      parent = File.join(scripts, "parent.rb")
      File.write(parent, <<~RUBY)
        require "open3"
        require "json"
        ActiveRecord::Schema.verbose = false
        load Rails.root.join("db/schema.rb")
        Rails.application.eager_load!
        legacy = $stdin.read
        readable = ActiveRecord::Base.descendants.reject(&:abstract_class?).each_with_object({}) do |model, found|
          model.encrypted_attributes.to_a.each do |attribute|
            found["\#{model.name}.\#{attribute}"] = begin
              model.type_for_attribute(attribute.to_s).deserialize(legacy) == #{LEGACY.dump}
            rescue StandardError => e
              e.class.name
            end
          end
        end
        puts "LEGACY=\#{readable.to_json}"
        probe = ActiveRecord::Encryption.encryptor.encrypt(#{PROBE.dump})
        out, _status = Open3.capture2(Gem.ruby, "bin/rails", "runner", #{child.dump}, stdin_data: probe, chdir: Rails.root.to_s)
        puts out.lines.grep(/RESULT=/).last
      RUBY

      # COVERAGE would make bin/rails start SimpleCov, and its coverage gate,
      # in these probe processes.
      process_env = { "RAILS_ENV" => "development", "COVERAGE" => nil }
      ShelfarrEncryptionKeys::REQUIRED.each { |name| process_env[name] = env[name] }
      out, status = Open3.capture2e(process_env, Gem.ruby, "bin/rails", "runner", parent, stdin_data: legacy, chdir: dir)
      FileUtils.rm_rf(scripts)

      assert status.success?, out.lines.last(5).join
      [ JSON.parse(out.lines.grep(/\ALEGACY=/).last.to_s.delete_prefix("LEGACY=").presence || "{}"),
        out.lines.grep(/\ARESULT=/).last&.strip ]
    end
  end

  ENCRYPTED_ATTRIBUTES = %w[
    HardcoverConnection.access_token HardcoverConnection.refresh_token User.otp_secret User.backup_codes
    DownloadClient.password DownloadClient.api_key AcquisitionProvider.api_key
    OwnedLibraryConnection.bridge_token OwnedLibraryConnection.auth_session_id OwnedLibraryConnection.auth_login_url
  ].freeze

  {
    # The variables `bin/dev` starts with: development's fixed keys.
    "without encryption variables" => [],
    # Only the primary key is set, to the persisted one; the salt stays at its
    # development default, so the derived key still differs.
    "with only the persisted primary key set" => %w[ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY],
    # Every key matches the file; nothing earlier needs another scheme.
    "with the persisted keys set" => ShelfarrEncryptionKeys::REQUIRED
  }.each do |label, from_file|
    test "development #{label} reads values written with a key file and shares its keys with processes it starts" do
      persisted = random_keys
      readable, result = boot_development(persisted: persisted, env: persisted.slice(*from_file),
        legacy: encrypt_with(persisted, LEGACY))

      assert_equal "RESULT=true", result, "a process started from the server reads what it encrypted"
      assert_empty ENCRYPTED_ATTRIBUTES - readable.keys, "every encrypted attribute was checked"
      assert_equal readable.keys.index_with(true), readable, "every encrypted attribute reads the earlier value"
    end
  end
end
