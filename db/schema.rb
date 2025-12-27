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

ActiveRecord::Schema[8.1].define(version: 2025_12_27_000001) do
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

  create_table "books", force: :cascade do |t|
    t.string "author"
    t.integer "book_type", default: 0, null: false
    t.string "cover_url"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "file_path"
    t.string "isbn"
    t.string "language", default: "en"
    t.string "open_library_edition_id"
    t.string "open_library_work_id"
    t.string "publisher"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.integer "year"
    t.index ["book_type"], name: "index_books_on_book_type"
    t.index ["isbn"], name: "index_books_on_isbn"
    t.index ["open_library_edition_id"], name: "index_books_on_open_library_edition_id"
    t.index ["open_library_work_id"], name: "index_books_on_open_library_work_id"
  end

  create_table "download_clients", force: :cascade do |t|
    t.string "api_key"
    t.string "category"
    t.string "client_type", null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.string "name", null: false
    t.string "password"
    t.integer "priority", default: 0, null: false
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.string "username"
    t.index ["client_type", "priority"], name: "index_download_clients_on_client_type_and_priority"
    t.index ["enabled"], name: "index_download_clients_on_enabled"
    t.index ["name"], name: "index_download_clients_on_name", unique: true
  end

  create_table "downloads", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "download_client_id"
    t.string "download_path"
    t.string "download_type"
    t.string "external_id"
    t.string "name"
    t.integer "progress", default: 0
    t.integer "request_id", null: false
    t.bigint "size_bytes"
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["download_client_id"], name: "index_downloads_on_download_client_id"
    t.index ["external_id"], name: "index_downloads_on_external_id"
    t.index ["request_id"], name: "index_downloads_on_request_id"
    t.index ["status"], name: "index_downloads_on_status"
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

  create_table "requests", force: :cascade do |t|
    t.boolean "attention_needed", default: false
    t.integer "book_id", null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.text "issue_description"
    t.datetime "next_retry_at"
    t.text "notes"
    t.integer "retry_count", default: 0
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["attention_needed"], name: "index_requests_on_attention_needed"
    t.index ["book_id"], name: "index_requests_on_book_id"
    t.index ["next_retry_at"], name: "index_requests_on_next_retry_at"
    t.index ["status"], name: "index_requests_on_status"
    t.index ["user_id", "status"], name: "index_requests_on_user_id_and_status"
    t.index ["user_id"], name: "index_requests_on_user_id"
  end

  create_table "search_results", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "download_url"
    t.string "guid", null: false
    t.string "indexer"
    t.string "info_url"
    t.integer "leechers"
    t.string "magnet_url"
    t.datetime "published_at"
    t.integer "request_id", null: false
    t.integer "seeders"
    t.bigint "size_bytes"
    t.integer "status", default: 0, null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
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
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["book_id"], name: "index_uploads_on_book_id"
    t.index ["book_type"], name: "index_uploads_on_book_type"
    t.index ["processed_at"], name: "index_uploads_on_processed_at"
    t.index ["status"], name: "index_uploads_on_status"
    t.index ["user_id"], name: "index_uploads_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.text "backup_codes"
    t.datetime "created_at", null: false
    t.integer "failed_login_count", default: 0, null: false
    t.datetime "last_failed_login_at"
    t.string "last_failed_login_ip"
    t.datetime "locked_until"
    t.string "name", default: "", null: false
    t.boolean "otp_required", default: false, null: false
    t.string "otp_secret"
    t.string "password_digest", null: false
    t.integer "role", default: 0, null: false
    t.datetime "updated_at", null: false
    t.string "username", null: false
    t.index ["role"], name: "index_users_on_role"
    t.index ["username"], name: "index_users_on_username", unique: true
  end

  add_foreign_key "activity_logs", "users"
  add_foreign_key "downloads", "requests"
  add_foreign_key "notifications", "users"
  add_foreign_key "requests", "books"
  add_foreign_key "requests", "users"
  add_foreign_key "search_results", "requests"
  add_foreign_key "sessions", "users"
  add_foreign_key "uploads", "books"
  add_foreign_key "uploads", "users"
end
