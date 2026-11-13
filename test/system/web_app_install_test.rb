# frozen_string_literal: true

require "application_system_test_case"
require_relative "../test_helpers/consumer_test_helper"
require_relative "../support/consumer_reachability"

module WebAppInstallSystemTest
  extend ActiveSupport::Concern
  include ConsumerTestHelper

  BASE = "/shelf"
  APP = Rack::URLMap.new(BASE => ConsumerReachability.new(Rails.application))
  OFFERS = "window.__installOffers = 0; window.addEventListener('beforeinstallprompt', () => window.__installOffers++, true)"

  class_methods do
    def driven_by_chrome(name, *arguments)
      driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ], options: { name: name, native_displayed: true } do |options|
        options.add_argument("--no-sandbox") if Process.uid.zero?
        options.add_argument("--mute-audio")
        options.add_argument("--bypass-app-banner-engagement-checks")
        arguments.each { |argument| options.add_argument(argument) }
      end
    end
  end

  included do
    setup do
      ConsumerReachability.reset!
      @previous_app = Capybara.app
      @previous_root = ActionController::Base.relative_url_root
      Capybara.app = APP
      ActionController::Base.relative_url_root = BASE
      Rails.application.importmap.send(:clear_cache)
      page.current_window.resize_to(390, 844)
      prepare_consumer_library
      page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: OFFERS)
      sign_in(users(:one))
    end

    teardown do
      ConsumerReachability.reset!
      clear_browser_offline_state
    ensure
      Capybara.app = @previous_app
      ActionController::Base.relative_url_root = @previous_root
      Rails.application.importmap.send(:clear_cache)
      FileUtils.remove_entry(@root) if @root && File.exist?(@root)
    end
  end

  private

  def at(path) = "#{BASE}#{path}"

  def sign_in(user)
    session = user.sessions.create!
    signed = ActionDispatch::TestRequest.create.cookie_jar.tap { |jar| jar.signed[:session_id] = session.id }[:session_id]
    clear_browser_offline_state
    visit at("/up")
    page.driver.browser.manage.add_cookie(name: "session_id", value: signed, path: "/")
  end

  def install_offers = page.evaluate_script("window.__installOffers")

  def wait_for_progress(book, timeout: 20)
    wait_until("the saved place reaches the server", timeout: timeout) { users(:one).consumer_progresses.find_by(book: book) }
    users(:one).consumer_progresses.find_by(book: book)
  end

  def standalone? = page.evaluate_script("matchMedia('(display-mode: standalone)').matches")

  def wait_until(what, timeout: 15)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "Timed out waiting until #{what}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.1
    end
  end

  def assert_no_horizontal_overflow
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")
  end

  def capture(filename)
    return unless ENV["CONSUMER_SCREENSHOT_DIR"].present?

    FileUtils.mkdir_p(ENV.fetch("CONSUMER_SCREENSHOT_DIR"))
    page.save_screenshot(File.join(ENV.fetch("CONSUMER_SCREENSHOT_DIR"), filename))
  end
end

class WebAppInstallTest < ApplicationSystemTestCase
  include WebAppInstallSystemTest

  driven_by_chrome :web_app_install_chrome

  test "Chrome finds Shelfarr installable under the deployment subpath, starting in the reader" do
    visit at(new_session_path)
    manifest = page.driver.browser.execute_cdp("Page.getAppManifest")
    assert_equal "#{page.server.base_url}#{BASE}/manifest.webmanifest", manifest.fetch("url")
    assert_empty manifest.fetch("errors")
    assert_equal({ "installabilityErrors" => [] }, page.driver.browser.execute_cdp("Page.getInstallabilityErrors"))
    assert_equal "#{page.server.base_url}#{BASE}/", page.driver.browser.execute_cdp("Page.getAppId").fetch("appId")
    data = JSON.parse(manifest.fetch("data"))
    assert_equal [ at(consumer_library_path), "#{BASE}/", "standalone" ], data.values_at("start_url", "scope", "display")
  end

  test "an install offer made on one page is still there after moving to the Account page" do
    page.current_window.resize_to(1400, 1400)
    visit at(root_path)
    wait_until("Chrome offers installation") { install_offers == 1 }
    page.execute_script("window.__samePage = true")
    first("nav a[href='#{at(profile_path)}']").click
    assert_current_path at(profile_path)
    assert page.evaluate_script("window.__samePage === true"), "the Account page opened without reloading"
    within("#home-screen") do
      assert_button "Install Shelfarr"
      assert_text "Open Shelfarr in Safari."
      assert_no_text "You're using Shelfarr from your home screen."
    end
    assert_equal 1, install_offers
  end
end

class WebAppInstalledWindowTest < ApplicationSystemTestCase
  include WebAppInstallSystemTest

  driven_by_chrome :web_app_installed_window_chrome, "--app=data:text/html,"

  test "the installed app doesn't ask to be installed again" do
    visit at(consumer_library_path)
    assert standalone?
    wait_until("Chrome offers installation") { install_offers == 1 }
    assert_no_link "Add Shelfarr to your home screen"
    click_link "Account"
    within("#home-screen") do
      assert_text "You're using Shelfarr from your home screen."
      assert_no_button "Install Shelfarr"
      assert_no_text "Open Shelfarr in Safari."
    end
  end

  test "launched without a connection, the app opens the downloads and keeps the listening place" do
    FileUtils.cp(Rails.root.join("test/fixtures/files/consumer_sample.mp3"), @audio_path)
    visit at(consumer_publication_path(@audiobook))
    assert_selector "[data-consumer-reader-target=duration]", text: /0:0[89]/, wait: 15
    within(".consumer-offline") do
      click_button "Download"
      assert_text "Available offline", wait: 20
    end
    start_url = JSON.parse(page.driver.browser.execute_cdp("Page.getAppManifest").fetch("data")).fetch("start_url")

    ConsumerReachability.offline = true
    visit start_url
    assert standalone?
    assert_selector "h1", text: "On this device.", wait: 15
    assert_selector ".consumer-download", text: "A Listening Life"
    assert_no_horizontal_overflow
    capture("installed-offline-launch-mobile.png")
    click_link "Listen"
    assert_selector "[data-consumer-reader-target=duration]", text: /0:0[89]/, wait: 15
    find("button[aria-label='Play audiobook']").click
    wait_until("offline audio plays") { page.evaluate_script("document.querySelector('audio').currentTime") > 2 }
    find("button[aria-label='Pause audiobook']").click
    paused = Time.current
    assert_text "Saved on this device. It will sync when you're back online.", wait: 12
    assert_empty users(:one).consumer_progresses

    ConsumerReachability.offline = false
    page.execute_script("window.dispatchEvent(new Event('online'))")
    progress = wait_for_progress(@audiobook)
    assert_operator progress.position_seconds, :>, 2
    assert_in_delta paused.to_f, progress.observed_at.to_f, 15
  end
end

class WebAppInstallChoiceTest < ApplicationSystemTestCase
  include WebAppInstallSystemTest

  ONLY_TEST_OFFERS = "window.addEventListener('beforeinstallprompt', offer => { if (offer.isTrusted) offer.stopImmediatePropagation() }, true)"

  test "a declined install keeps the steps, and an accepted one waits for the browser to finish" do
    page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: ONLY_TEST_OFFERS)
    page.current_window.resize_to(1400, 1400)
    visit at(consumer_library_path)
    click_link "Add Shelfarr to your home screen"
    assert_current_path at(profile_path)
    within("#home-screen") do
      assert_no_button "Install Shelfarr"
      assert_text "Open Shelfarr in Chrome."
    end

    offer_install(outcome: "dismissed")
    within("#home-screen") do
      click_button "Install Shelfarr"
      assert_selector "[role=status]", text: "Shelfarr wasn't installed. You can add it later from here or from your browser's menu."
      assert_no_button "Install Shelfarr"
      assert_text "Open Shelfarr in Chrome."
    end

    offer_install(outcome: "accepted")
    within("#home-screen") do
      click_button "Install Shelfarr"
      assert_selector "[role=status]", text: "Your browser is adding Shelfarr to this device."
      assert_text "Open Shelfarr in Chrome."
    end
    page.execute_script("window.dispatchEvent(new Event('appinstalled'))")
    within("#home-screen") do
      assert_selector "[role=status]", text: "Shelfarr is installed. Open it from your home screen or app list."
      assert_no_text "Open Shelfarr in Chrome."
    end
    assert_equal 2, page.evaluate_script("window.__promptsShown")
  end

  private

  def offer_install(outcome:)
    page.execute_script(<<~JS, outcome)
      const offer = new Event("beforeinstallprompt", { cancelable: true })
      offer.prompt = async () => { window.__promptsShown = (window.__promptsShown || 0) + 1 }
      offer.userChoice = Promise.resolve({ outcome: arguments[0], platform: "web" })
      window.dispatchEvent(offer)
    JS
  end
end
