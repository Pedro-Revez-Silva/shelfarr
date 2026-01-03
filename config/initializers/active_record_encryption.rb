# frozen_string_literal: true

# Ensure Active Record encryption keys exist for encrypted attributes.
# In production and development, fall back to a persisted key file if env vars are missing.
return if Rails.env.test?

required_keys = %w[
  ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY
  ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
  ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT
].freeze

missing_keys = required_keys.reject { |key| ENV[key].present? }

if missing_keys.any?
  key_file = Rails.root.join("storage", ".encryption_keys")

  if File.exist?(key_file)
    File.read(key_file).each_line do |line|
      if line =~ /export\s+(\w+)=\"([^\"]+)\"/
        ENV[$1] ||= $2
      end
    end
  else
    require "securerandom"

    ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"] = SecureRandom.base64(32)
    ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"] = SecureRandom.base64(32)
    ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"] = SecureRandom.base64(32)

    File.write(
      key_file,
      <<~KEYS
        export ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=\"#{ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"]}\"
        export ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=\"#{ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"]}\"
        export ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=\"#{ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"]}\"
      KEYS
    )
    File.chmod(0o600, key_file)
  end
end
