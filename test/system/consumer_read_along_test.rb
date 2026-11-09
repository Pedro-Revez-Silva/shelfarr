# frozen_string_literal: true

require "application_system_test_case"
require_relative "../test_helpers/consumer_test_helper"
require_relative "../test_helpers/read_along_fixtures"
require_relative "../support/consumer_reachability"

# Read-along in a real browser under a deployment subpath, with genuine EPUB 3
# Media Overlays and an imported alignment. The narration fixture sounds a
# different pitch for each cue, so the test proves that the highlighted text,
# the manifest interval and the served audio bytes correspond.
class ConsumerReadAlongTest < ApplicationSystemTestCase
  include ConsumerTestHelper
  include ReadAlongFixtures

  BASE = "/shelf"
  APP = Rack::URLMap.new(BASE => ConsumerReachability.new(Rails.application))

  setup do
    ConsumerReachability.reset!
    Consumer::ReadAlong.forget_all
    @previous_app = Capybara.app
    @previous_root = ActionController::Base.relative_url_root
    Capybara.app = APP
    ActionController::Base.relative_url_root = BASE
    Rails.application.importmap.send(:clear_cache)
    page.current_window.resize_to(390, 844)
    prepare_consumer_library
    write_read_along_epub(@epub_path)
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

  test "narration highlights the cue being heard, its audio sounds that cue, and pages follow" do
    open_reader
    assert_empty users(:one).consumer_progresses
    reveal_reading_controls
    assert_text "Narration from this book. Narration covers all 2 sections."
    capture("read-along-controls-mobile.png")

    # Every cue's interval of the served narration sounds that cue's pitch.
    manifest = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1]
      const url = JSON.parse(document.querySelector("[data-consumer-reader-target=publication]").textContent).assets[0].read_along.manifest_url
      fetch(url, { credentials: "same-origin" }).then(response => response.json()).then(done)
    JS
    pitches = page.evaluate_async_script(<<~JS, manifest.fetch("audio").first.fetch("url"), manifest.fetch("cues"))
      const [url, cues, done] = arguments
      fetch(url, { credentials: "same-origin" }).then(response => response.arrayBuffer())
        .then(bytes => new OfflineAudioContext(1, 1, 22050).decodeAudioData(bytes))
        .then(buffer => {
          const data = buffer.getChannelData(0), rate = buffer.sampleRate
          done(cues.map(([, , , begin, end]) => {
            const from = Math.floor(((begin + end) / 2000 - 0.2) * rate), to = Math.floor(((begin + end) / 2000 + 0.2) * rate)
            let crossings = 0
            for (let index = from + 1; index < to; index++) if (data[index - 1] < 0 && data[index] >= 0) crossings++
            return crossings / ((to - from) / rate)
          }))
        }, error => done(String(error)))
    JS
    pitches.each_with_index { |pitch, cue| assert_in_delta tone_frequency(cue), pitch, 12, "cue #{cue}" }

    play_pause("Play")
    hide_reading_controls
    highlighted = []
    wait_until("narration reaches the second chapter", timeout: 25) do
      cue = active_cue
      highlighted << cue if cue && highlighted.last != cue
      time = audio_time
      expected = (time / 2).floor
      # While a cue sounds, its own paragraph (and only it) is highlighted.
      assert_equal "c#{expected}", cue, "at #{time}s" if cue && (time % 2).between?(0.3, 1.5)
      cue == "c6"
    end
    assert_equal %w[c0 c1 c2 c3 c4 c5 c6], highlighted
    within_frame(find(".consumer-ebook iframe")) { assert_text "Cue 7 sounds the willow tone." }
    assert_match(/chapter 2/, find("[data-consumer-reader-target=location]", visible: :all).text(:all))
    assert_selector ".consumer-read-along-pill", visible: true
    capture("read-along-playing-mobile.png")

    find("[data-consumer-reader-target=readAlongPillPlay]").click
    heard = paused_time
    progress = wait_for_heard(@ebook, heard)
    point = progress.locator.dig("locations", "readAlong")
    assert_equal "OEBPS/chapter2.xhtml", progress.locator.fetch("href")
    assert_equal [ "c#{(heard / 2).floor}" ], progress.locator.dig("locations", "fragments")
    assert_in_delta heard * 1000, point.fetch("offset_ms"), 300
    assert_equal manifest.fetch("generation"), point.fetch("generation")
    assert_operator progress.observed_at, :<=, progress.updated_at
  end

  test "restoring writes nothing, a resume rewinds once, and pauses during the replay keep the saved place" do
    open_reader
    reveal_reading_controls
    play_pause("Play")
    wait_until("narration passes nine seconds", timeout: 20) { audio_time > 9 }
    play_pause("Pause")
    saved = wait_for_heard(@ebook, paused_time)
    offset = saved.locator.dig("locations", "readAlong", "offset_ms")
    version = saved.version

    visit at(consumer_publication_path(@ebook))
    wait_until("the narration place is restored") { (audio_time * 1000 - offset).abs < 50 }
    assert_equal "c#{offset / 2000}", active_cue
    sleep 1
    assert_equal version, users(:one).consumer_progresses.find_by!(book: @ebook).version

    reveal_reading_controls
    play_pause("Play")
    wait_until("the resume rewinds five seconds") { audio_time.between?(offset / 1000.0 - 5.2, offset / 1000.0 - 3.5) }
    3.times do
      play_pause("Pause")
      sleep 0.3
      play_pause("Play")
      sleep 0.3
    end
    play_pause("Pause")
    assert_operator audio_time, :<, offset / 1000.0
    sleep 1.5
    stored = users(:one).consumer_progresses.find_by!(book: @ebook)
    assert_equal version, stored.version, "a pause inside the replayed span must not move the saved place back"
    assert_equal offset, stored.locator.dig("locations", "readAlong", "offset_ms")
  end

  test "turning pages while narration plays is browsing; returning follows the narration again" do
    open_reader
    reveal_reading_controls
    play_pause("Play")
    hide_reading_controls
    wait_until("the first cue sounds") { active_cue == "c0" }
    find("[data-consumer-reader-target=viewport]").send_keys(:arrow_right)
    find("[data-consumer-reader-target=viewport]").send_keys(:arrow_right)
    assert_button "Back to the narration", wait: 5
    sleep 1
    browsing = users(:one).consumer_progresses.find_by(book: @ebook)
    assert(browsing.nil? || browsing.locator.dig("locations", "readAlong"), "browsing pages wrote a reading place")
    click_button "Back to the narration"
    wait_until("the page with the heard cue shows") { cue_visible?(active_cue) }
    find("[data-consumer-reader-target=readAlongPillPlay]").click
  end

  test "a downloaded read-along book reads and narrates offline and syncs the heard place with its listening time" do
    open_reader
    reveal_reading_controls
    within(".consumer-offline") do
      click_button "Download"
      assert_text "Available offline", wait: 20
    end
    entries = media_entries.map { |url| url.sub(%r{\A.*?/read/}, "/read/").gsub(/\h{64}/, "ID") }
    prefix = "/read/#{@ebook.id}/assets/ID/read_along"
    assert_equal [ prefix, *%w[META-INF/container.xml OEBPS/content.opf OEBPS/nav.xhtml OEBPS/chapter1.xhtml OEBPS/chapter2.xhtml
      OEBPS/style.css OEBPS/audio/narration.mp3].map { |path| "#{prefix}/resources/#{path}" } ].sort, entries.sort
    assert_not_includes entries, "/read/#{@ebook.id}/assets/ID", "the whole EPUB is not downloaded for read-along"

    ConsumerReachability.offline = true
    visit at(consumer_publication_path(@ebook))
    assert_selector ".consumer-ebook iframe", wait: 20
    within_frame(find(".consumer-ebook iframe")) { assert_text "Cue 1 sounds the quiet tone." }
    reveal_reading_controls
    play_pause("Play")
    wait_until("offline narration plays past six seconds", timeout: 20) { audio_time > 6 }
    assert_equal "c3", active_cue
    play_pause("Pause")
    heard_at = Time.current
    assert_text "Saved on this device. It will sync when you're back online.", wait: 12
    assert_empty users(:one).consumer_progresses
    capture("read-along-offline-mobile.png")

    sleep 1.2
    ConsumerReachability.offline = false
    page.execute_script("window.dispatchEvent(new Event('online'))")
    progress = wait_for_progress(@ebook)
    assert_operator progress.observed_at, :<=, heard_at + 0.5
    assert_operator progress.observed_at, :<, progress.updated_at - 0.5, "the activity time, not the sync time, is stored"
    assert_equal "c3", progress.locator.dig("locations", "fragments", 0)
  end

  test "a partly evicted read-along download is never ready, and a new alignment is an update" do
    open_reader
    reveal_reading_controls
    within(".consumer-offline") do
      click_button "Download"
      assert_text "Available offline", wait: 20
    end
    page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1]
      caches.keys().then(names => Promise.all(names.filter(name => name.startsWith("shelfarr-offline-media")).map(name =>
        caches.open(name).then(cache => cache.keys().then(keys => Promise.all(keys.filter(key => key.url.endsWith("chapter2.xhtml")).map(key => cache.delete(key))))))))
        .then(() => done(true))
    JS
    visit at(consumer_publication_path(@ebook))
    reveal_reading_controls
    within(".consumer-offline") { assert_text "The browser removed part of this download", wait: 15 }
    assert_selector ".consumer-offline:not([data-offline-state=ready])"
    within(".consumer-offline") do
      click_button "Try again"
      assert_text "Available offline", wait: 20
    end

    # The same file with a different (still genuine) overlay is a new edition.
    cues = default_read_along_cues.map { |cue| cue.merge(clip_end: format("0:00:%06.3f", Consumer::ReadAlong::Clock.milliseconds(cue[:clip_end]) / 1000.0 - 0.1)) }
    write_read_along_epub(@epub_path, cues: cues)
    visit at(consumer_publication_path(@ebook))
    reveal_reading_controls
    within(".consumer-offline") { assert_text "an older edition", wait: 15 }
  end

  test "an interrupted read-along download is paused, not ready, and resumes to a complete copy" do
    open_reader
    reveal_reading_controls
    ConsumerReachability.drop = %r{/read_along/resources/OEBPS/audio/narration\.mp3\z}
    within(".consumer-offline") do
      click_button "Download"
      assert_text "Download paused", wait: 20
    end
    assert_selector ".consumer-offline:not([data-offline-state=ready])"
    assert(media_entries.none? { |url| url.end_with?("/read_along") }, "the manifest is stored only after every file it lists")
    ConsumerReachability.drop = nil
    within(".consumer-offline") do
      click_button "Resume"
      assert_text "Available offline", wait: 20
    end
    assert(media_entries.any? { |url| url.end_with?("/narration.mp3") })
  end

  test "cancelling an interrupted narration download removes its already stored resources" do
    open_reader
    reveal_reading_controls
    ConsumerReachability.drop = %r{/read_along/resources/OEBPS/audio/narration\.mp3\z}
    within(".consumer-offline") do
      click_button "Download"
      assert_text "Download paused", wait: 20
    end
    assert(media_entries.any? { |url| url.end_with?("/chapter1.xhtml") }, "text arrived before narration was interrupted")
    assert_selector ".consumer-offline:not([data-offline-state=ready])"
    within(".consumer-offline") do
      click_button "Cancel"
      assert_button "Download", wait: 10
    end
    assert_empty media_entries, "Cancel must reclaim the text and audio already stored, not only its unfinished manifest"
  end

  test "cancelling an interrupted narration update keeps exactly the earlier complete download" do
    open_reader
    reveal_reading_controls
    within(".consumer-offline") do
      click_button "Download"
      assert_text "Available offline", wait: 20
    end
    previous = media_entries.sort
    cues = default_read_along_cues.map { |cue| cue.merge(clip_end: format("0:00:%06.3f", Consumer::ReadAlong::Clock.milliseconds(cue[:clip_end]) / 1000.0 - 0.1)) }
    write_read_along_epub(@epub_path, cues: cues)
    visit at(consumer_publication_path(@ebook))
    reveal_reading_controls
    ConsumerReachability.drop = %r{/read_along/resources/OEBPS/audio/narration\.mp3\z}
    within(".consumer-offline") do
      click_button "Update"
      assert_text "Download paused", wait: 20
    end
    assert_operator media_entries.size, :>, previous.size, "the replacement stored new text before interruption"
    within(".consumer-offline") do
      click_button "Cancel"
      assert_text "Available offline", wait: 10
      assert_text "an older edition"
    end
    assert_equal previous, media_entries.sort, "Cancel keeps the prior complete edition and removes only replacement resources"
  end

  test "an imported alignment narrates a separate audiobook and saves both places at the hearing time" do
    write_read_along_epub(@epub_path, overlay: false)
    FileUtils.cp(TONES, @audio_path)
    Consumer::ReadAlong::Import.new(ebook: @ebook, audiobook: @audiobook).call(read_along_document(epub_path: @epub_path, audio_path: @audio_path))
    open_reader
    reveal_reading_controls
    assert_text "Narrated by “#{@audiobook.title}”, aligned to this edition."
    play_pause("Play")
    wait_until("narration passes five seconds", timeout: 20) { audio_time > 5 }
    play_pause("Pause")
    heard = paused_time
    ebook = wait_for_heard(@ebook, heard)
    audiobook = wait_for_progress(@audiobook, version: ebook.version)
    assert_equal ebook.observed_at, audiobook.observed_at
    assert_in_delta heard, audiobook.position_seconds, 0.3
    assert_equal Consumer::LibraryAssets.new(@audiobook).list.first.id, audiobook.asset_id
    assert_equal "c#{(heard / 2).floor}", ebook.locator.dig("locations", "fragments", 0)

    # Listening further in the audiobook's own player is offered, not written.
    visit at(consumer_publication_path(@audiobook))
    assert_selector "[data-consumer-reader-target=duration]", text: /0:1[56]/, wait: 15
    page.execute_script("const seek = document.querySelector('[data-consumer-reader-target=seek]'); seek.value = String(13 / 16 * 100); seek.dispatchEvent(new Event('change', { bubbles: true }))")
    wait_for_progress(@audiobook, version: audiobook.version + 1)
    ebook_version = ebook.version
    open_reader
    assert_text "You listened further in the audiobook.", wait: 10
    click_button "Go there"
    wait_until("the audiobook's place shows") { active_cue == "c6" && (audio_time - 13).abs < 0.1 }
    sleep 1
    assert_equal ebook_version, users(:one).consumer_progresses.find_by!(book: @ebook).version
  end

  test "a refused overlay explains itself and the book still reads" do
    write_read_along_epub(@epub_path, cues: default_read_along_cues.each_with_index.map { |cue, index| index == 4 ? cue.merge(clip_begin: "0:00:07.000") : cue })
    open_reader
    within_frame(find(".consumer-ebook iframe")) { assert_text "Cue 1 sounds the quiet tone." }
    reveal_reading_controls
    assert_text "This book's narration data can't be used"
    assert_text "Reading works as usual."
    assert_no_selector "[data-consumer-reader-target=readAlongPlay]", visible: true
    click_button "Next →"
    wait_for_progress(@ebook)
    capture("read-along-refused-mobile.png")
  end

  private

  def open_reader
    visit at(consumer_publication_path(@ebook))
    assert_selector ".consumer-ebook iframe", wait: 20
    within_frame(find(".consumer-ebook iframe")) { assert_text "Cue 1 sounds the quiet tone." }
  end

  # The overlay's narration button, by its current label.
  def play_pause(label)
    find("[data-consumer-reader-target=readAlongPlay]", text: label).click
  end

  def paused_time
    wait_until("narration pauses") { page.evaluate_script("document.querySelector('[data-consumer-reader-target=readAlongAudio]').paused") }
    audio_time
  end

  # The saved place once it is the one heard at `seconds` (earlier five-second
  # checkpoints may arrive first).
  def wait_for_heard(book, seconds, timeout: 20)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      progress = users(:one).consumer_progresses.find_by(book: book)
      offset = progress&.locator&.dig("locations", "readAlong", "offset_ms")
      return progress if offset && (offset - seconds * 1000).abs < 300
      flunk "The heard place (#{seconds}s) wasn't saved for #{book.title}; last #{offset.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.2
    end
  end

  def audio_time
    page.evaluate_script("document.querySelector('[data-consumer-reader-target=readAlongAudio]').currentTime")
  end

  def active_cue
    page.evaluate_script("(document.querySelector('.consumer-ebook iframe')?.contentDocument?.querySelector('.shelfarr-read-along-active')?.id || '').replace('user-content-', '') || null")
  end

  def cue_visible?(cue)
    return false unless cue

    page.evaluate_script(<<~JS)
      (() => {
        const frame = document.querySelector('.consumer-ebook iframe')
        const element = frame.contentDocument.getElementById('user-content-#{cue}')
        const rect = element?.getClientRects()[0], bounds = document.querySelector('[data-consumer-reader-target=viewport]').getBoundingClientRect()
        if (!rect) return false
        const x = frame.getBoundingClientRect().left + rect.left
        return x >= bounds.left - 2 && x < bounds.right - 2
      })()
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

  def sign_in(user)
    session = user.sessions.create!
    signed = ActionDispatch::TestRequest.create.cookie_jar.tap { |jar| jar.signed[:session_id] = session.id }[:session_id]
    visit at("/read/offline")
    page.driver.browser.manage.add_cookie(name: "session_id", value: signed, path: "/")
    clear_browser_offline_state
  end

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
    return if page.has_selector?("[data-consumer-reader-target=controls]", visible: true, wait: 0)

    find("[data-consumer-reader-target=viewport]").send_keys(:escape)
    assert_selector "[data-consumer-reader-target=controls]", visible: true
  end

  def hide_reading_controls
    click_button "Done" if page.has_selector?("[data-consumer-reader-target=controls]", visible: true, wait: 0)
    assert_no_selector "[data-consumer-reader-target=controls]", visible: true
  end

  def capture(filename)
    return unless ENV["CONSUMER_SCREENSHOT_DIR"].present?

    FileUtils.mkdir_p(ENV.fetch("CONSUMER_SCREENSHOT_DIR"))
    page.save_screenshot(File.join(ENV.fetch("CONSUMER_SCREENSHOT_DIR"), filename))
  end
end
