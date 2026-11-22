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

  test "an account the allowlist refuses gets a release page that names this deployment's path" do
    sign_in_as(users(:one))
    with_env(WebPreview::Access::VARIABLE => users(:two).id.to_s) do
      get "#{BASE}/preview/library/downloads"
      assert_response :not_found
      assert_select "meta[name=shelfarr-base][content='#{BASE}']"
    end
  end

  def offline_boot
    { "worker" => "#{BASE}/preview/offline-worker.js", "scope" => "#{BASE}/preview/library/", "downloads" => "#{BASE}/preview/library/downloads" }
  end

  test "the reader, its media, its worker and Downloads live under the deployment path" do
    sign_in_as(users(:one))
    get "#{BASE}/preview/library/#{@ebook.id}/read"
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
    get "#{BASE}/preview/library/downloads"
    assert_response :success
    get "#{BASE}/preview/offline-worker.js"
    config = JSON.parse(response.body.split(";\n", 2).first.delete_prefix("self.SHELFARR_GO_OFFLINE = "))
    assert_equal [ "#{BASE}/preview/library", "#{BASE}/preview/library/downloads" ], config.values_at("library", "downloads")
    assert config.fetch("assets").all? { |entry| entry.fetch("path").start_with?("#{BASE}/assets/") }
  end
end
