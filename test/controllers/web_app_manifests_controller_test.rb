# frozen_string_literal: true

require "test_helper"

class WebAppManifestsControllerTest < ActionDispatch::IntegrationTest
  ICON = %r{\A/shelf/assets/web_app/shelfarr-(?:192|512|maskable-512|apple-touch)-\h+\.png\z}

  setup do
    @previous_root = ActionController::Base.relative_url_root
    ActionController::Base.relative_url_root = "/shelf"
  end

  teardown { ActionController::Base.relative_url_root = @previous_root }

  test "the manifest is public, identical for every visitor and starts in the reader under the deployment subpath" do
    get "/manifest.webmanifest", env: { "SCRIPT_NAME" => "/shelf" }
    assert_response :success
    assert_equal "application/manifest+json", response.media_type
    assert_equal "no-cache", response.headers["Cache-Control"]
    assert_nil response.headers["Set-Cookie"]
    signed_out = response.body
    manifest = JSON.parse(signed_out)

    assert_equal({ "id" => "/shelf/", "name" => "Shelfarr", "short_name" => "Shelfarr",
      "description" => "Read and listen to your Shelfarr library.", "lang" => "en",
      "start_url" => "/shelf/read", "scope" => "/shelf/", "display" => "standalone",
      "background_color" => "#FBF7F0", "theme_color" => "#FBF7F0" }, manifest.except("icons"))
    assert_equal [ [ "192x192", "image/png", "any" ], [ "512x512", "image/png", "any" ], [ "512x512", "image/png", "maskable" ] ],
      manifest.fetch("icons").map { |icon| icon.values_at("sizes", "type", "purpose") }
    manifest.fetch("icons").each { |icon| assert_png_icon icon.fetch("src"), icon.fetch("sizes") }

    sign_in_as(users(:one))
    get "/manifest.webmanifest", env: { "SCRIPT_NAME" => "/shelf" }
    assert_equal signed_out, response.body
  end

  test "a deployment at the root keeps the whole site in the app" do
    ActionController::Base.relative_url_root = nil
    get web_app_manifest_path
    assert_equal [ "/", "/read", "/" ], JSON.parse(response.body).values_at("id", "start_url", "scope")
  end

  test "sign-in, reader, offline and account pages all link the manifest and home screen icon" do
    get "/session/new", env: { "SCRIPT_NAME" => "/shelf" }
    assert_home_screen_metadata

    get "/read/offline", env: { "SCRIPT_NAME" => "/shelf" }
    assert_home_screen_metadata

    sign_in_as(users(:one))
    get "/read", env: { "SCRIPT_NAME" => "/shelf" }
    assert_home_screen_metadata
    assert_select "a.consumer-home-screen-link[href='/shelf/profile#home-screen']", text: "Add Shelfarr to your home screen"

    get "/profile", env: { "SCRIPT_NAME" => "/shelf" }
    assert_home_screen_metadata
    assert_select "#home-screen" do
      assert_select "h2", text: "Shelfarr on your home screen"
      assert_select "[data-web-app-install-target=offer][hidden] button", text: "Install Shelfarr"
      assert_select "[data-web-app-install-target=guide] h3", text: "Android"
      assert_select "[data-web-app-install-target=guide] h3", text: "iPhone and iPad"
      assert_select "[data-web-app-install-target=guide] ol li", text: "Tap Add to Home Screen, keep Open as Web App on, then tap Add."
    end
    assert_equal 4, @touch_icons.size
    @touch_icons.uniq.each { |src| assert_png_icon src, "180x180" }
  end

  private

  def assert_home_screen_metadata
    assert_select "link[rel=manifest][href='/shelf/manifest.webmanifest']", count: 1
    assert_select "meta[name=apple-mobile-web-app-title][content=Shelfarr]", count: 1
    assert_select "link[rel=apple-touch-icon]", count: 1 do |links|
      (@touch_icons ||= []) << links.first["href"]
    end
  end

  def assert_png_icon(src, sizes)
    assert_match ICON, src
    path = src.delete_prefix("/shelf")
    get path
    assert_response :success
    assert_equal "image/png", response.media_type
    width, height = response.body.byteslice(16, 8).unpack("NN")
    assert_equal sizes, "#{width}x#{height}"
  end
end
