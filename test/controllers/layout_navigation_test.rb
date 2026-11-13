# frozen_string_literal: true

require "test_helper"

class LayoutNavigationTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
  end

  test "authenticated users see uploads navigation link even when uploads are disabled" do
    sign_in_as(@user)

    get root_url

    assert_response :success
    assert_select "a[href='#{uploads_path}']", text: "Uploads"
    assert_select "a[href='#{new_upload_path}']", text: "Upload", count: 0
  end

  test "one library, discover without a Hardcover catalog, and requests are the main destinations" do
    SettingsService.set(:hardcover_enabled, true)
    SettingsService.set(:hardcover_api_token, "")
    sign_in_as(@user)

    get requests_url

    assert_response :success
    menu_links = css_select("#main-menu a").map { |link| [ link.text.squish, link["href"] ] }
    assert_equal [ [ "Library", consumer_library_path ], [ "Discover", search_path ], [ "Requests", requests_path ] ],
      menu_links.reject { |_text, href| href.include?("attention") }.first(3)
    assert_select "nav[aria-label='Main'] a", text: "Read & listen", count: 0
    assert_select "nav[aria-label='Main'] a[href='#{library_index_path}']", count: 0
    assert_select "nav[aria-label='Main'] a[href='#{admin_root_path}']", count: 0
    assert_select "nav[aria-label='Main'] a[aria-current='page']", text: "Requests", count: 2
    assert_select "nav[aria-label='Main'] a[aria-current='page']", count: 2
  end

  test "discover opens the Hardcover catalog when one is configured" do
    SettingsService.set(:hardcover_enabled, true)
    SettingsService.set(:hardcover_api_token, "instance_test_token")
    sign_in_as(@user)

    get search_url

    assert_select "nav[aria-label='Main'] a[href='#{discover_path}'][aria-current='page']", text: "Discover", count: 2
    assert_select "nav[aria-label='Discover sections'] a[aria-current='page']", text: "Search"
    assert_select "nav[aria-label='Discover sections'] a[href='#{discover_lists_path}']", text: "Lists"
  end

  test "search stays a discover section when Hardcover is switched off" do
    SettingsService.set(:hardcover_enabled, false)
    sign_in_as(@user)

    get search_url

    assert_select "h1", "Discover"
    assert_select "nav[aria-label='Discover sections'] a", count: 1, text: "Search"
    assert_select "nav[aria-label='Main'] a[href='#{search_path}'][aria-current='page']", text: "Discover", count: 2
  end

  test "book files and account pages keep their place in the navigation" do
    sign_in_as(@user)

    get library_index_url
    assert_select "nav[aria-label='Main'] a[aria-current='page']", text: "Library", count: 2

    get profile_url
    assert_select "nav[aria-label='Main'] a[href='#{profile_path}'][aria-current='page']", count: 2
  end

  test "admins reach the server overview from one entry and set up again there" do
    sign_in_as(users(:two))

    get admin_settings_url

    assert_select "nav[aria-label='Main'] a[href='#{admin_root_path}'][aria-current='page']", text: "Admin", count: 2
    assert_select "nav[aria-label='Main'] form[action='#{restart_admin_setup_wizard_path}']", count: 0
  end

  test "the mobile menu is a labelled disclosure that works without JavaScript" do
    sign_in_as(@user)

    get root_url

    assert_select "button[data-mobile-menu-target='button'][aria-controls='main-menu'][aria-expanded='false']"
    assert_select "#main-menu[data-mobile-menu-target='menu']"
    assert_select "noscript style", text: /\[data-mobile-menu-target="menu"\] \{ display: block; \}/
  end

  test "both shells show that this server runs the beta" do
    use_release_channel("beta")
    sign_in_as(@user)

    get root_url
    assert_select "nav[aria-label='Main'] [data-release-badge][title='Shelfarr 1.0 Beta']", text: "Beta"

    get consumer_library_url
    assert_select ".consumer-header [data-release-badge][title='Shelfarr 1.0 Beta']", text: "Beta"
    assert_select ".consumer-header", text: /Reader preview/, count: 0
    assert_select ".consumer-navigation a[aria-current='page']", count: 1, text: "Library"
  end

  test "a stable server shows no beta badge" do
    use_release_channel("stable")
    sign_in_as(@user)

    get root_url
    assert_select "[data-release-badge]", count: 0

    get consumer_library_url
    assert_select "[data-release-badge]", count: 0
  end
end
