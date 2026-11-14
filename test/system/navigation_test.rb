require "application_system_test_case"

Capybara.register_driver :navigation_without_javascript do |app|
  options = Selenium::WebDriver::Chrome::Options.new
  options.add_argument("--headless=new")
  options.add_argument("--mute-audio")
  options.add_argument("--no-sandbox") if Process.uid.zero?
  options.add_preference("profile.managed_default_content_settings.javascript", 2)
  Capybara::Selenium::Driver.new(app, browser: :chrome, options: options)
end

class NavigationTest < ApplicationSystemTestCase
  setup do
    clear_settings_env!
    SettingsService.set(:zlibrary_enabled, false)
  end

  teardown do
    restore_settings_env!
  end

  test "Turbo navigation never displays the phone menu beside desktop navigation" do
    sign_in_as(users(:two))
    visit requests_path
    assert_no_selector "#main-menu", visible: true
    page.execute_script("window.navigationDocument = 'same-navigation-document'")

    within("nav[aria-label='Main']") { click_link "Admin", exact: true }

    assert_selector "h1", text: "Server overview"
    assert_equal "same-navigation-document", page.evaluate_script("window.navigationDocument")
    assert_no_selector "#main-menu", visible: true
    assert_no_selector "button[aria-controls='main-menu']", visible: true

    within("nav[aria-label='Main']") { click_link "Discover", exact: true }
    assert_selector "h1", text: "Discover"
    assert_no_selector "#main-menu", visible: true
    page.go_back
    assert_selector "h1", text: "Server overview"
    assert_no_selector "#main-menu", visible: true

    page.current_window.resize_to(390, 844)
    menu = find("button[aria-controls='main-menu']")
    assert_equal "false", menu["aria-expanded"]
    assert_no_selector "#main-menu", visible: true
    menu.click
    within("#main-menu") { click_link "Requests", exact: true }
    assert_selector "h1", text: "All Requests"
    assert_no_selector "#main-menu", visible: true
    assert_equal "false", find("button[aria-controls='main-menu']")["aria-expanded"]
  end

  test "without JavaScript phone navigation stays usable and desktop navigation is not duplicated" do
    Capybara.using_driver(:navigation_without_javascript) do
      page.current_window.resize_to(390, 844)
      sign_in_as(users(:two))
      visit requests_path
      assert_nil page.evaluate_script("window.Turbo")
      assert_selector "#main-menu", visible: true
      assert_no_selector "button[aria-controls='main-menu']", visible: true

      within("#main-menu") { click_link "Admin", exact: true }
      assert_selector "h1", text: "Server overview"
      page.current_window.resize_to(1400, 900)
      assert_no_selector "#main-menu", visible: true
      assert_no_selector "button[aria-controls='main-menu']", visible: true
      within("nav[aria-label='Main']") { assert_link "Discover", visible: true }
    end
  end

  test "a phone menu stays usable after automatic morph refreshes" do
    sign_in_as(users(:one))
    page.current_window.resize_to(390, 844)
    visit request_path(requests(:pending_request))
    assert_selector "meta[name='turbo-refresh-method'][content='morph']", visible: :all
    assert_selector "button[aria-controls='main-menu']", visible: true
    page.execute_script("window.navigationDocument = 'same-morph-document'")

    2.times do
      page.execute_script(<<~JAVASCRIPT)
        document.documentElement.dataset.navigationMorphed = "false"
        document.addEventListener("turbo:morph", () => document.documentElement.dataset.navigationMorphed = "true", { once: true })
        Turbo.session.refresh(location.href)
      JAVASCRIPT
      assert_selector "html[data-navigation-morphed='true']", visible: :all
      assert_equal "same-morph-document", page.evaluate_script("window.navigationDocument")
      assert_no_selector "#main-menu", visible: true
      menu = find("button[aria-controls='main-menu']")
      assert_equal "false", menu["aria-expanded"]
      menu.click
      assert_selector "#main-menu", visible: true
      assert_equal "true", menu["aria-expanded"]
    end
  end

  test "a health problem opens the right settings tab and section, and Back returns to the overview" do
    SystemHealth.for_service("indexer").check_failed!(message: "Failed to connect to Prowlarr")
    sign_in_as(users(:two))
    visit admin_root_path

    click_link "Open Indexer settings"

    assert_selector "[role='tab'][aria-selected='true']", text: "Search"
    assert_selector "#settings-section-indexer", visible: true
    assert_equal "settings-section-indexer", page.evaluate_script("document.activeElement.id")
    assert_equal "#search", page.evaluate_script("location.hash")

    click_button "Integrations"
    assert_selector "#settings-section-hardcover", visible: true
    page.go_back

    assert_current_path admin_root_path
    assert_text "Indexer is down"
    page.go_forward
    assert_selector "[role='tab'][aria-selected='true']", text: "Integrations"
  end

  test "a link to a collapsed source opens its tab and expands it" do
    sign_in_as(users(:two))
    visit root_path

    visit admin_settings_path(anchor: "settings-section-zlibrary")

    assert_selector "[role='tab'][aria-selected='true']", text: "Search"
    assert_selector "details#settings-section-zlibrary[open]", visible: true
    assert_equal "#search", page.evaluate_script("location.hash")
  end

  test "the phone menu reports its state and Escape closes it back to its button" do
    sign_in_as(users(:one))
    page.current_window.resize_to(390, 844)
    visit requests_path

    menu_button = find("button[aria-controls='main-menu']")
    assert_equal "false", menu_button["aria-expanded"]
    assert_no_selector "#main-menu", visible: true

    menu_button.click
    assert_equal "true", menu_button["aria-expanded"]
    within("#main-menu") do
      assert_selector "a[aria-current='page']", text: "Requests"
      assert_link "Library", href: consumer_library_path
      assert_link "Discover"
    end

    find("#main-menu a", text: "Library").send_keys(:escape)
    assert_no_selector "#main-menu", visible: true
    assert_equal "false", menu_button["aria-expanded"]
    assert_equal "main-menu", page.evaluate_script("document.activeElement.getAttribute('aria-controls')")
  ensure
    page.current_window.resize_to(1400, 1400)
  end

  test "with doubled text on a phone the header still leaves the menu button reachable and nothing scrolls sideways" do
    sign_in_as(users(:two))
    page.current_window.resize_to(390, 844)
    visit admin_root_path
    page.execute_script("document.documentElement.style.fontSize = '200%'")

    covering = page.evaluate_script(<<~JAVASCRIPT)
      (() => {
        const button = document.querySelector("button[aria-controls='main-menu']")
        const box = button.getBoundingClientRect()
        const hit = document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2)
        return button.contains(hit) ? null : hit.outerHTML.slice(0, 120)
      })()
    JAVASCRIPT
    assert_nil covering
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, page.evaluate_script("document.documentElement.clientWidth")
    find("button[aria-controls='main-menu']").click
    assert_link "Admin", href: admin_root_path

    page.current_window.resize_to(1400, 900)
    labels = page.evaluate_script(<<~JAVASCRIPT)
      [...document.querySelectorAll("nav[aria-label='Main'] a, nav[aria-label='Main'] [data-release-badge], nav[aria-label='Main'] form button")]
        .filter((element) => !element.closest("#main-menu") && !element.querySelector("[data-release-badge]"))
        .map((element) => element.getBoundingClientRect())
        .filter((box) => box.width > 0)
    JAVASCRIPT
    labels.combination(2).each do |first, second|
      overlap = first["left"] < second["right"] && second["left"] < first["right"] &&
        first["top"] < second["bottom"] && second["top"] < first["bottom"]
      assert_not overlap, "Header items overlap with doubled text: #{first} and #{second}"
    end
  ensure
    page.current_window.resize_to(1400, 1400)
  end
end
