Rails.application.configure do
  config.enable_reloading = false

  config.eager_load = ENV["CI"].present?

  config.public_file_server.headers = { "cache-control" => "public, max-age=3600" }

  config.consider_all_requests_local = true
  config.cache_store = :null_store

  # Hardcover background pacing is exercised by dedicated tests; elsewhere stubbed pages should not sleep.
  config.x.hardcover_background_min_interval = 0
  config.x.hardcover_import_item_gap = 0

  config.action_dispatch.show_exceptions = :rescuable

  config.action_controller.allow_forgery_protection = false

  config.active_storage.service = :test

  config.action_mailer.delivery_method = :test

  config.action_mailer.default_url_options = { host: "example.com" }

  config.active_support.deprecation = :stderr

  config.action_controller.raise_on_missing_callback_actions = true

  # Keep the in-process test adapter for most tests. Isolated supervisor
  # probes switch the adapter to :solid_queue and need the queue DB.
  config.solid_queue.connects_to = { database: { writing: :queue } }

  config.active_record.encryption.primary_key = "test_primary_key_for_encryption_1234"
  config.active_record.encryption.deterministic_key = "test_deterministic_key_for_encrypt"
  config.active_record.encryption.key_derivation_salt = "test_key_derivation_salt_for_tests"
end
