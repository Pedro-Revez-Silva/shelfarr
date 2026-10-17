# frozen_string_literal: true

# Ensure Active Record encryption keys exist for encrypted attributes.
# In production, fall back to a persisted key file if env vars are missing.
# This is needed because Thruster doesn't pass env vars to the Rails subprocess.
#
# Development chooses its keys in config/environments/development.rb, before
# this file runs: the ACTIVE_RECORD_ENCRYPTION_* variables when set, otherwise
# fixed development keys. Setting those variables here would not change this
# process's keys, only those of processes started from it later (such as the
# Solid Queue supervisor Puma spawns), which then could not read what this
# process wrote. Earlier versions did exactly that, so values a development
# process wrote with the persisted keys stay readable as a previous scheme.
module ShelfarrEncryptionKeys
  REQUIRED = %w[
    ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY
    ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
    ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT
  ].freeze

  module_function

  def key_file
    Rails.root.join("storage", ".encryption_keys")
  end

  def read(path)
    return {} unless File.exist?(path)

    File.read(path).each_line.filter_map do |line|
      [ $1, $2 ] if line =~ /^export\s+(\w+)="([^"]+)"$/
    end.to_h.slice(*REQUIRED)
  end

  # Whether `keys` derive the same encryption key as `config`. Keys are
  # derived from the primary key and the salt, so a file sharing only the
  # primary key (with the salt left to its development default) still wrote
  # values the configured keys cannot read.
  def derives_like?(keys, config)
    keys["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"] == config.primary_key &&
      keys["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"] == config.key_derivation_salt
  end

  # A previous encryption scheme that decrypts values encrypted with `keys`,
  # derived the way Active Record derives them from its configured primary
  # key and salt (SHA256, and SHA1 as Active Record also accepts).
  def previous_scheme(keys)
    primary = keys["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"]
    salt = keys["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"]
    return if primary.blank? || salt.blank?

    length = ActiveRecord::Encryption.cipher.key_length
    derived = [ OpenSSL::Digest::SHA256, OpenSSL::Digest::SHA1 ].map do |digest|
      ActiveRecord::Encryption::Key.new(ActiveSupport::KeyGenerator.new(primary, hash_digest_class: digest).generate_key(salt, length))
    end
    { key_provider: ActiveRecord::Encryption::KeyProvider.new(derived) }
  end
end

return if Rails.env.test?

if Rails.env.development?
  persisted = ShelfarrEncryptionKeys.read(ShelfarrEncryptionKeys.key_file)
  if persisted.any? && !ShelfarrEncryptionKeys.derives_like?(persisted, Rails.application.config.active_record.encryption)
    ActiveSupport.on_load(:active_record_encryption) do
      scheme = ShelfarrEncryptionKeys.previous_scheme(persisted)
      ActiveRecord::Encryption.config.previous = [ scheme ] if scheme
    end
  end
  return
end

required_keys = ShelfarrEncryptionKeys::REQUIRED

missing_keys = required_keys.reject { |key| ENV[key].present? }

if missing_keys.any?
  key_file = ShelfarrEncryptionKeys.key_file

  if File.exist?(key_file)
    File.read(key_file).each_line do |line|
      if line =~ /^export\s+(\w+)="([^"]+)"$/
        ENV[$1] ||= $2
      end
    end
  else
    require "securerandom"

    ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"] = SecureRandom.base64(32)
    ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"] = SecureRandom.base64(32)
    ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"] = SecureRandom.base64(32)

    FileUtils.mkdir_p(File.dirname(key_file))
    File.write(
      key_file,
      <<~KEYS
        export ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY="#{ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"]}"
        export ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY="#{ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"]}"
        export ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT="#{ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"]}"
      KEYS
    )
    File.chmod(0o600, key_file)
  end
end
