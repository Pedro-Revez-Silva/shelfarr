# frozen_string_literal: true

require "application_system_test_case"
require_relative "../test_helpers/consumer_test_helper"
require_relative "../test_helpers/web_preview_test_helper"

module WebPreviewFlows
  extend ActiveSupport::Concern

  PASSWORD = "Password123!"

  included do
    include ConsumerTestHelper
    include WebPreviewTestHelper

    setup do
      @previous_preview = ENV[WebPreview::Access::VARIABLE]
      ENV[WebPreview::Access::VARIABLE] = [ users(:one), users(:two) ].map { |user| user.id.to_s }.join(",")
      @previous_forgery = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      @previous_app = Capybara.app
      @previous_root = ActionController::Base.relative_url_root
      if self.class::BASE.present?
        Capybara.app = Rack::URLMap.new(self.class::BASE => Rails.application)
        ActionController::Base.relative_url_root = self.class::BASE
      end
      Rails.application.importmap.send(:clear_cache)
      prepare_consumer_library
      FileUtils.cp(Rails.root.join("test/fixtures/files/consumer_sample.mp3"), @audio_path)
      File.unlink(@epub_path)
      write_consumer_epub(@epub_path, chapter: "A first chapter. " * 400, second_chapter: "The second chapter. " * 400)
      Book.where.not(id: [ @ebook.id, @audiobook.id ]).update_all(file_path: nil)
      40.times { |index| Book.create!(title: "Shelf novel #{format('%02d', index)}", author: "A. Shelver", book_type: :ebook, file_path: @epub_path) }
      page.current_window.resize_to(1400, 1000)
      sign_in(users(:one))
      record_policy_violations
    end

    teardown do
      ActionController::Base.allow_forgery_protection = @previous_forgery
      ENV[WebPreview::Access::VARIABLE] = @previous_preview
      begin
        page.driver.browser.network_conditions = { offline: false, latency: 0, download_throughput: -1, upload_throughput: -1 }
      rescue StandardError
        nil
      end
      Capybara.app = @previous_app
      ActionController::Base.relative_url_root = @previous_root
      Rails.application.importmap.send(:clear_cache)
      FileUtils.remove_entry(@root) if @root && File.exist?(@root)
    end

    test "the shell serves versioned static assets under the deployment path with a strict policy and no leftovers" do
      visit at("/preview")
      assert_current_path at("/preview/library")
      assert_selector "h1", text: "Library"
      sources = page.evaluate_script("Array.from(document.querySelectorAll('script[src],link[rel=stylesheet]')).map(node => node.src || node.href)")
      assert_equal 2, sources.size
      sources.each { |source| assert_match(%r{\Ahttp://[^/]+#{Regexp.escape(self.class::BASE)}/assets/web/preview-[0-9a-f]+\.(js|css)\z}, source) }
      assert_equal 0, page.evaluate_script("document.querySelectorAll('script:not([src]):not([type=\"application/json\"]), [style]').length")
      assert_equal [], page.evaluate_script("window.__policyViolations")
      assert_nil page.evaluate_script("navigator.serviceWorker && navigator.serviceWorker.controller")
      assert_equal "Library preview · Shelfarr", page.title
      boot = JSON.parse(page.evaluate_script("document.getElementById('shelfarr-boot').textContent"))
      assert_equal({ "version" => 1, "account" => users(:one).id.to_s, "mount" => "#{self.class::BASE}/preview", "api" => "#{self.class::BASE}/preview/api/v1", "classic_library" => "#{self.class::BASE}/read" }, boot)
    end

    test "the library shows the server and account, filters, searches, loads more and opens details without writing" do
      visit at("/preview/library")
      assert_selector "h1", text: "Library"
      within("header.shell-header") do
        assert_text "Library preview"
        assert_text "Signed in as User One"
        assert_text "127.0.0.1"
        assert_selector "nav[aria-label=Primary] a[aria-current=page]", text: "Library"
        %w[Find Account].each { |name| assert_selector "nav[aria-label=Primary] a.nav-link:not(.nav-link--handoff)", text: name }
        assert_no_selector "nav[aria-label=Primary] a", text: "Server"
        assert_selector "a[href='#{at('/read')}']", text: "Classic library"
      end
      assert_selector "article.book-card", count: 30
      assert_text "Showing 30 books so far"
      click_button "Load more books"
      assert_selector "article.book-card", count: 42
      assert_text "Showing 42 books"
      assert_text "That is everything on this shelf."
      titles = all("article.book-card h3").map(&:text)
      assert_equal titles.uniq, titles

      choose "Audiobooks", allow_label_click: true
      assert_current_path(at("/preview/library?type=audiobook"), url: false, ignore_query: false)
      assert_selector "article.book-card", count: 1
      assert_selector "article.book-card h3", text: "A Listening Life"
      select "Reading", from: "Reading status"
      assert_text "No books match these filters"
      click_button "Clear filters"
      assert_selector "article.book-card", minimum: 30

      fill_in "Search your library", with: "quiet"
      click_button "Search"
      assert_selector "article.book-card", count: 1
      assert_selector "h2", text: "Search results"
      assert_equal "quiet", Rack::Utils.parse_query(URI.parse(current_url).query)["q"]

      assert_no_difference [ "ConsumerProgress.count", "ConsumerReadingState.count" ] do
        click_link "The Quiet Library"
        assert_selector "h1", text: "The Quiet Library"
        assert_selector "a.button--primary", text: "Start reading"
        assert_selector "table th[scope=row]", text: "A Book.epub"
        assert_equal [], page.evaluate_script("window.__policyViolations")
      end
      assert_equal at("/read/#{@ebook.id}"), URI.parse(find("a.button--primary")[:href]).path
    end

    test "Read opens the existing reader and its saved place shows up in the new library and details" do
      open_from_search("The Quiet Library")
      assert_selector "h1", text: "The Quiet Library"
      assert_no_difference "ConsumerProgress.count" do
        click_link "Start reading"
        assert_current_path at("/read/#{@ebook.id}")
        assert_selector ".consumer-ebook iframe", wait: 20
        within_frame(find(".consumer-ebook iframe")) { assert_text "A first chapter." }
      end
      find("[data-consumer-reader-target=viewport]").send_keys(:arrow_right)
      progress = wait_until("the reader saved a place") { users(:one).consumer_progresses.find_by(book: @ebook) }
      assert_equal 1, progress.version
      assert_operator progress.observed_at, :<=, progress.updated_at

      visit at("/preview/library")
      assert_selector "h2", text: "Keep going"
      within("section.continue") do
        assert_selector "h3", text: "The Quiet Library"
        assert_match(/\d+% read|Continue reading/, find("a.resume-link").text)
        assert_equal at("/read/#{@ebook.id}"), URI.parse(find("a.resume-link")[:href]).path
      end
      click_link "The Quiet Library", match: :first
      assert_selector "a.button--primary", text: "Continue reading"
      assert_equal progress.reload.version, 1
      assert_equal progress.attributes, users(:one).consumer_progresses.find_by!(book: @ebook).attributes
    end

    test "Listen opens the existing player and its saved position shows up in the new library" do
      visit at("/preview/library?type=audiobook")
      click_link "A Listening Life"
      assert_selector "a.button--primary", text: "Start listening"
      click_link "Start listening"
      assert_current_path at("/read/#{@audiobook.id}")
      assert_selector "[data-consumer-reader-target=duration]", text: /0:0[89]/, wait: 15
      assert_empty users(:one).consumer_progresses
      find("button[aria-label='Play audiobook']").click
      assert_selector "button[aria-label='Pause audiobook']"
      page.execute_script("const audio = document.querySelector('audio'); audio.currentTime = 3; audio.dispatchEvent(new Event('timeupdate'))")
      find("button[aria-label='Pause audiobook']").click
      assert_text "Your place is saved", wait: 12
      saved = users(:one).consumer_progresses.find_by!(book: @audiobook)
      assert_in_delta 3, saved.position_seconds, 2

      visit at("/preview/library")
      within("section.continue") { assert_match(/Resume at 0:0[1-5]/, find("a.resume-link").text) }
      find("section.continue a.card-link", text: "A Listening Life").click
      assert_selector "a.button--primary", text: "Continue listening"
      assert_text(/Resume at 0:0[1-5]/)
      assert_equal saved.attributes, users(:one).consumer_progresses.find_by!(book: @audiobook).attributes
    end

    test "the reading status is saved through the session, CSRF and account checks and keeps the saved place" do
      Consumer::ProgressWriter.new(user: users(:one), book: @audiobook).call(audio_progress.stringify_keys)
      saved = users(:one).consumer_progresses.find_by!(book: @audiobook).attributes
      visit at("/preview/library/#{@audiobook.id}")
      assert_selector "h1", text: "A Listening Life"
      select "Finished", from: "Reading status"
      click_button "Save status"
      assert_text "Saved. Your saved place is kept."
      assert_selector "a.button--primary", text: "Listen again"
      assert_equal "finished", users(:one).consumer_reading_states.find_by!(book: @audiobook).status
      assert_equal saved, users(:one).consumer_progresses.find_by!(book: @audiobook).attributes
      visit at("/preview/library?status=finished")
      assert_selector "article.book-card h3", text: "A Listening Life"
      assert_equal 0, users(:two).consumer_reading_states.count
    end

    test "Back restores the filter, the query and the scroll position, also after a reload" do
      visit at("/preview/library?sort=title")
      click_button "Load more books"
      assert_selector "article.book-card", count: 42
      page.execute_script("window.scrollTo(0, 1500)")
      sleep 0.4
      expected = page.evaluate_script("Math.round(window.scrollY)")
      assert_operator expected, :>, 1000
      target = all("article.book-card h3 a").find { |link| page.evaluate_script("arguments[0].getBoundingClientRect().top > 0", link.native) rescue true }
      title = target.text
      target.click
      assert_selector "h1", text: title
      page.go_back
      assert_current_path at("/preview/library?sort=title"), url: false
      assert_selector "article.book-card", count: 42
      sleep 0.5
      assert_in_delta expected, page.evaluate_script("Math.round(window.scrollY)"), 3

      page.refresh
      assert_selector "article.book-card", count: 42, wait: 15
      sleep 0.8
      assert_in_delta expected, page.evaluate_script("Math.round(window.scrollY)"), 3

      page.execute_script("window.scrollTo(0, 900)")
      sleep 0.4
      expected = page.evaluate_script("Math.round(window.scrollY)")
      visit at("/read")
      assert_text "Your library."
      page.go_back
      assert_current_path at("/preview/library?sort=title"), url: false
      assert_selector "article.book-card", count: 42, wait: 15
      sleep 0.8
      assert_in_delta expected, page.evaluate_script("Math.round(window.scrollY)"), 3

      fill_in "Search your library", with: "novel 07"
      click_button "Search"
      assert_selector "article.book-card", count: 1
      page.go_back
      assert_selector "article.book-card", count: 42
      assert_equal({ "sort" => "title" }, Rack::Utils.parse_query(URI.parse(current_url).query))
      page.go_forward
      assert_selector "article.book-card", count: 1
      assert_field "Search your library", with: "novel 07"
    end

    test "a phone gets a bottom navigation, readable tap targets and no horizontal overflow" do
      page.current_window.resize_to(390, 844)
      visit at("/preview/library")
      assert_selector "article.book-card", count: 30
      assert_no_horizontal_overflow
      nav = page.evaluate_script("(() => { const r = document.querySelector('nav[aria-label=Primary]').getBoundingClientRect(); return [r.bottom, window.innerHeight, getComputedStyle(document.querySelector('nav[aria-label=Primary]')).position] })()")
      assert_equal "fixed", nav[2]
      assert_in_delta nav[1], nav[0], 1
      heights = page.evaluate_script("Array.from(document.querySelectorAll('nav[aria-label=Primary] a, .pill span, button.button, input[type=search], select')).map(node => Math.round(node.getBoundingClientRect().height))")
      assert_operator heights.min, :>=, 44
      assert_operator page.evaluate_script("getComputedStyle(document.querySelector('.book-grid')).gridTemplateColumns.split(' ').length"), :>=, 2
      open_from_search("The Quiet Library")
      assert_selector "h1", text: "The Quiet Library"
      assert_no_horizontal_overflow
      assert_equal [], page.evaluate_script("window.__policyViolations")
    end

    test "a tab built for one account stops and shows nothing when another tab signs in as someone else" do
      visit at("/preview/library")
      assert_selector "article.book-card", count: 30
      visit at("/preview/library/#{@ebook.id}")
      assert_selector "h1", text: "The Quiet Library"
      sign_in(users(:two), visit_first: false)
      page.execute_script("window.dispatchEvent(new Event('focus'))")
      assert_selector "h1", text: "The signed-in account changed", wait: 15
      assert_no_text "The Quiet Library"
      assert_no_selector "nav"
      assert_equal 0, ConsumerReadingState.count
      assert_selector "a", text: "Reload as the current account"
      click_link "Reload as the current account"
      assert_selector "h1", text: "Library"
      assert_text "Signed in as Admin User"
      assert_selector "nav[aria-label=Primary] a", text: "Server"
    end

    test "a stale tab cannot save a status for the account that left" do
      visit at("/preview/library/#{@ebook.id}")
      assert_selector "h1", text: "The Quiet Library"
      select "Finished", from: "Reading status"
      sign_in(users(:two), visit_first: false)
      click_button "Save status"
      assert_selector "h1", text: "The signed-in account changed", wait: 15
      assert_equal 0, ConsumerReadingState.count
    end

    test "losing the session is explained and signing in again returns to the preview" do
      visit at("/preview/library")
      assert_selector "article.book-card", count: 30
      users(:one).sessions.destroy_all
      click_button "Load more books"
      assert_selector "h1", text: "Your session ended", wait: 15
      assert_no_selector "article.book-card"
      click_link "Sign in again"
      assert_current_path at("/session/new")
      fill_in "username", with: "userone"
      fill_in "password", with: PASSWORD
      click_button "Sign in"
      assert_current_path at("/preview/library")
      assert_selector "article.book-card", count: 30
    end

    test "a network failure keeps the books and recovers when the connection returns" do
      visit at("/preview/library")
      assert_selector "article.book-card", count: 30
      page.driver.browser.network_conditions = { offline: true, latency: 0, download_throughput: -1, upload_throughput: -1 }
      click_button "Load more books"
      assert_text "More books could not be loaded.", wait: 20
      assert_selector "article.book-card", count: 30
      page.driver.browser.network_conditions = { offline: false, latency: 0, download_throughput: -1, upload_throughput: -1 }
      assert_no_selector ".inline-error", wait: 15
      assert_selector "article.book-card", count: 30
      click_button "Load more books"
      assert_selector "article.book-card", count: 42, wait: 15
    end

    test "a broken cover falls back to the generated cover and a deleted book is explained" do
      @ebook.update!(cover_url: "https://127.0.0.1:9/missing-cover.jpg")
      visit at("/preview/library?q=Quiet")
      assert_selector "article.book-card h3", text: "The Quiet Library"
      card = find("article.book-card", text: "The Quiet Library")
      assert card.has_selector?(".cover[data-fallback=true] .cover-title", text: "The Quiet Library", wait: 15)
      visit at("/preview/library/#{@ebook.id}")
      assert_selector "h1", text: "The Quiet Library"
      @ebook.destroy!
      visit at("/preview/library/#{@ebook.id}")
      assert_text "This book is no longer in your library"
      click_link "Back to the library"
      assert_selector "h1", text: "Library"
    end

    test "users who are not enabled keep the classic experience and cannot reach the preview" do
      ENV[WebPreview::Access::VARIABLE] = users(:two).id.to_s
      visit at("/preview/library")
      assert_text "The page you were looking for doesn't exist"
      assert_no_selector "#shelfarr-boot", visible: :all
      visit at("/read")
      assert_text "Your library."
    end
  end

  def at(path) = "#{self.class::BASE}#{path}"

  def sign_in(user, visit_first: true)
    session = user.sessions.create!
    signed = ActionDispatch::TestRequest.create.cookie_jar.tap { |jar| jar.signed[:session_id] = session.id }[:session_id]
    clear_browser_offline_state if visit_first
    visit at("/up") if visit_first
    page.driver.browser.manage.add_cookie(name: "session_id", value: signed, path: "/")
  end

  def open_from_search(title)
    visit at("/preview/library")
    fill_in "Search your library", with: title.split.first(2).join(" ")
    click_button "Search"
    click_link title
  end

  def record_policy_violations
    page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: "window.__policyViolations = []; document.addEventListener('securitypolicyviolation', event => window.__policyViolations.push(event.violatedDirective + ' ' + event.blockedURI));")
  end

  def wait_until(what, timeout: 20)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      result = yield
      return result if result
      flunk "Timed out waiting until #{what}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.1
    end
  end

  def assert_no_horizontal_overflow
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")
  end
end

class WebPreviewRootTest < ApplicationSystemTestCase
  BASE = ""
  include WebPreviewFlows
end

class WebPreviewSubpathTest < ApplicationSystemTestCase
  BASE = "/shelf"
  include WebPreviewFlows
end
