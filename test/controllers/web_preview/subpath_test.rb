# frozen_string_literal: true

require "test_helper"
require_relative "../../test_helpers/consumer_test_helper"
require_relative "../../test_helpers/web_preview_test_helper"

class WebPreview::SubpathTest < ActionDispatch::IntegrationTest
  include ConsumerTestHelper
  include WebPreviewTestHelper

  BASE = "/shelf"

  setup do
    prepare_consumer_library
    Book.where.not(id: [ @ebook.id, @audiobook.id ]).update_all(file_path: nil)
    @previous_root = ActionController::Base.relative_url_root
    ActionController::Base.relative_url_root = BASE
    @previous_enabled = ENV[WebPreview::Access::VARIABLE]
    ENV[WebPreview::Access::VARIABLE] = users(:one).id.to_s
  end

  teardown do
    ActionController::Base.relative_url_root = @previous_root
    ENV[WebPreview::Access::VARIABLE] = @previous_enabled
    FileUtils.remove_entry(@root)
  end

  def app
    @app ||= Rack::URLMap.new(BASE => Rails.application)
  end

  test "a signed-out visitor is sent to the sign-in page under the deployment path" do
    get "#{BASE}/preview/library"
    assert_redirected_to "http://www.example.com#{BASE}/session/new"
    get "#{BASE}/preview/api/v1/library", headers: account_headers(users(:one))
    assert_response :unauthorized
  end

  test "the shell, its assets, the API and the reader handoff all live under the deployment path" do
    sign_in_as(users(:one))
    get "#{BASE}/preview"
    assert_redirected_to "http://www.example.com#{BASE}/preview/library"
    with_forgery_protection do
      get "#{BASE}/preview/library/#{@ebook.id}"
      assert_response :success
      assert_equal({ "version" => 1, "account" => users(:one).id.to_s, "mount" => "#{BASE}/preview", "api" => "#{BASE}/preview/api/v1", "classic_library" => "#{BASE}/read",
        "reader_formats" => %w[cbz epub pdf], "offline" => offline_boot }, JSON.parse(css_select("script#shelfarr-boot").sole.text))
      assert_select "script[type=module][src^='#{BASE}/assets/web/preview-']"
      assert_select "link[rel=stylesheet][href^='#{BASE}/assets/web/preview-']"
      assert_select "a[href='#{BASE}/read']"
    end
    get "#{BASE}/preview/api/v1/library", headers: account_headers(users(:one))
    assert_response :success
    items = response.parsed_body.fetch("items")
    assert_equal [ "#{BASE}/read/#{@audiobook.id}", "#{BASE}/read/#{@ebook.id}" ], items.map { |item| item.fetch("reader_url") }
    get "#{BASE}/preview/api/v1/session", headers: account_headers(users(:one))
    assert_equal({ "legacy_library" => "#{BASE}/read", "discover" => "#{BASE}/search", "requests" => "#{BASE}/requests", "account" => "#{BASE}/profile" }, response.parsed_body.fetch("links"))
  end

  test "a chosen format is requested through the API under the deployment path" do
    sign_in_as(users(:one))
    BookMetadataLookupService.stub(:call, { title: "Middlemarch", author: "George Eliot" }) do
      post "#{BASE}/preview/api/v1/books/openlibrary/OL900W/requests", params: { book_type: "audiobook", language: "en" }, headers: account_headers(users(:one)), as: :json
    end
    assert_response :created
    assert_equal [ [ "audiobook", "created" ] ], response.parsed_body.fetch("results").map { |result| result.values_at("book_type", "outcome") }
    assert_equal "requested", response.parsed_body.fetch("book").fetch("formats").find { |format| format.fetch("book_type") == "audiobook" }.fetch("state")
  end

  test "an account the allowlist refuses gets a release page that names this deployment's path" do
    sign_in_as(users(:one))
    with_env(WebPreview::Access::VARIABLE => users(:two).id.to_s) do
      get "#{BASE}/preview/read/downloads"
      assert_response :not_found
      assert_select "meta[name=shelfarr-base][content='#{BASE}']"
    end
  end

  test "the offline marker belongs to this deployment's preview path and name, never the root deployment's" do
    name = OfflineContinuity.cookie_name("#{BASE}/preview")
    assert_not_equal OfflineContinuity.cookie_name("/preview"), name
    assert_not_equal OfflineContinuity.cookie_name("#{BASE}/preview/preview"), name
    users(:one).update!(failed_login_count: 0, locked_until: nil)
    post "#{BASE}/session", params: { username: users(:one).username, password: "Password123!" }
    assert_redirected_to "http://www.example.com#{BASE}/"
    line = Array(response.headers["Set-Cookie"]).flat_map { |header| header.split("\n") }.select { |cookie| cookie.start_with?("shelfarr_offline_") }.sole
    assert line.start_with?("#{name}=")
    assert_includes line.split(";").map(&:strip), "path=#{BASE}/preview"
    get "#{BASE}/preview/api/v1/auth/bootstrap"
    assert_equal line.split(";").first.delete_prefix("#{name}="), response.parsed_body.fetch("offline_continuity")
  end

  test "the interim reader and Downloads addresses redirect within the deployment path" do
    sign_in_as(users(:one))
    { "#{BASE}/preview/library/#{@ebook.id}/read" => "#{BASE}/preview/read/#{@ebook.id}", "#{BASE}/preview/library/downloads" => "#{BASE}/preview/read/downloads" }.each do |from, to|
      get from
      assert_response :found
      assert_equal "http://www.example.com#{to}", response.location
    end
    get "#{BASE}/preview/offline-worker.js"
    assert_response :not_found
  end

  def offline_boot
    { "worker" => "#{BASE}/preview/read/offline-worker.js", "scope" => "#{BASE}/preview/read/", "downloads" => "#{BASE}/preview/read/downloads", "continuity_cookie" => OfflineContinuity.cookie_name("#{BASE}/preview") }
  end

  test "the reader, its media, its worker and Downloads live under the deployment path" do
    sign_in_as(users(:one))
    get "#{BASE}/preview/read/#{@ebook.id}"
    assert_response :success
    boot = JSON.parse(css_select("script#shelfarr-boot").sole.text)
    assert_equal [ "#{BASE}/preview", "#{BASE}/preview/api/v1", "#{BASE}/read/downloads", offline_boot ], boot.values_at("mount", "api", "classic_downloads", "offline")
    assert_match(%r{\A#{BASE}/assets/consumer_reader_engine-\h+\.js\z}, boot.fetch("reader_engine"))
    get "#{BASE}/preview/api/v1/library/#{@ebook.id}/reader", headers: account_headers(users(:one))
    publication = response.parsed_body.fetch("publication")
    asset = publication.fetch("assets").sole
    assert_equal "#{BASE}/preview/api/v1/accounts/#{users(:one).id}/library/#{@ebook.id}/assets/#{asset.fetch("id")}", asset.fetch("url")
    assert_equal "#{BASE}/read/#{@ebook.id}", publication.dig("classic_reader", "url")
    get asset.fetch("url")
    assert_response :success
    get "#{BASE}/preview/read/downloads"
    assert_response :success
    get "#{BASE}/preview/read/offline-worker.js"
    config = JSON.parse(response.body.split(";\n", 2).first.delete_prefix("self.SHELFARR_GO_OFFLINE = "))
    assert_equal [ "shelfarr-rails-preview-offline.v1@#{BASE}/preview|", { "prefix" => "#{BASE}/preview/read", "suffix" => "" }, "#{BASE}/preview/read/downloads" ],
      config.values_at("cache", "reads", "downloads")
    assert config.fetch("assets").all? { |entry| entry.fetch("path").start_with?("#{BASE}/assets/") }
  end

  test "the classic notifications address, the warm inbox and its actions live under the deployment path" do
    sign_in_as(users(:one))
    notification = users(:one).notifications.create!(notification_type: "request_completed", title: "Book Ready", message: "Ready.")
    get "#{BASE}/notifications"
    assert_redirected_to "http://www.example.com#{BASE}/preview/notifications"
    get "#{BASE}/preview/notifications"
    assert_response :success
    get "#{BASE}/preview/api/v1/notifications", headers: account_headers(users(:one))
    assert_equal [ notification.id.to_s ], response.parsed_body.fetch("items").map { |item| item.fetch("id") }
    post "#{BASE}/preview/api/v1/notifications/#{notification.id}/read", headers: account_headers(users(:one)), as: :json
    assert_response :success
    assert notification.reload.read?
    post "#{BASE}/preview/api/v1/notifications/clear", params: { through: notification.id.to_s }, headers: account_headers(users(:one)), as: :json
    assert_equal [ 0, 0, 1 ], response.parsed_body.values_at("unread", "total", "changed")
  end

  test "the classic activity bookmark, the warm activity page and its API live under the deployment path" do
    admin = users(:two)
    ENV[WebPreview::Access::VARIABLE] = admin.id.to_s
    sign_in_as(admin)
    entry = ActivityLog.create!(action: "user.login", user: admin)
    get "#{BASE}/admin/activity_logs?action_filter=user.login"
    assert_redirected_to "http://www.example.com#{BASE}/preview/server/system/activity?action=user.login"
    get "#{BASE}/preview/server/system/activity?action=user.login"
    assert_response :success
    get "#{BASE}/preview/api/v1/admin/activity?action_filter=user.login", headers: account_headers(admin)
    assert_equal [ entry.id.to_s ], response.parsed_body.fetch("entries").map { |item| item.fetch("id") }
  end

  test "the classic Audible bookmark, the warm Library and files page and the Audible API live under the deployment path" do
    admin = users(:two)
    ENV[WebPreview::Access::VARIABLE] = admin.id.to_s
    sign_in_as(admin)
    get "#{BASE}/admin/owned_library_connections?tab=catalog&q=Dune"
    assert_redirected_to "http://www.example.com#{BASE}/preview/server/library?audible_q=Dune#audible-catalogue"
    get "#{BASE}/preview/server/library?audible_q=Dune"
    assert_response :success
    get "#{BASE}/preview/api/v1/admin/audible", headers: account_headers(admin)
    assert_response :success
    assert_equal "needs_setup", response.parsed_body.dig("connection", "status")
  end
end
