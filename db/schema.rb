# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_10_120000) do
  create_table "acquisition_providers", force: :cascade do |t|
    t.boolean "allow_private_network", default: false, null: false
    t.string "api_key"
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.string "name", null: false
    t.integer "priority", default: 0, null: false
    t.boolean "supports_audiobooks", default: true, null: false
    t.boolean "supports_comicbooks", default: false, null: false
    t.boolean "supports_ebooks", default: true, null: false
    t.integer "timeout_seconds", default: 30, null: false
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.index ["enabled"], name: "index_acquisition_providers_on_enabled"
    t.index ["name"], name: "index_acquisition_providers_on_name", unique: true
    t.index ["priority"], name: "index_acquisition_providers_on_priority"
  end

  create_table "activity_logs", force: :cascade do |t|
    t.string "action", null: false
    t.string "controller"
    t.datetime "created_at", null: false
    t.json "details", default: {}
    t.string "ip_address"
    t.integer "trackable_id"
    t.string "trackable_type"
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.index ["action"], name: "index_activity_logs_on_action"
    t.index ["created_at"], name: "index_activity_logs_on_created_at"
    t.index ["trackable_type", "trackable_id"], name: "index_activity_logs_on_trackable"
    t.index ["trackable_type", "trackable_id"], name: "index_activity_logs_on_trackable_type_and_trackable_id"
    t.index ["user_id"], name: "index_activity_logs_on_user_id"
  end

  create_table "api_tokens", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.datetime "last_used_at"
    t.string "name", null: false
    t.datetime "revoked_at"
    t.text "scopes", default: "[]", null: false
    t.string "token_digest", null: false
    t.string "token_prefix", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.index ["revoked_at"], name: "index_api_tokens_on_revoked_at"
    t.index ["token_digest"], name: "index_api_tokens_on_token_digest", unique: true
    t.index ["token_prefix"], name: "index_api_tokens_on_token_prefix"
    t.index ["user_id"], name: "index_api_tokens_on_user_id"
  end

  create_table "books", force: :cascade do |t|
    t.string "author"
    t.integer "book_type", default: 0, null: false
    t.string "comic_vine_id"
    t.integer "content_kind", default: 0, null: false
    t.string "cover_url"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "file_path"
    t.string "google_books_id"
    t.string "hardcover_id"
    t.string "isbn"
    t.string "issue_number"
    t.string "language", default: "en"
    t.string "metadata_source", default: "openlibrary"
    t.string "narrator"
    t.string "open_library_edition_id"
    t.string "open_library_work_id"
    t.string "publisher"
    t.date "release_date"
    t.string "series"
    t.string "series_position"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.integer "year"
    t.index ["book_type"], name: "index_books_on_book_type"
    t.index ["comic_vine_id"], name: "index_books_on_comic_vine_id"
    t.index ["content_kind"], name: "index_books_on_content_kind"
    t.index ["google_books_id"], name: "index_books_on_google_books_id"
    t.index ["hardcover_id"], name: "index_books_on_hardcover_id"
    t.index ["isbn"], name: "index_books_on_isbn"
    t.index ["open_library_edition_id"], name: "index_books_on_open_library_edition_id"
    t.index ["open_library_work_id"], name: "index_books_on_open_library_work_id"
    t.index ["series_position"], name: "index_books_on_series_position"
  end

  create_table "download_clients", force: :cascade do |t|
    t.string "api_key"
    t.string "category"
    t.string "client_type", null: false
    t.datetime "created_at", null: false
    t.string "download_path"
    t.boolean "enabled", default: true, null: false
    t.string "name", null: false
    t.string "password"
    t.integer "priority", default: 0, null: false
    t.integer "torrent_verification_max_attempts", default: 10, null: false
    t.integer "torrent_verification_wait_time", default: 2, null: false
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.string "username"
    t.index ["client_type", "priority"], name: "index_download_clients_on_client_type_and_priority"
    t.index ["enabled"], name: "index_download_clients_on_enabled"
    t.index ["name"], name: "index_download_clients_on_name", unique: true
  end

  create_table "download_routing_rules", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "download_client_id", null: false
    t.string "download_type", null: false
    t.boolean "enabled", default: true, null: false
    t.string "indexer_name", null: false
    t.string "normalized_indexer_name", null: false
    t.string "provider", null: false
    t.datetime "updated_at", null: false
    t.index ["download_client_id"], name: "index_download_routing_rules_on_download_client_id"
    t.index ["enabled"], name: "index_download_routing_rules_on_enabled"
    t.index ["provider", "normalized_indexer_name", "download_type"], name: "index_download_routing_rules_on_route", unique: true
  end

  create_table "downloads", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "download_client_id"
    t.string "download_path"
    t.string "download_type"
    t.string "external_id"
    t.string "name"
    t.integer "not_found_count", default: 0, null: false
    t.string "post_processing_job_id"
    t.integer "progress", default: 0
    t.integer "request_id", null: false
    t.integer "search_result_id"
    t.bigint "size_bytes"
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["download_client_id"], name: "index_downloads_on_download_client_id"
    t.index ["external_id"], name: "index_downloads_on_external_id"
    t.index ["request_id"], name: "index_downloads_on_request_id"
    t.index ["search_result_id"], name: "index_downloads_on_search_result_id"
    t.index ["status"], name: "index_downloads_on_status"
  end

  create_table "library_items", force: :cascade do |t|
    t.string "asin"
    t.string "audiobookshelf_id", null: false
    t.string "author"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "isbn"
    t.string "language"
    t.string "library_id", null: false
    t.string "library_platform", default: "audiobookshelf", null: false
    t.boolean "missing", default: false, null: false
    t.string "narrator"
    t.integer "published_year"
    t.string "publisher"
    t.string "series"
    t.string "series_position"
    t.string "subtitle"
    t.datetime "synced_at"
    t.string "title"
    t.datetime "updated_at", null: false
    t.index ["isbn"], name: "index_library_items_on_isbn"
    t.index ["library_id"], name: "index_library_items_on_library_id"
    t.index ["library_platform", "library_id", "audiobookshelf_id"], name: "idx_on_library_platform_library_id_audiobookshelf_i_c1fd6c7905", unique: true
    t.index ["library_platform"], name: "index_library_items_on_library_platform"
    t.index ["missing"], name: "index_library_items_on_missing"
    t.index ["synced_at"], name: "index_library_items_on_synced_at"
  end

  create_table "metadata_provider_statuses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "failure_count", default: 0, null: false
    t.string "last_error"
    t.datetime "last_failure_at"
    t.datetime "last_success_at"
    t.string "provider", null: false
    t.datetime "rate_limited_until"
    t.string "status", default: "unknown", null: false
    t.datetime "updated_at", null: false
    t.index ["provider"], name: "index_metadata_provider_statuses_on_provider", unique: true
  end

  create_table "notifications", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "message"
    t.integer "notifiable_id"
    t.string "notifiable_type"
    t.string "notification_type", null: false
    t.datetime "read_at"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["notifiable_type", "notifiable_id"], name: "index_notifications_on_notifiable"
    t.index ["user_id", "created_at"], name: "index_notifications_on_user_id_and_created_at"
    t.index ["user_id", "read_at"], name: "index_notifications_on_user_id_and_read_at"
    t.index ["user_id"], name: "index_notifications_on_user_id"
  end

  create_table "request_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.json "details", default: {}
    t.integer "download_id"
    t.string "event_type", null: false
    t.integer "level", default: 0, null: false
    t.text "message"
    t.integer "request_id", null: false
    t.string "source", null: false
    t.datetime "updated_at", null: false
    t.boolean "user_visible", default: false, null: false
    t.index ["created_at"], name: "index_request_events_on_created_at"
    t.index ["download_id"], name: "index_request_events_on_download_id"
    t.index ["event_type"], name: "index_request_events_on_event_type"
    t.index ["request_id"], name: "index_request_events_on_request_id"
  end

  create_table "requests", force: :cascade do |t|
    t.boolean "attention_needed", default: false
    t.integer "book_id", null: false
    t.string "collection_id"
    t.string "collection_source"
    t.string "collection_title"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.string "created_via", default: "web", null: false
    t.string "external_chat_id"
    t.string "external_source"
    t.string "external_user_id"
    t.text "issue_description"
    t.string "language"
    t.datetime "next_retry_at"
    t.text "notes"
    t.string "request_scope", default: "single", null: false
    t.integer "retry_count", default: 0
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["attention_needed"], name: "index_requests_on_attention_needed"
    t.index ["book_id"], name: "index_requests_on_book_id"
    t.index ["collection_source", "collection_id"], name: "index_requests_on_collection_source_and_collection_id"
    t.index ["created_via"], name: "index_requests_on_created_via"
    t.index ["external_source", "external_user_id"], name: "index_requests_on_external_source_and_external_user_id"
    t.index ["next_retry_at"], name: "index_requests_on_next_retry_at"
    t.index ["request_scope"], name: "index_requests_on_request_scope"
    t.index ["status"], name: "index_requests_on_status"
    t.index ["user_id", "status"], name: "index_requests_on_user_id_and_status"
    t.index ["user_id"], name: "index_requests_on_user_id"
  end

  create_table "search_results", force: :cascade do |t|
    t.integer "acquisition_provider_id"
    t.string "blocklist_reason"
    t.datetime "blocklisted_at"
    t.integer "confidence_score"
    t.datetime "created_at", null: false
    t.string "detected_language"
    t.string "download_url"
    t.string "guid", null: false
    t.string "indexer"
    t.string "info_url"
    t.integer "leechers"
    t.string "magnet_url"
    t.json "provider_payload", default: {}
    t.string "provider_result_id"
    t.datetime "published_at"
    t.integer "request_id", null: false
    t.json "score_breakdown"
    t.integer "seeders"
    t.bigint "size_bytes"
    t.string "source", default: "prowlarr"
    t.integer "status", default: 0, null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["acquisition_provider_id", "provider_result_id"], name: "index_search_results_on_provider_result"
    t.index ["acquisition_provider_id"], name: "index_search_results_on_acquisition_provider_id"
    t.index ["request_id", "blocklisted_at"], name: "index_search_results_on_request_id_and_blocklisted_at"
    t.index ["request_id", "guid"], name: "index_search_results_on_request_id_and_guid", unique: true
    t.index ["request_id"], name: "index_search_results_on_request_id"
    t.index ["status"], name: "index_search_results_on_status"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "settings", force: :cascade do |t|
    t.string "category", default: "general"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.text "value"
    t.string "value_type", default: "string", null: false
    t.index ["category"], name: "index_settings_on_category"
    t.index ["key"], name: "index_settings_on_key", unique: true
  end

  create_table "system_healths", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "last_check_at"
    t.datetime "last_success_at"
    t.text "message"
    t.string "service", null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["service"], name: "index_system_healths_on_service", unique: true
    t.index ["status"], name: "index_system_healths_on_status"
  end

  create_table "telegram_chat_authorizations", force: :cascade do |t|
    t.datetime "approved_at"
    t.integer "approved_by_id"
    t.string "chat_id", null: false
    t.string "chat_title"
    t.string "code_digest"
    t.datetime "code_generated_at"
    t.datetime "created_at", null: false
    t.datetime "paused_at"
    t.string "requested_by_telegram_user_id"
    t.string "requested_by_telegram_username"
    t.datetime "updated_at", null: false
    t.index ["approved_at"], name: "index_telegram_chat_authorizations_on_approved_at"
    t.index ["approved_by_id"], name: "index_telegram_chat_authorizations_on_approved_by_id"
    t.index ["chat_id"], name: "index_telegram_chat_authorizations_on_chat_id", unique: true
    t.index ["code_generated_at"], name: "index_telegram_chat_authorizations_on_code_generated_at"
    t.index ["paused_at"], name: "index_telegram_chat_authorizations_on_paused_at"
  end

  create_table "telegram_updates", force: :cascade do |t|
    t.string "chat_id"
    t.string "command"
    t.datetime "created_at", null: false
    t.string "telegram_user_id"
    t.string "update_id", null: false
    t.datetime "updated_at", null: false
    t.index ["telegram_user_id", "created_at"], name: "index_telegram_updates_on_telegram_user_id_and_created_at"
    t.index ["update_id"], name: "index_telegram_updates_on_update_id", unique: true
  end

  create_table "uploads", force: :cascade do |t|
    t.integer "book_id"
    t.integer "book_type"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.text "error_message"
    t.string "file_path"
    t.bigint "file_size"
    t.integer "match_confidence"
    t.string "original_filename"
    t.string "parsed_author"
    t.string "parsed_title"
    t.datetime "processed_at"
    t.integer "request_id"
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["book_id"], name: "index_uploads_on_book_id"
    t.index ["book_type"], name: "index_uploads_on_book_type"
    t.index ["processed_at"], name: "index_uploads_on_processed_at"
    t.index ["request_id"], name: "index_uploads_on_request_id"
    t.index ["status"], name: "index_uploads_on_status"
    t.index ["user_id"], name: "index_uploads_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.text "backup_codes"
    t.datetime "created_at", null: false
    t.datetime "deleted_at"
    t.integer "failed_login_count", default: 0, null: false
    t.datetime "last_failed_login_at"
    t.string "last_failed_login_ip"
    t.datetime "locked_until"
    t.string "name", default: "", null: false
    t.string "oidc_provider"
    t.string "oidc_uid"
    t.boolean "otp_required", default: false, null: false
    t.string "otp_secret"
    t.string "password_digest", null: false
    t.integer "role", default: 0, null: false
    t.datetime "telegram_link_token_created_at"
    t.string "telegram_link_token_digest"
    t.string "telegram_user_id"
    t.string "telegram_username"
    t.datetime "updated_at", null: false
    t.string "username", null: false
    t.index ["deleted_at"], name: "index_users_on_deleted_at"
    t.index ["oidc_provider", "oidc_uid"], name: "index_users_on_oidc_provider_and_uid_unique", unique: true, where: "deleted_at IS NULL AND oidc_provider IS NOT NULL AND oidc_uid IS NOT NULL"
    t.index ["role"], name: "index_users_on_role"
    t.index ["telegram_link_token_digest"], name: "index_users_on_telegram_link_token_digest"
    t.index ["telegram_user_id"], name: "index_users_on_telegram_user_id_unique", unique: true, where: "deleted_at IS NULL AND telegram_user_id IS NOT NULL"
    t.index ["username"], name: "index_users_on_username", unique: true, where: "deleted_at IS NULL"
  end

  add_foreign_key "activity_logs", "users"
  add_foreign_key "api_tokens", "users"
  add_foreign_key "download_routing_rules", "download_clients"
  add_foreign_key "downloads", "requests"
  add_foreign_key "downloads", "search_results", on_delete: :nullify
  add_foreign_key "notifications", "users"
  add_foreign_key "request_events", "downloads"
  add_foreign_key "request_events", "requests"
  add_foreign_key "requests", "books"
  add_foreign_key "requests", "users"
  add_foreign_key "search_results", "acquisition_providers"
  add_foreign_key "search_results", "requests"
  add_foreign_key "sessions", "users"
  add_foreign_key "telegram_chat_authorizations", "users", column: "approved_by_id"
  add_foreign_key "uploads", "books"
  add_foreign_key "uploads", "requests"
  add_foreign_key "uploads", "users"
end
