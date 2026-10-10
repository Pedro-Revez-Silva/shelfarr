# frozen_string_literal: true

require "test_helper"
require "open3"

class ActiveRecordEncryptionTest < ActiveSupport::TestCase
  PROBE = "cross-process-probe"

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

  # Boots the development environment the way `bin/dev` does, with no
  # encryption variables, encrypts a probe, and has a second process started
  # from it (inheriting its environment, like the Solid Queue supervisor Puma
  # spawns) decrypt it. Only the probe and booleans are printed.
  test "a process started from a development server can read what the server encrypted" do
    Dir.mktmpdir do |dir|
      child = File.join(dir, "child.rb")
      File.write(child, <<~RUBY)
        probe = $stdin.read
        outcome = begin
          ActiveRecord::Encryption.encryptor.decrypt(probe) == #{PROBE.dump}
        rescue StandardError => e
          e.class.name
        end
        puts "RESULT=\#{outcome}"
      RUBY
      parent = File.join(dir, "parent.rb")
      File.write(parent, <<~RUBY)
        require "open3"
        probe = ActiveRecord::Encryption.encryptor.encrypt(#{PROBE.dump})
        out, _status = Open3.capture2(Gem.ruby, "bin/rails", "runner", #{child.dump}, stdin_data: probe, chdir: Rails.root.to_s)
        puts out.lines.grep(/RESULT=/).last
      RUBY

      # COVERAGE would make bin/rails start SimpleCov, and its coverage gate,
      # in these probe processes.
      env = { "RAILS_ENV" => "development", "COVERAGE" => nil }
      ShelfarrEncryptionKeys::REQUIRED.each { |name| env[name] = nil }
      out, status = Open3.capture2e(env, Gem.ruby, "bin/rails", "runner", parent, chdir: Rails.root.to_s)

      assert status.success?, out.lines.last(5).join
      assert_equal "RESULT=true", out.lines.grep(/RESULT=/).last&.strip
    end
  end
end
