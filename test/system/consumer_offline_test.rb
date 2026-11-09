# frozen_string_literal: true

require "application_system_test_case"
require_relative "../test_helpers/consumer_test_helper"
require_relative "../support/consumer_reachability"

# Deliberate offline reading and listening in a real browser, served under a
# deployment subpath. "Offline" closes the server's connections, so the service
# worker, the offline shell and the progress outbox meet genuine network errors.
class ConsumerOfflineTest < ApplicationSystemTestCase
  include ConsumerTestHelper

  BASE = "/shelf"
  APP = Rack::URLMap.new(BASE => ConsumerReachability.new(Rails.application))

  setup do
    ConsumerReachability.reset!
    @previous_app = Capybara.app
    @previous_root = ActionController::Base.relative_url_root
    Capybara.app = APP
    ActionController::Base.relative_url_root = BASE
    # Import map paths are computed once per process; this test's subpath
    # must not reuse another test's root paths, nor leave its own behind.
    Rails.application.importmap.send(:clear_cache)
    page.current_window.resize_to(390, 844)
    prepare_consumer_library
    FileUtils.cp(Rails.root.join("test/fixtures/files/consumer_sample.mp3"), @audio_path)
    File.unlink(@epub_path)
    write_consumer_epub(@epub_path, chapter: "Pages kept for a journey. " * 900)
    sign_in(users(:one))
  end

  teardown do
    ConsumerReachability.reset!
    begin
      visit "#{BASE}/read/offline"
      clear_browser_offline_state
    rescue StandardError
      nil
    end
    Capybara.app = @previous_app
    ActionController::Base.relative_url_root = @previous_root
    Rails.application.importmap.send(:clear_cache)
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  test "a downloaded audiobook plays offline, keeps its place and syncs it with the listening time" do
    visit at(consumer_publication_path(@audiobook))
    assert_selector "[data-consumer-reader-target=duration]", text: /0:0[89]/, wait: 15
    within(".consumer-offline") do
      assert_text "Listen without a connection"
      click_button "Download"
      assert_text "Available offline", wait: 20
    end
    assert_selector ".consumer-offline[data-offline-state=ready]"
    assert_link "Manage downloads", href: at(consumer_downloads_path)
    assert_no_horizontal_overflow
    capture("offline-audio-ready-mobile.png")

    visit at(consumer_library_path)
    assert_selector "a[data-offline-publication='#{@audiobook.id}'] .consumer-offline-chip", text: "On this device", wait: 10
    assert_link "Downloads on this device →"
    capture("offline-library-online-mobile.png")

    ConsumerReachability.offline = true
    visit at(consumer_publication_path(@audiobook))
    assert_selector "h1", text: "A Listening Life", wait: 15
    assert_selector ".consumer-preview", text: "Offline"
    assert_selector "[data-consumer-reader-target=duration]", text: /0:0[89]/, wait: 15
    find("button[aria-label='Play audiobook']").click
    wait_until("offline audio plays") { page.evaluate_script("document.querySelector('audio').currentTime") > 1 }
    # Seeking asks the worker for a byte range of the cached file.
    page.execute_script("const audio = document.querySelector('audio'); audio.currentTime = 6")
    wait_until("the seek lands") { page.evaluate_script("document.querySelector('audio').currentTime") >= 6 }
    find("button[aria-label='Pause audiobook']").click
    paused = Time.current
    assert_text "Saved on this device. It will sync when you're back online.", wait: 12
    assert_empty users(:one).consumer_progresses
    assert_no_horizontal_overflow
    capture("offline-audio-playing-mobile.png")

    visit at(consumer_library_path)
    assert_selector "h1", text: "On this device.", wait: 15
    assert_selector ".consumer-download", text: "A Listening Life"
    assert_link "Listen"
    capture("offline-downloads-mobile.png")

    click_link "Listen"
    assert_selector "[data-consumer-reader-target=duration]", text: /0:0[89]/, wait: 15
    assert_selector "[data-consumer-reader-target=elapsed]", text: /0:0[67]/, wait: 10

    ConsumerReachability.offline = false
    page.execute_script("window.dispatchEvent(new Event('online'))")
    assert_text "You're back online.", wait: 15
    progress = wait_for_progress(@audiobook)
    assert_in_delta 6.5, progress.position_seconds, 1.5
    assert_in_delta paused.to_f, progress.observed_at.to_f, 15
    assert_operator progress.updated_at, :>, progress.observed_at
    assert_text "Your place is saved to your account", wait: 12
    capture("offline-audio-reconnected-mobile.png")
  end

  test "a downloaded ebook reopens offline in the quiet reader and turns pages" do
    visit at(consumer_publication_path(@ebook))
    assert_selector ".consumer-ebook iframe", wait: 20
    assert_no_selector ".consumer-offline", visible: true
    reveal_reading_controls
    within(".consumer-offline") do
      assert_text "Read without a connection"
      click_button "Download"
      assert_text "Available offline", wait: 20
    end
    capture("offline-ebook-controls-mobile.png")

    ConsumerReachability.offline = true
    visit at(consumer_publication_path(@ebook))
    assert_selector ".consumer-ebook iframe", wait: 20
    within_frame(find(".consumer-ebook iframe")) { assert_text "Pages kept for a journey." }
    assert_no_selector ".consumer-header", visible: true
    assert_selector "[data-consumer-reader-target=location]", text: %r{\A1 / \d+}, visible: :all, wait: 10
    find("[data-consumer-reader-target=viewport]").send_keys(:arrow_right)
    assert_selector "[data-consumer-reader-target=location]", text: %r{\A2 / \d+}, visible: :all, wait: 10
    turned = Time.current
    assert_selector "[data-consumer-reader-target=notice]", text: "Saved on this device. It will sync when you're back online.", wait: 12
    assert_no_horizontal_overflow
    capture("offline-ebook-reading-mobile.png")

    ConsumerReachability.offline = false
    page.execute_script("window.dispatchEvent(new Event('online'))")
    progress = wait_for_progress(@ebook)
    assert_operator progress.locator.dig("locations", "progression"), :>, 0
    assert_in_delta turned.to_f, progress.observed_at.to_f, 15
  end

  test "another account never sees these downloads, and the sign-in page forgets the offline account" do
    download_audiobook
    # Signing out shows the sign-in page, which forgets the offline account.
    page.driver.browser.manage.delete_all_cookies
    visit at(new_session_path)
    wait_until("the offline account is forgotten") { offline_account.nil? }
    ConsumerReachability.offline = true
    visit at(consumer_library_path)
    assert_text "Sign in to use downloads", wait: 15
    assert_no_text "A Listening Life"
    visit at(consumer_publication_path(@audiobook))
    assert_text "Sign in to use downloads", wait: 15
    assert_no_selector "audio", visible: :all
    capture("offline-signed-out-mobile.png")

    ConsumerReachability.offline = false
    sign_in(users(:two), clear: false)
    visit at(consumer_library_path)
    assert_text "Your library."
    wait_until("the new account is confirmed") { offline_account == users(:two).id.to_s }
    assert_no_link "Downloads on this device →"
    ConsumerReachability.offline = true
    visit at(consumer_library_path)
    assert_text "Nothing downloaded yet", wait: 15
    assert_no_text "A Listening Life"
    visit at(consumer_publication_path(@audiobook))
    assert_text "This book isn't available on this device.", wait: 15
    assert_no_selector "audio", visible: :all

    ConsumerReachability.offline = false
    visit at(consumer_downloads_path)
    assert_text "Downloads from another account on this browser use 32.5 KB. They stay hidden from you.", wait: 15
    assert_no_text "A Listening Life"
    capture("offline-other-account-mobile.png")
    click_button "Remove other accounts' downloads"
    click_button "Remove the other account's downloads?"
    assert_no_text "Downloads from another account", wait: 10
    assert_equal 0, media_entries.size
  end

  test "an interrupted download is paused and resumes with only the files it still needs" do
    tracks = use_two_tracks
    ConsumerReachability.drop = %r{/assets/#{tracks.last.id}\z}
    visit at(consumer_publication_path(@audiobook))
    within(".consumer-offline") do
      click_button "Download"
      assert_text "Download paused at 50%", wait: 20
      assert_text "The connection was lost. Resume when you're back online."
      assert_button "Resume"
      assert_button "Cancel"
    end
    assert_no_horizontal_overflow
    capture("offline-download-paused-mobile.png")
    visit at(consumer_library_path)
    assert_selector "a[data-offline-publication='#{@audiobook.id}'] .consumer-offline-chip", text: "Download not finished", wait: 10
    ConsumerReachability.offline = true
    visit at(consumer_publication_path(@audiobook))
    assert_text "This book isn't available on this device.", wait: 15

    ConsumerReachability.offline = false
    ConsumerReachability.drop = nil
    visit at(consumer_publication_path(@audiobook))
    ConsumerReachability.requests.clear
    within(".consumer-offline") do
      click_button "Resume"
      assert_text "Available offline · 65 KB", wait: 20
    end
    fetched = drain(ConsumerReachability.requests).grep(%r{/assets/})
    assert_equal [ "#{BASE}#{consumer_asset_path(@audiobook, tracks.last.id)}" ], fetched
    assert_equal 2, media_entries.size
  end

  test "cancelling a download in progress discards what it stored" do
    use_two_tracks
    ConsumerReachability.hold = %r{/read/\d+/assets/}
    visit at(consumer_publication_path(@audiobook))
    within(".consumer-offline") do
      click_button "Download"
      assert_text "Downloading · 0% of 65 KB", wait: 15
      assert_selector "progress", visible: true
      click_button "Cancel"
      assert_text "Listen without a connection", wait: 15
      assert_button "Download"
    end
    ConsumerReachability.release!
    sleep 0.5
    assert_equal 0, media_entries.size
  end

  test "tabs share one download: another tab follows it and can cancel it" do
    use_two_tracks
    ConsumerReachability.hold = %r{/read/\d+/assets/}
    visit at(consumer_publication_path(@audiobook))
    within(".consumer-offline") do
      click_button "Download"
      assert_text "Downloading · 0% of 65 KB", wait: 15
    end
    other = open_new_window
    within_window(other) do
      visit at(consumer_publication_path(@audiobook))
      within(".consumer-offline") do
        assert_text "Downloading", wait: 15
        click_button "Cancel"
        assert_text "Listen without a connection", wait: 15
      end
    end
    within(".consumer-offline") { assert_text "Listen without a connection", wait: 15 }
    ConsumerReachability.release!
    sleep 0.5
    assert_equal 0, media_entries.size
    other.close
  end

  test "a replaced edition offers an update and keeps the older copy until it is complete" do
    visit at(consumer_publication_path(@ebook))
    assert_selector ".consumer-ebook iframe", wait: 20
    reveal_reading_controls
    within(".consumer-offline") do
      click_button "Download"
      assert_text "Available offline", wait: 20
    end
    old = consumer_asset(@ebook)
    sleep 1.1 # a later modification time, as a real replacement would have
    File.unlink(@epub_path)
    write_consumer_epub(@epub_path, chapter: "A revised edition for the journey. " * 600)
    current = consumer_asset(@ebook)
    assert_not_equal old.id, current.id

    visit at(consumer_publication_path(@ebook))
    assert_selector ".consumer-ebook iframe", wait: 20
    reveal_reading_controls
    within(".consumer-offline") do
      assert_text "Available offline · an older edition", wait: 15
      assert_text "The server has a newer file."
      capture("offline-ebook-update-mobile.png")
      click_button "Update"
      assert_text(/Available offline · [\d.]+ KB/, wait: 20)
    end
    assert_equal [ current.id ], media_entries.map { |url| url[/\h{64}\z/] }

    ConsumerReachability.offline = true
    visit at(consumer_publication_path(@ebook))
    assert_selector ".consumer-ebook iframe", wait: 20
    within_frame(find(".consumer-ebook iframe")) { assert_text "A revised edition for the journey." }
  end

  test "files the browser evicted are never shown as ready" do
    download_audiobook
    page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1]
      caches.keys().then(names => Promise.all(names.filter(name => name.startsWith("shelfarr-offline-media")).map(name =>
        caches.open(name).then(cache => cache.keys().then(keys => Promise.all(keys.map(key => cache.delete(key))))))))
        .then(() => done(true))
    JS
    visit at(consumer_downloads_path)
    assert_text "Download stopped", wait: 15
    assert_text "The browser removed part of this download. Download it again."
    assert_selector "button[aria-label='Try again: A Listening Life']", text: "Try again"
    capture("offline-evicted-mobile.png")
    ConsumerReachability.offline = true
    visit at(consumer_publication_path(@audiobook))
    assert_text "This book isn't available on this device.", wait: 15
  end

  test "an offline copy opens at the place most recently saved online" do
    download_audiobook
    page.execute_script("const seek = document.querySelector('#consumer-seek'); seek.value = 60; seek.dispatchEvent(new Event('input')); seek.dispatchEvent(new Event('change'))")
    saved = wait_for_progress(@audiobook)
    assert_text "Your place is saved to your account", wait: 12
    ConsumerReachability.offline = true
    visit at(consumer_publication_path(@audiobook))
    assert_selector "[data-consumer-reader-target=elapsed]", text: "0:0#{saved.position_seconds.floor}", wait: 15
  end

  test "the first download retains an audiobook place already confirmed during this visit" do
    visit at(consumer_publication_path(@audiobook))
    assert_selector "[data-consumer-reader-target=duration]", text: /0:0[89]/, wait: 15
    page.execute_script("const seek = document.querySelector('#consumer-seek'); seek.value = 60; seek.dispatchEvent(new Event('input')); seek.dispatchEvent(new Event('change'))")
    saved = wait_for_progress(@audiobook)
    assert_text "Your place is saved to your account", wait: 12
    within(".consumer-offline") do
      click_button "Download"
      assert_text "Available offline", wait: 20
    end

    ConsumerReachability.offline = true
    visit at(consumer_publication_path(@audiobook))
    assert_selector "[data-consumer-reader-target=elapsed]", text: "0:0#{saved.position_seconds.floor}", wait: 15
    assert_equal saved.version, saved.reload.version, "opening the download creates no activity"
  end

  test "the first download retains an ebook page already confirmed during this visit" do
    visit at(consumer_publication_path(@ebook))
    assert_selector ".consumer-ebook iframe", wait: 20
    find("[data-consumer-reader-target=viewport]").send_keys(:arrow_right)
    assert_selector "[data-consumer-reader-target=location]", text: %r{\A2 / \d+}, visible: :all, wait: 10
    saved = wait_for_progress(@ebook)
    assert_selector "[data-consumer-reader-target=syncStatus]", text: "Your place is saved to your account", visible: :all, wait: 12
    reveal_reading_controls
    within(".consumer-offline") do
      click_button "Download"
      assert_text "Available offline", wait: 20
    end

    ConsumerReachability.offline = true
    visit at(consumer_publication_path(@ebook))
    assert_selector ".consumer-ebook iframe", wait: 20
    assert_selector "[data-consumer-reader-target=location]", text: %r{\A2 / \d+}, visible: :all, wait: 15
    assert_equal saved.version, saved.reload.version, "opening the download creates no activity"
  end

  test "Downloads Resume refetches completed tracks evicted while the download was paused" do
    tracks = use_two_tracks
    ConsumerReachability.drop = %r{/assets/#{tracks.last.id}\z}
    visit at(consumer_publication_path(@audiobook))
    within(".consumer-offline") do
      click_button "Download"
      assert_text "Download paused at 50%", wait: 20
    end
    visit at(consumer_downloads_path)
    assert_text "Paused at 50%", wait: 15
    page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      caches.keys().then(async names => {
        for (const name of names.filter(n => n.startsWith("shelfarr-offline-media"))) {
          const cache = await caches.open(name);
          for (const request of await cache.keys()) await cache.delete(request);
        }
      }).then(() => done(true));
    JS
    ConsumerReachability.drop = nil
    find("button[aria-label='Resume: A Listening Life']").click
    assert_text "Available offline", wait: 20
    assert_equal tracks.map(&:id).sort, media_entries.map { |url| url[/\h{64}\z/] }.sort
    ConsumerReachability.offline = true
    visit at(consumer_publication_path(@audiobook))
    assert_selector "h1", text: "A Listening Life", wait: 15
    assert_no_text "This book isn't available on this device."
    assert_selector "[data-consumer-reader-target=duration]", text: /0:0[89]/, wait: 15
  end

  test "replacing an in-flight edition starts its replacement after releasing the download lock" do
    visit at(consumer_publication_path(@audiobook))
    result = using_wait_time(10) do
      page.evaluate_async_script(<<~JS)
        const done = arguments[arguments.length - 1];
        (async () => {
          const offline = await import("consumer_offline");
          const publication = JSON.parse(document.querySelector("script[data-consumer-reader-target=publication]").textContent);
          await offline.confirmAccount({base: "/shelf", account: publication.progress_scope.account, maxAgeDays: 30});
          let release, started;
          const gate = new Promise(resolve => release = resolve), begun = new Promise(resolve => started = resolve);
          const original = window.fetch;
          let calls = 0;
          window.fetch = async (url, options) => {
            if (!String(url).includes("/assets/")) return original(url, options);
            calls++;
            if (calls === 1) { started(); await gate; }
            const id = String(url).split("/").at(-1);
            return new Response(new Uint8Array(publication.assets[0].size_bytes), {status: 200, headers: {
              ETag: '"' + id + '"', "Content-Length": String(publication.assets[0].size_bytes)
            }});
          };
          try {
            const key = await offline.download(publication);
            await begun;
            const next = structuredClone(publication);
            next.assets[0].id = "b".repeat(64);
            next.assets[0].content_url = next.assets[0].content_url.replace(/[a-f0-9]{64}$/, next.assets[0].id);
            await offline.download(next);
            release();
            for (let i = 0; i < 200; i++) {
              const record = await offline.getRecord(key);
              if (!record.pending && !await offline.isRunning(key)) {
                return {calls, ready: record.publication?.assets[0].id};
              }
              await new Promise(resolve => setTimeout(resolve, 25));
            }
            return {problem: "replacement never became ready", calls};
          } finally { window.fetch = original; }
        })().then(done, error => done({problem: String(error)}));
      JS
    end
    assert_nil result["problem"], result.inspect
    assert_equal 2, result["calls"]
    assert_equal "b" * 64, result["ready"]
    assert_equal [ "b" * 64 ], media_entries.map { |url| url[/\h{64}\z/] }
  end

  private

  def download_audiobook
    visit at(consumer_publication_path(@audiobook))
    assert_selector "[data-consumer-reader-target=duration]", text: /0:0[89]/, wait: 15
    within(".consumer-offline") do
      click_button "Download"
      assert_text "Available offline", wait: 20
    end
  end

  def use_two_tracks
    directory = File.join(@root, "Audio chapters")
    FileUtils.mkdir_p(directory)
    %w[Chapter1.mp3 Chapter2.mp3].each { |name| FileUtils.cp(@audio_path, File.join(directory, name)) }
    @audiobook.update!(file_path: directory)
    Consumer::LibraryAssets.new(@audiobook).list
  end

  def drain(queue)
    items = []
    items << queue.pop until queue.empty?
    items
  end

  # Synthetic reads of this test origin's offline storage.
  def offline_account
    page.evaluate_async_script(<<~JS, "#{Capybara.current_session.server.base_url}#{BASE}")
      const [deployment, done] = arguments
      const request = indexedDB.open("shelfarr-offline", 1)
      request.onsuccess = () => {
        const db = request.result
        if (!db.objectStoreNames.contains("accounts")) { db.close(); return done(null) }
        const read = db.transaction("accounts").objectStore("accounts").get(deployment)
        read.onsuccess = () => { db.close(); done(read.result?.account ?? null) }
      }
      request.onerror = () => done(null)
    JS
  end

  def media_entries
    page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1]
      caches.keys().then(async names => {
        const urls = []
        for (const name of names.filter(name => name.startsWith("shelfarr-offline-media"))) {
          for (const request of await (await caches.open(name)).keys()) urls.push(request.url)
        }
        done(urls)
      })
    JS
  end

  def at(path) = "#{BASE}#{path}"

  def sign_in(user, clear: true)
    session = user.sessions.create!
    signed = ActionDispatch::TestRequest.create.cookie_jar.tap { |jar| jar.signed[:session_id] = session.id }[:session_id]
    visit at("/read/offline")
    page.driver.browser.manage.add_cookie(name: "session_id", value: signed, path: "/")
    clear_browser_offline_state if clear
  end

  # Synthetic cleanup of this test origin's offline state between tests.
  def clear_browser_offline_state
    page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1]
      ;(async () => {
        for (const registration of await navigator.serviceWorker.getRegistrations()) await registration.unregister()
        for (const name of await caches.keys()) await caches.delete(name)
        await new Promise(resolve => { const request = indexedDB.deleteDatabase("shelfarr-offline"); request.onsuccess = request.onerror = request.onblocked = resolve })
        localStorage.clear()
      })().then(() => done(true), error => done(String(error)))
    JS
  end

  def wait_for_progress(book, version: 1, timeout: 20)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      progress = users(:one).consumer_progresses.find_by(book: book)
      return progress if progress && progress.version >= version
      flunk "No saved progress (version #{version}) for #{book.title}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.2
    end
  end

  def wait_until(what, timeout: 15)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "Timed out waiting until #{what}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.1
    end
  end

  def reveal_reading_controls
    find("[data-consumer-reader-target=viewport]").send_keys(:escape)
    assert_selector "[data-consumer-reader-target=controls]", visible: true
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
