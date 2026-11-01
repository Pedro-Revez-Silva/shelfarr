# frozen_string_literal: true

module Shelfarr
  # Docker secrets expose a credential as a file. NAME_FILE is read once at
  # boot, before Rails uses the value, and assigned to NAME.
  module SecretEnvFiles
    class Error < StandardError; end

    RAILS_SECRETS = %w[
      SECRET_KEY_BASE
      RAILS_MASTER_KEY
    ].freeze
    ENCRYPTION_KEYS = %w[
      ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY
      ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
      ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT
    ].freeze
    SETTING_SECRETS = %w[
      SHELFARR_SETTING_HARDCOVER_OAUTH_CLIENT_SECRET
      SHELFARR_SETTING_OIDC_CLIENT_SECRET
      SHELFARR_SETTING_WEBHOOK_TOKEN
    ].freeze
    NAMES = (RAILS_SECRETS + ENCRYPTION_KEYS + SETTING_SECRETS).freeze

    class << self
      def load!(env = ENV)
        NAMES.each { |name| load_name(env, name) }
        env
      end

      private

      def load_name(env, name)
        file_name = "#{name}_FILE"
        path = env[file_name]
        return if path.nil? || path.empty?

        current = env[name]
        if !current.nil? && !current.empty?
          raise Error, "Both #{name} and #{file_name} are set. Set only one."
        end

        env[name] = read_secret(file_name, path)
        env.delete(file_name)
      end

      def read_secret(file_name, path)
        secret = File.open(path, "rb") { |file| read_regular_file(file, file_name, path) }
        secret.force_encoding(Encoding::UTF_8)
        raise Error, "#{file_name} #{path} is not valid UTF-8" unless secret.valid_encoding?

        secret
      rescue SystemCallError => error
        raise Error, "#{file_name} #{path} is unreadable: #{error.message}"
      end

      def read_regular_file(file, file_name, path)
        raise Error, "#{file_name} #{path} is not a regular file" unless file.stat.file?

        file.read.chomp
      end
    end
  end
end
