# frozen_string_literal: true

require "application_system_test_case"
require_relative "../test_helpers/consumer_test_helper"

class ConsumerReaderTest < ApplicationSystemTestCase
  include ConsumerTestHelper

  setup do
    prepare_consumer_library
    FileUtils.cp(Rails.root.join("test/fixtures/files/consumer_sample.mp3"), @audio_path)
    sign_in_as(users(:one))
    page.execute_script("localStorage.removeItem('shelfarr.reader.preferences.v1')")
  end
  teardown { FileUtils.remove_entry(@root) if @root && File.exist?(@root) }

  test "mobile shelf leads to actual EPUB pages with safe reader isolation and saved progress" do
    File.unlink(@epub_path)
    chapter = "Every story has a beginning. " * 600
    write_consumer_epub(@epub_path, chapter: chapter + '<script>window.parent.consumerXss=true</script><form action="https://example.invalid"><input/></form><img src="https://example.invalid/tracker" onerror="window.parent.consumerXss=true"/>')
    page.current_window.resize_to(390, 844)
    visit consumer_library_path(type: "ebook")
    assert_text "Your library."
    assert_no_horizontal_overflow
    capture("consumer-library-mobile.png")
    click_link "The Quiet Library", match: :first
    assert_selector ".consumer-ebook iframe", wait: 20
    within_frame(find(".consumer-ebook iframe")) do
      assert_text "Every story has a beginning."
      scripts = page.evaluate_script("Array.from(document.querySelectorAll('script')).map(script => script.outerHTML)")
      assert_empty scripts, scripts.join("\n")
      assert_no_selector "form", visible: :all
    end
    assert_equal "undefined", page.evaluate_script("typeof window.consumerXss")
    assert_not_includes find(".consumer-ebook iframe")["sandbox"].split, "allow-scripts"
    assert_empty users(:one).consumer_progresses
    assert_no_horizontal_overflow
    capture("consumer-ebook-mobile.png")
    find("[data-consumer-reader-target=viewport]").send_keys(:arrow_right)
    progress = wait_for_progress(@ebook)
    assert_equal "OEBPS/chapter.xhtml", progress.locator.fetch("href")
    assert_operator progress.locator.fetch("locations").fetch("progression"), :>, 0
    assert_operator progress.observed_at, :<=, progress.updated_at
    assert_no_horizontal_overflow
  end

  test "the mobile player plays real audio seeks and saves listening position" do
    page.current_window.resize_to(390, 844)
    visit consumer_publication_path(@audiobook)
    assert_selector "[data-consumer-reader-target=duration]", text: /0:0[89]/, wait: 15
    find("button[aria-label='Play audiobook']").click
    assert_selector "button[aria-label='Pause audiobook']"
    assert page.evaluate_script("document.querySelector('audio').paused === false")
    page.execute_script("const audio = document.querySelector('audio'); audio.currentTime = 3; audio.dispatchEvent(new Event('timeupdate'))")
    find("button[aria-label='Pause audiobook']").click
    assert_text "Your place is saved", wait: 12
    assert_in_delta 3, users(:one).consumer_progresses.find_by!(book: @audiobook).position_seconds, 2
    assert_no_horizontal_overflow
    capture("consumer-audio-mobile.png")
  end

  test "relative internal EPUB links use the publication path instead of the app route" do
    File.unlink(@epub_path)
    write_consumer_epub(@epub_path, chapter: 'A first chapter. <a href="two.xhtml">Keep reading</a>', second_chapter: "The next part of the story.")
    visit consumer_publication_path(@ebook)
    assert_selector ".consumer-ebook iframe", wait: 20
    within_frame(find(".consumer-ebook iframe")) { click_link "Keep reading" }
    # The next section replaces the book frame; enter the new one.
    assert_selector "[data-consumer-reader-target=location]", text: "chapter 2", visible: :all, wait: 10
    within_frame(find(".consumer-ebook iframe")) { assert_text "The next part of the story." }
    version = wait_for_progress(@ebook).version
    reveal_reading_controls
    click_link "← Your library"
    assert_current_path consumer_library_path
    assert_text "Your library."
    page.go_back
    assert_selector ".consumer-ebook iframe", wait: 20
    within_frame(find(".consumer-ebook iframe")) { assert_text "The next part of the story." }
    assert_equal version, users(:one).consumer_progresses.find_by!(book: @ebook).version
  end

  test "selected playback speed survives changing tracks" do
    directory = File.join(@root, "Audio tracks")
    FileUtils.mkdir_p(directory)
    %w[Chapter1.mp3 Chapter2.mp3].each { |name| FileUtils.cp(@audio_path, File.join(directory, name)) }
    @audiobook.update!(file_path: directory)
    visit consumer_publication_path(@audiobook)
    assert_selector "[data-consumer-reader-target=duration]", text: /0:0[89]/, wait: 15
    find("select[data-action='change->consumer-reader#changeSpeed']").select("1.5×")
    find("select[data-consumer-reader-target=tracks]").select("Chapter2.mp3")
    assert_selector "[data-consumer-reader-target=trackTitle]", text: "Chapter2.mp3"
    assert page.evaluate_script("document.querySelector('audio').playbackRate === 1.5 && document.querySelector('audio').defaultPlaybackRate === 1.5")
  end

  test "reading preferences survive reopening and text size refreshes the page count" do
    File.unlink(@epub_path)
    write_consumer_epub(@epub_path, chapter: "A good story keeps its place. " * 650)
    page.current_window.resize_to(390, 844)
    visit consumer_publication_path(@ebook)
    assert_selector ".consumer-ebook iframe", wait: 20
    wait_until("the initial reader page is ready") { reader_place&.dig(:inside) }
    reveal_reading_controls
    click_button "Next →"
    # Font reflow intentionally records no activity. Let this navigation save
    # before changing the layout, rather than racing its location report.
    wait_for_progress(@ebook)
    initial_total = find("[data-consumer-reader-target=location]").text[/\/ (\d+)/, 1].to_i
    3.times { find("button[aria-label='Larger text']").click }
    assert_selector "[data-consumer-reader-target=location]" do |node|
      node.text[/\/ (\d+)/, 1].to_i > initial_total
    end
    assert_selector ".consumer-ebook iframe" do
      page.evaluate_script("JSON.parse(localStorage.getItem('shelfarr.reader.preferences.v1')).fontSize === 135 && parseFloat(getComputedStyle(document.querySelector('.consumer-ebook iframe').contentDocument.querySelector('p')).fontSize) > 21")
    end
    enlarged = within_frame(find(".consumer-ebook iframe")) { page.evaluate_script("getComputedStyle(document.querySelector('p')).fontSize") }
    assert_text "Your place is saved", wait: 12
    click_link "← Your library"
    assert_current_path consumer_library_path
    click_link "The Quiet Library", match: :first
    assert_selector ".consumer-ebook iframe", wait: 20
    restored = within_frame(find(".consumer-ebook iframe")) { page.evaluate_script("getComputedStyle(document.querySelector('p')).fontSize") }
    assert_equal enlarged, restored
  end

  test "paused track changes stay paused and listening speed survives reopening" do
    directory = File.join(@root, "Audio chapters")
    FileUtils.mkdir_p(directory)
    %w[Chapter1.mp3 Chapter2.mp3].each { |name| FileUtils.cp(@audio_path, File.join(directory, name)) }
    @audiobook.update!(file_path: directory)
    visit consumer_publication_path(@audiobook)
    assert_selector "[data-consumer-reader-target=duration]", text: /0:0[89]/, wait: 15
    find("button[aria-label='Play audiobook']").click
    find("button[aria-label='Pause audiobook']").click
    find("select[data-consumer-reader-target=speed]").select("1.5×")
    find("select[data-consumer-reader-target=tracks]").select("Chapter2.mp3")
    assert_selector "[data-consumer-reader-target=trackTitle]", text: "Chapter2.mp3"
    assert page.evaluate_script("document.querySelector('audio').paused")
    click_link "← Your library"
    assert_current_path consumer_library_path
    visit consumer_publication_path(@audiobook)
    assert_selector "[data-consumer-reader-target=duration]", text: /0:0[89]/, wait: 15
    assert_equal "1.5", find("select[data-consumer-reader-target=speed]").value
    assert page.evaluate_script("document.querySelector('audio').playbackRate === 1.5")
  end

  test "reading status and sorted filters are usable and keep a saved place" do
    visit consumer_publication_path(@ebook)
    assert_selector ".consumer-ebook iframe", wait: 20
    reveal_reading_controls
    within(".consumer-reading-status") do
      select "Finished", from: "Reading status"
      click_button "Save status"
    end
    assert_text "Reading status saved. Your saved place is kept."
    visit consumer_library_path
    within(".consumer-library-options") do
      select "Finished", from: "Reading status"
      select "Title A–Z", from: "Sort by"
      click_button "Apply"
    end
    assert_selector ".consumer-book-card", count: 1
    assert_selector ".consumer-book-card", text: "The Quiet Library"
    assert_no_horizontal_overflow
    @ebook.update!(file_path: File.join(@root, "gone.epub"))
    visit consumer_publication_path(@ebook)
    assert_text "No readable files are available"
    assert_link "Check again", href: consumer_publication_path(@ebook)
    assert_link "Back to your library", href: consumer_library_path
    assert_no_link "Library item details"
  end

  test "touch reading stays quiet and desktop navigation stays visible without covering the book" do
    File.unlink(@epub_path)
    write_consumer_epub(@epub_path, chapter: "Quiet words fill the whole page. " * 700)
    [ [ 390, 844, "mobile" ], [ 1024, 768, "touch tablet" ], [ 1280, 900, "desktop" ] ].each do |width, height, name|
      page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: name != "desktop", maxTouchPoints: 5)
      page.current_window.resize_to(width, height)
      visit consumer_publication_path(@ebook)
      assert_selector ".consumer-ebook iframe", wait: 20
      within_frame(find(".consumer-ebook iframe")) { assert_text "Quiet words fill the whole page." }
      assert_no_selector ".consumer-header"
      assert_no_selector ".consumer-publication-heading"
      assert_no_selector ".consumer-reading-status"
      assert_no_selector "button", text: "Next →"
      assert_no_selector "[data-consumer-reader-target=chapters]"
      if name == "desktop"
        within("[data-consumer-reader-target=desktopNav]") do
          assert_link "← Your library"
          assert_select "Chapter", selected: "A beginning"
          assert_button "Reading controls"
        end
      else
        assert_no_selector "[data-consumer-reader-target=desktopNav]"
      end
      assert_no_text "The Quiet Library"
      frame = page.evaluate_script("(() => { const r = document.querySelector('.consumer-ebook-frame').getBoundingClientRect(); return [r.width, r.height, window.innerWidth, window.innerHeight] })()")
      assert_equal frame[2], frame[0]
      assert_equal frame[3] - (name == "desktop" ? 64 : 0), frame[1]
      assert page.evaluate_script("(() => { const nav = document.querySelector('[data-consumer-reader-target=desktopNav]'); const text = document.querySelector('.consumer-ebook iframe'); return getComputedStyle(nav).display === 'none' || nav.getBoundingClientRect().bottom <= text.getBoundingClientRect().top })()"), "desktop navigation must not cover any text"
      assert_no_horizontal_overflow
      capture("consumer-reading-#{name}.png")
      before = iframe_box
      reveal_reading_controls
      assert_equal page.evaluate_script("document.activeElement.textContent"), "Done"
      assert_selector "button", text: "Next →"
      assert_selector ".consumer-reader-title", text: "The Quiet Library"
      assert_equal before, iframe_box, "revealing controls must not reflow the book"
      assert_no_horizontal_overflow
      capture("consumer-reading-controls-#{name}.png")
      find("[data-consumer-reader-target=hide]").send_keys(:escape)
      assert_no_selector "button", text: "Next →"
      assert page.evaluate_script("document.activeElement.matches('[data-consumer-reader-target=viewport]')")
      assert_equal before, iframe_box
    end
  ensure
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false)
  end

  test "desktop chapter selection and Back work without discovering a hidden tap zone" do
    File.unlink(@epub_path)
    write_consumer_epub(@epub_path, chapter: "The first chapter stays quiet. " * 400, second_chapter: "Desktop chapter selection works. " * 400)
    Zip::File.open(@epub_path) do |zip|
      nav = zip.read("OEBPS/nav.xhtml").sub("</ol>", '<li><a href="two.xhtml">Another chapter</a></li></ol>')
      zip.get_output_stream("OEBPS/nav.xhtml") { |out| out.write(nav) }
    end
    page.current_window.resize_to(1280, 900)
    visit consumer_publication_path(@ebook)
    assert_selector ".consumer-ebook iframe", wait: 20
    assert_selector "[data-consumer-reader-target=desktopNav]"
    assert_empty users(:one).consumer_progresses, "showing the navigation is not reading"
    within("[data-consumer-reader-target=desktopNav]") do
      assert_select "Chapter", with_options: [ "A beginning", "Another chapter" ]
      select "Another chapter", from: "Chapter"
    end
    assert_selector "[data-consumer-reader-target=location]", text: "chapter 2", visible: :all, wait: 10
    within_frame(find(".consumer-ebook iframe")) { assert_text "Desktop chapter selection works." }
    assert_equal "OEBPS/two.xhtml", wait_for_progress(@ebook).locator["href"]
    before = iframe_box
    within("[data-consumer-reader-target=desktopNav]") { click_button "Reading controls" }
    assert_selector "[data-consumer-reader-target=controls]"
    assert_no_selector "[data-consumer-reader-target=desktopNav]"
    assert_equal before, iframe_box, "opening controls does not reflow the book"
    click_button "Done"
    assert_selector "[data-consumer-reader-target=desktopNav]"
    assert_equal before, iframe_box
    capture("consumer-desktop-visible-navigation.png")
    within("[data-consumer-reader-target=desktopNav]") { click_link "← Your library" }
    assert_current_path consumer_library_path
  end

  # Keys go wherever the browser has focus, as a person's keyboard does; no
  # element is focused or targeted first.
  test "keyboard turns an opened desktop book wherever focus is, once per press, leaving shortcuts and controls alone" do
    File.unlink(@epub_path)
    write_consumer_epub(@epub_path, chapter: "Keys turn these pages. " * 900)
    page.current_window.resize_to(1280, 900)
    visit consumer_publication_path(@ebook)
    assert_selector ".consumer-ebook iframe", wait: 20
    assert_selector "[data-consumer-reader-target=location]", text: %r{\A1 / \d+}, visible: :all, wait: 20
    wait_for_reader_layout
    assert page.evaluate_script("document.activeElement === document.body"), "a freshly opened page keeps focus on its body"
    assert_empty users(:one).consumer_progresses, "opening is not reading"

    # Nothing has been clicked: the body has focus.
    turned = Time.current
    press_key :arrow_right
    assert_reader_page 2
    progress = wait_until_saved_here
    assert_operator progress.locator.dig("locations", "progression"), :>, 0
    assert_in_delta turned.to_f, progress.observed_at.to_f, 5
    assert_operator progress.observed_at, :<=, progress.updated_at
    press_key :page_down
    assert_reader_page 3
    press_key :page_up
    assert_reader_page 2
    press_key :arrow_left
    assert_reader_page 1
    assert_equal 0, wait_until_saved_here.locator.dig("locations", "progression"), "turning back is saved too"

    # Browser and system shortcuts are not page turns. (Alt+Left is Back and
    # would leave the page, so only Alt+Right is pressed.) The next plain press
    # then moves exactly one page from where they left it.
    path = current_path
    [ [ :control, :arrow_right ], [ :control, :arrow_left ], [ :meta, :arrow_right ], [ :meta, :arrow_left ], [ :alt, :arrow_right ] ].each do |modifier, key|
      page.driver.browser.action.key_down(modifier).send_keys(key).key_up(modifier).perform
    end
    assert_equal path, current_path
    press_key :arrow_right
    assert_reader_page 2
    saved = wait_until_saved_here

    # Keys in the reader's own controls keep their native meaning.
    within("[data-consumer-reader-target=desktopNav]") { click_button "Reading controls" }
    assert_selector "[data-consumer-reader-target=controls]", visible: true
    tab_to "[data-consumer-reader-target=chapters]"
    press_key :arrow_right
    press_key :page_down
    tab_to "select[name=status]"
    press_key :arrow_right
    status = find("select[name=status]").value
    press_key :arrow_down
    wait_until("the status menu moves natively") { find("select[name=status]").value != status }
    wait_for_reader_layout
    assert_reader_page 2
    # Escape still closes the controls from a menu and returns focus to the
    # reading surface, where arrows turn again.
    press_key :escape
    assert_no_selector "[data-consumer-reader-target=controls]", visible: true
    assert page.evaluate_script("document.activeElement.matches('[data-consumer-reader-target=viewport]')")
    assert_equal saved.attributes.slice("version", "observed_at", "locator"), users(:one).consumer_progresses.find_by!(book: @ebook).attributes.slice("version", "observed_at", "locator"),
      "opening controls, moving focus and using menus are not reading"
    assert_equal 0, outbox_size
    press_key :arrow_right
    assert_reader_page 3

    # Inside the sandboxed book frame its own listener turns the page; the frame's
    # keys never reach the page as well, so each press is still one page.
    view = find("[data-consumer-reader-target=viewport]")
    view.click(x: (view.native.size.width * 0.35).to_i, y: 0)
    assert_reader_page 4
    assert page.evaluate_script("document.activeElement === document.querySelector('.consumer-ebook iframe')"), "clicking the text focuses the book frame"
    press_key :arrow_right
    assert_reader_page 5
    turned = Time.current
    press_key :arrow_left
    assert_reader_page 4
    progress = wait_until_saved_here
    assert_in_delta turned.to_f, progress.observed_at.to_f, 5
    assert_equal 0, outbox_size
  end

  test "taps turn pages at the sides, reveal controls in the middle, and the hidden reveal button is reachable" do
    File.unlink(@epub_path)
    write_consumer_epub(@epub_path, chapter: "Tap through the pages. " * 900)
    page.current_window.resize_to(390, 844)
    visit consumer_publication_path(@ebook)
    assert_selector ".consumer-ebook iframe", wait: 20
    assert_selector "[data-consumer-reader-target=location]", text: %r{\A1 / \d+}, visible: :all
    first_page = location_text
    tap_reader(0.85)
    assert_selector "[data-consumer-reader-target=location]", text: %r{\A2 / \d+}, visible: :all
    assert_no_selector "button", text: "Next →"
    assert_operator wait_for_progress(@ebook).locator.dig("locations", "progression"), :>, 0
    tap_reader(0.15)
    tap_reader(0.5)
    assert_selector "button", text: "Next →", wait: 3
    assert_equal first_page, location_text
    tap_reader(0.5)
    assert_no_selector "button", text: "Next →"
    reveal = find("[data-consumer-reader-target=reveal]", visible: :all)
    assert_equal "false", reveal["aria-expanded"]
    page.execute_script("arguments[0].focus()", reveal)
    assert_selector "[data-consumer-reader-target=reveal]", text: "Show reading controls"
    reveal.click
    assert_equal "true", reveal["aria-expanded"]
    assert_selector "button", text: "Next →"
  end

  test "an offline page turn is kept across a reload and synced with its original reading time" do
    File.unlink(@epub_path)
    write_consumer_epub(@epub_path, chapter: "Offline pages still count. " * 900)
    visit consumer_publication_path(@ebook)
    assert_selector ".consumer-ebook iframe", wait: 20
    # HTTP LAN browsers lack randomUUID, while retaining getRandomValues.
    page.execute_script("Object.defineProperty(crypto, 'randomUUID', { value: undefined, configurable: true })")
    go_offline
    find("[data-consumer-reader-target=viewport]").send_keys(:arrow_right)
    assert_selector "[data-consumer-reader-target=notice]", text: "Saved on this device. It will sync when you're back online.", wait: 12
    turned = Time.current
    assert_empty users(:one).consumer_progresses
    visit consumer_publication_path(@ebook)
    progress = wait_for_progress(@ebook)
    assert_operator progress.locator.dig("locations", "progression"), :>, 0
    assert_in_delta turned.to_f, progress.observed_at.to_f, 15
    assert_operator progress.updated_at, :>, progress.observed_at
    assert_equal 0, page.evaluate_script("Object.keys(localStorage).filter(key => key.startsWith('shelfarr.progress.v1')).length")
  end

  test "an older offline place does not overwrite a later place from another device" do
    File.unlink(@epub_path)
    write_consumer_epub(@epub_path, chapter: "Two devices, one story. " * 900)
    visit consumer_publication_path(@ebook)
    assert_selector ".consumer-ebook iframe", wait: 20
    go_offline
    find("[data-consumer-reader-target=viewport]").send_keys(:arrow_right)
    assert_selector "[data-consumer-reader-target=notice]", text: "Saved on this device", wait: 12
    later = { "href" => "OEBPS/chapter.xhtml", "locations" => { "progression" => 0.01 } }
    users(:one).consumer_progresses.create!(book: @ebook, asset_id: consumer_asset(@ebook).id, locator: later, version: 1,
      client_mutation_id: SecureRandom.uuid, observed_at: 1.minute.from_now)
    page.execute_script("window.fetch = window.realFetch; window.dispatchEvent(new Event('online'))")
    assert_selector "[data-consumer-reader-target=remote]", text: "Another device has a more recent place.", wait: 12
    assert_no_selector "[data-consumer-reader-target=notice]"
    assert_equal 0, page.evaluate_script("Object.keys(localStorage).filter(key => key.startsWith('shelfarr.progress.v1')).length")
    saved = users(:one).consumer_progresses.find_by!(book: @ebook)
    assert_equal [ 1, later ], [ saved.version, saved.locator ]
    assert_no_selector "[data-consumer-reader-target=conflict]"
  end

  test "a place deep in a long chapter reopens with its paragraph on screen, from the outbox and from the account" do
    File.unlink(@epub_path)
    coast = (1..60).map { |n| "Coastal note #{n}. The second chapter follows the tide past lantern #{n}. Each numbered observation identifies a different place along the shore." }
    write_consumer_epub(@epub_path, chapter: "Garden note 1. A short way in.", second_chapter: coast.join("</p><p>"))
    page.current_window.resize_to(1280, 800)
    page.execute_script("localStorage.setItem('shelfarr.reader.preferences.v1', JSON.stringify({ fontSize: 115 }))")
    visit consumer_publication_path(@ebook)
    assert_selector "[data-consumer-reader-target=location]", text: %r{\A1 / \d+ · chapter 1}, visible: :all, wait: 20
    turn_page_until { |page, total, chapter| chapter == 2 && page == total - 2 }
    total = location_text[%r{/ (\d+)}, 1].to_i
    assert_operator total, :>=, 6, "the chapter must span enough pages to expose a restored offset"
    earlier = reader_place[:start]
    wait_until("the earlier page is acknowledged") { saved_cfi == earlier && outbox_size.zero? }

    # The next page stays only in this browser's outbox.
    go_offline
    find("[data-consumer-reader-target=viewport]").send_keys(:arrow_right)
    assert_selector "[data-consumer-reader-target=notice]", text: "Saved on this device. It will sync when you're back online.", wait: 12
    turned = Time.current
    target = reader_place[:start]
    reached = reader_place(target)
    marker, offset = reached.values_at(:marker, :offset)
    assert reached[:inside], "the saved character was reached before closing"
    assert_match(/\ACoastal note \d+\z/, marker)
    assert_equal earlier, saved_cfi

    visit consumer_publication_path(@ebook)
    assert_place_on_screen(target, marker, "#{total - 1} / #{total} · chapter 2", offset: offset)
    wait_until("the outbox place is acknowledged") { saved_cfi == target && outbox_size.zero? }
    saved = users(:one).consumer_progresses.find_by!(book: @ebook)
    assert_in_delta turned.to_f, saved.observed_at.to_f, 15
    assert_place_on_screen(target, marker, "#{total - 1} / #{total} · chapter 2", offset: offset)

    # Reopening an acknowledged place is not a new checkpoint.
    visit consumer_publication_path(@ebook)
    assert_place_on_screen(target, marker, "#{total - 1} / #{total} · chapter 2", offset: offset)
    after = users(:one).consumer_progresses.find_by!(book: @ebook)
    assert_equal saved.attributes.slice("version", "observed_at", "updated_at", "client_mutation_id", "locator"),
      after.attributes.slice("version", "observed_at", "updated_at", "client_mutation_id", "locator")
    assert_equal 0, outbox_size

    # After genuine reading, layout changes must not be mistaken for another
    # page turn, including the engine's intermediate, incorrectly clamped page.
    find("[data-consumer-reader-target=viewport]").send_keys(:arrow_left)
    wait_until("the backward turn is saved") { saved_cfi != target && outbox_size.zero? }
    target = saved_cfi
    assert reader_place(target)[:inside]
    saved = users(:one).consumer_progresses.find_by!(book: @ebook)
    page.execute_script(<<~JS)
      window.layoutProgressWrites = []
      const layoutFetch = window.fetch
      window.fetch = (url, options) => {
        if (String(url).includes("/progress") && options?.method === "PUT") window.layoutProgressWrites.push(options.body)
        return layoutFetch(url, options)
      }
    JS
    before_resize = location_text
    page.current_window.resize_to(900, 700)
    wait_until("the resized page contains the saved text") { location_text != before_resize && reader_place(target)&.dig(:inside) }
    wait_for_reader_layout
    assert reader_place(target)[:inside]
    assert_silent_layout(saved)

    reveal_reading_controls
    find("button[aria-label='Larger text']").click
    wait_for_reader_layout
    assert reader_place(target)[:inside], "the saved text stays visible at the new text size"
    assert_silent_layout(saved)
    find("button[aria-label='Smaller text']").click
    wait_for_reader_layout
    assert reader_place(target)[:inside]
    assert_silent_layout(saved)

    # Each layout starts its page before the saved text. Several in a row (a
    # phone turned both ways, with a text size change between) must keep the
    # saved place itself, not the start of the page the last layout produced.
    find("[data-consumer-reader-target=hide]").click
    { [ 390, 844 ] => "Larger text", [ 844, 390 ] => "Smaller text" }.each do |(width, height), button|
      before_turn = location_text
      page.current_window.resize_to(width, height)
      wait_until("the #{width}px page contains the saved text") { location_text != before_turn && reader_place(target)&.dig(:inside) }
      wait_for_reader_layout
      assert reader_place(target)[:inside], "the saved text stays visible at #{width}x#{height}"
      assert_silent_layout(saved)
      reveal_reading_controls
      find("button[aria-label='#{button}']").click
      wait_for_reader_layout
      find("[data-consumer-reader-target=hide]").click
      assert reader_place(target)[:inside], "the saved text stays visible after #{button} at #{width}x#{height}"
      assert_silent_layout(saved)
      capture("consumer-reading-reflowed-#{width}x#{height}.png")
    end

    # Suppression ends with the next deliberate turn.
    find("[data-consumer-reader-target=viewport]").send_keys(:arrow_right)
    assert_operator wait_for_progress(@ebook, version: saved.version + 1).version, :>, saved.version
  end

  test "resuming a saved listening place rewinds five seconds without replacing the saved place" do
    observed = 2.minutes.ago.utc.floor(3)
    users(:one).consumer_progresses.create!(book: @audiobook, asset_id: consumer_asset(@audiobook).id, position_seconds: 7,
      version: 1, client_mutation_id: SecureRandom.uuid, observed_at: observed)
    visit consumer_publication_path(@audiobook)
    assert_selector "[data-consumer-reader-target=elapsed]", text: "0:07", wait: 15
    find("button[aria-label='Play audiobook']").click
    assert_selector "button[aria-label='Pause audiobook']"
    assert_operator page.evaluate_script("document.querySelector('audio').currentTime"), :<, 4
    find("button[aria-label='Pause audiobook']").click
    sleep 1
    saved = users(:one).consumer_progresses.find_by!(book: @audiobook)
    assert_equal [ 1, 7.0, observed ], [ saved.version, saved.position_seconds, saved.observed_at ]
    # Pausing again inside the replay must not subtract another five seconds.
    replay = page.evaluate_script("document.querySelector('audio').currentTime")
    find("button[aria-label='Play audiobook']").click
    assert_in_delta replay, page.evaluate_script("document.querySelector('audio').currentTime"), 0.6
    find("button[aria-label='Pause audiobook']").click
    assert_equal [ 1, 7.0, observed ], [ saved.reload.version, saved.position_seconds, saved.observed_at ]
    # A deliberate seek while paused is saved and the next play starts there.
    page.execute_script("const seek = document.querySelector('#consumer-seek'); seek.value = 25; seek.dispatchEvent(new Event('input')); seek.dispatchEvent(new Event('change'))")
    assert_operator wait_for_progress(@audiobook, version: 2).observed_at, :>, observed
    position = page.evaluate_script("document.querySelector('audio').currentTime")
    find("button[aria-label='Play audiobook']").click
    assert_in_delta position, page.evaluate_script("document.querySelector('audio').currentTime"), 0.6
  end

  private

  def wait_for_progress(book, version: 1, timeout: 15)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      progress = users(:one).consumer_progresses.find_by(book: book)
      return progress if progress && progress.version >= version
      flunk "No saved progress (version #{version}) for #{book.title}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.2
    end
  end

  def wait_until(what, timeout: 15, detail: nil)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "Timed out waiting until #{what}#{detail&.call}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.1
    end
  end

  def turn_page_until(limit: 40)
    limit.times do
      page_number, total, chapter = location_text.scan(/\d+/).map(&:to_i)
      return if yield(page_number, total, chapter)

      before = location_text
      find("[data-consumer-reader-target=viewport]").send_keys(:arrow_right)
      wait_until("the page turns") { location_text != before }
    end
    flunk "Never reached the requested page (at #{location_text})"
  end

  # A key press delivered to whatever has focus, like a physical keyboard.
  def press_key(key)
    page.driver.browser.action.send_keys(key).perform
  end

  # Moves focus with Tab, as a keyboard user does, until the control has it.
  def tab_to(selector, limit: 30)
    limit.times do
      return if page.evaluate_script("document.activeElement.matches(arguments[0])", selector)

      press_key :tab
    end
    flunk "Tab never reached #{selector}"
  end

  # The page shown once every queued turn and layout has run, so a press that
  # turned twice cannot pass as one turn.
  def assert_reader_page(number)
    assert_selector "[data-consumer-reader-target=location]", text: %r{\A#{number} / \d+}, visible: :all, wait: 10
    wait_for_reader_layout
    assert_match %r{\A#{number} / \d+}, location_text
  end

  def current_reader_cfi
    page.evaluate_script(<<~JS)
      (() => {
        const element = document.querySelector("[data-controller~='consumer-reader']")
        return window.Stimulus.getControllerForElementAndIdentifier(element, "consumer-reader").rendition.currentLocation()?.start?.cfi
      })()
    JS
  end

  # The account holds exactly the place on screen.
  def wait_until_saved_here
    cfi = current_reader_cfi
    wait_until("the account has the place on screen", detail: -> { "; saved #{saved_cfi.inspect}, shown #{cfi.inspect}" }) { saved_cfi == cfi }
    users(:one).consumer_progresses.find_by!(book: @ebook)
  end

  # Where a CFI's actual Range is drawn, not just which CFI the reader reports.
  def reader_place(cfi = nil)
    page.evaluate_script(<<~JS, cfi)&.symbolize_keys
      (() => {
        const element = document.querySelector("[data-controller~='consumer-reader']")
        const reader = window.Stimulus.getControllerForElementAndIdentifier(element, "consumer-reader")
        if (!reader?.readerReady) return null
        const start = reader.rendition.currentLocation()?.start?.cfi
        const range = reader.rendition.getRange(arguments[0] || start)
        if (!range) return null
        const frame = document.querySelector(".consumer-ebook iframe").getBoundingClientRect()
        const view = document.querySelector("[data-consumer-reader-target=viewport]").getBoundingClientRect()
        const within = rect => frame.left + rect.left >= view.left && frame.left + rect.right <= view.right &&
          frame.top + rect.top >= view.top && frame.top + rect.top < view.bottom
        // At a column boundary Firefox places a collapsed caret at the prior
        // line's end. Measure the next actual character, preserving the CFI.
        const measured = range.cloneRange()
        if (measured.collapsed && measured.startContainer.nodeType === Node.TEXT_NODE && measured.startOffset < measured.startContainer.length)
          measured.setEnd(measured.startContainer, measured.startOffset + 1)
        // Firefox may split a paragraph between columns; its visible fragment
        // need not be the first one, and the saved offset need not be zero.
        const paragraph = range.startContainer.parentElement.closest("p")
        return { start, marker: paragraph?.textContent.match(/Coastal note \\d+/)?.[0], offset: range.startOffset,
          inside: within(measured.getBoundingClientRect()), paragraphInside: !!paragraph && Array.from(paragraph.getClientRects()).some(within) }
      })()
    JS
  end

  def assert_place_on_screen(cfi, marker, label, offset:)
    place = nil
    wait_until("#{marker} is on screen at #{label}", timeout: 20, detail: -> { "; the reader shows #{location_text.inspect} with #{place.inspect}" }) do
      (place = reader_place(cfi)) && place[:inside] && location_text == label
    end
    assert_equal({ marker: marker, offset: offset, inside: true, paragraphInside: true }, place.slice(:marker, :offset, :inside, :paragraphInside))
  end

  def wait_for_reader_layout
    # EPUB.js queues reportLocation's RAF without awaiting it. Drain its queue
    # and that report before inspecting saved state; no fixed layout delay.
    page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1]
      const element = document.querySelector("[data-controller~='consumer-reader']")
      const reader = window.Stimulus.getControllerForElementAndIdentifier(element, "consumer-reader")
      Promise.resolve(reader.readerReflow || reader.fontReflow).then(() => reader.rendition.q.run())
        .then(() => requestAnimationFrame(() => done(true)))
        .catch(error => done(String(error)))
    JS
  end

  def assert_silent_layout(saved)
    assert_equal [], page.evaluate_script("window.layoutProgressWrites"), "layout must not upload a reading checkpoint"
    assert_equal 0, outbox_size
    assert_equal saved.attributes.slice("version", "observed_at", "updated_at", "client_mutation_id", "locator"),
      users(:one).consumer_progresses.find_by!(book: @ebook).attributes.slice("version", "observed_at", "updated_at", "client_mutation_id", "locator")
  end

  def saved_cfi
    users(:one).consumer_progresses.find_by(book: @ebook)&.locator&.dig("locations", "cfi")
  end

  def outbox_size
    page.evaluate_script("Object.keys(localStorage).filter(key => key.startsWith('shelfarr.progress.v1')).length")
  end

  def reveal_reading_controls
    find("[data-consumer-reader-target=viewport]").send_keys(:escape)
    assert_selector "[data-consumer-reader-target=controls]", visible: true
  end

  def iframe_box
    page.evaluate_script("(() => { const r = document.querySelector('.consumer-ebook iframe').getBoundingClientRect(); return [r.top, r.height, r.width] })()")
  end

  def location_text
    find("[data-consumer-reader-target=location]", visible: :all).text(:all)
  end

  # Click inside the sandboxed book frame at a fraction of the reading width.
  def tap_reader(fraction)
    page.execute_script(<<~JS, fraction)
      const viewport = document.querySelector("[data-consumer-reader-target=viewport]").getBoundingClientRect()
      const frame = document.querySelector(".consumer-ebook iframe")
      const box = frame.getBoundingClientRect()
      const x = viewport.left + viewport.width * arguments[0] - box.left
      const y = viewport.top + viewport.height / 2 - box.top
      const target = frame.contentDocument.elementFromPoint(x, y) || frame.contentDocument.body
      target.dispatchEvent(new MouseEvent("click", { bubbles: true, clientX: x, clientY: y }))
    JS
    sleep 0.4
  end

  # Progress writes fail like a dropped connection; everything else still loads.
  def go_offline
    page.execute_script(<<~JS)
      window.realFetch = window.fetch
      window.fetch = (url, options) => String(url).includes("/progress") ? Promise.reject(new TypeError("Failed to fetch")) : window.realFetch(url, options)
    JS
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
