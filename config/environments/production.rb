require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.enable_reloading = false

  config.eager_load = true

  config.consider_all_requests_local = false

  config.action_controller.perform_caching = true

  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  config.active_storage.service = :local

  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  config.silence_healthcheck_path = "/up"

  config.active_support.report_deprecations = false

  config.cache_store = :solid_cache_store

  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  config.action_mailer.default_url_options = { host: "example.com" }

  config.i18n.fallbacks = true

  config.active_record.dump_schema_after_migration = false

  config.active_record.attributes_for_inspect = [ :id ]

  # Active Record Encryption - keys are loaded by initializers/active_record_encryption.rb
  # Skip during asset precompilation (dummy keys used during Docker build)
  unless ENV["SECRET_KEY_BASE_DUMMY"]
    config.active_record.encryption.primary_key = ENV.fetch("ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY")
    config.active_record.encryption.deterministic_key = ENV.fetch("ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY")
    config.active_record.encryption.key_derivation_salt = ENV.fetch("ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT")
  end
end
