# frozen_string_literal: true

require "application_system_test_case"
require_relative "../test_helpers/consumer_test_helper"
require_relative "../test_helpers/fixed_layout_fixtures"
require_relative "../support/consumer_reachability"

# PDF and CBZ reading in a real browser, under a deployment subpath, with
# generated files. "Offline" closes the server's connections, so the service
# worker and the offline shell meet genuine network errors.
class ConsumerPagesTest < ApplicationSystemTestCase
  include ConsumerTestHelper
  include FixedLayoutFixtures

  BASE = "/shelf"
  APP = Rack::URLMap.new(BASE => ConsumerReachability.new(Rails.application))

  setup do
    ConsumerReachability.reset!
    @previous_app = Capybara.app
    @previous_root = ActionController::Base.relative_url_root
    Capybara.app = APP
    ActionController::Base.relative_url_root = BASE
    Rails.application.importmap.send(:clear_cache)
    page.current_window.resize_to(390, 844)
    prepare_consumer_library
    @pdf_path = File.join(@root, "Field Notes.pdf")
    File.binwrite(@pdf_path, fixed_layout_pdf(pages: 5, label: "Field page"))
    @pdf = Book.create!(title: "Field Notes", author: "A. Surveyor", book_type: :ebook, file_path: @pdf_path)
    @comic_path = File.join(@root, "Night Market.cbz")
    File.binwrite(@comic_path, fixed_layout_zip(comic_pages(6)))
    @comic = Book.create!(title: "Night Market", author: "An Artist", book_type: :comicbook, file_path: @comic_path)
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

  test "a PDF opens on real pages that turn, zoom, refit and restore without inventing activity" do
    visit at(consumer_publication_path(@pdf))
    wait_for_page(1)
    assert_no_selector ".consumer-header", visible: true
    assert_no_selector "[data-consumer-reader-target=controls]", visible: true
    assert page_painted?, "the PDF page canvas has drawn content"
    assert_includes text_layer, "Field page 1"
    assert_empty users(:one).consumer_progresses, "opening is not reading activity"
    assert_no_horizontal_overflow
    capture("pdf-page-mobile.png")

    tap_page(0.9)
    wait_for_page(2)
    progress = wait_for_progress(@pdf)
    assert_equal({ "href" => "document.pdf", "type" => "application/pdf",
      "locations" => { "position" => 2, "totalProgression" => 0.2, "fragments" => [ "page=2" ] } }, progress.locator)
    assert_operator progress.observed_at, :<=, progress.updated_at

    # The text layer is selectable, and selecting text is not a page turn.
    selected = page.evaluate_script(<<~JS)
      (() => { const span = [...document.querySelectorAll('.textLayer span')].find(node => node.textContent.includes('Selectable'))
        const range = document.createRange(); range.selectNodeContents(span); const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range); return String(selection) })()
    JS
    assert_includes selected, "Selectable words on page 2"
    # The click that ends a text selection does not turn the page.
    page.execute_script("const stage = document.querySelector('.consumer-pages__stage'); const box = stage.getBoundingClientRect(); stage.dispatchEvent(new MouseEvent('click', { bubbles: true, clientX: box.left + box.width * 0.9, clientY: box.top + box.height / 2 }))")
    sleep 0.4
    assert_equal "2", find(".consumer-pages")["data-page"]
    page.execute_script("getSelection().removeAllRanges()")

    find(".consumer-pages").send_keys("+")
    wait_until("the page zooms") { find(".consumer-pages")["data-zoom"].to_f > 1.4 }
    assert_selector ".consumer-pages.is-zoomed"
    assert page.evaluate_script("(() => { const s = document.querySelector('.consumer-pages__stage'); return s.scrollWidth > s.clientWidth })()"), "a zoomed page pans"
    capture("pdf-zoomed-mobile.png")
    find(".consumer-pages").send_keys("0")
    wait_until("the page fits again") { find(".consumer-pages")["data-zoom"] == "1.00" }
    # Two fingers spreading apart zoom in.
    page.execute_script(<<~JS)
      const stage = document.querySelector('.consumer-pages__stage'); const box = stage.getBoundingClientRect(); const x = box.left + box.width / 2, y = box.top + box.height / 2
      const touch = (type, pointerId, clientX) => stage.dispatchEvent(new PointerEvent(type, { pointerId, pointerType: 'touch', isPrimary: pointerId === 1, clientX, clientY: y, bubbles: true }))
      touch('pointerdown', 1, x - 30); touch('pointerdown', 2, x + 30); touch('pointermove', 1, x - 70); touch('pointermove', 2, x + 70); touch('pointerup', 1, x - 70); touch('pointerup', 2, x + 70)
    JS
    wait_until("the pinch zooms in") { find(".consumer-pages")["data-zoom"].to_f > 2 }
    assert_equal "2", find(".consumer-pages")["data-page"], "a pinch never turns the page"
    find(".consumer-pages").send_keys("0")
    wait_until("the page fits again") { find(".consumer-pages")["data-zoom"] == "1.00" }
    page.current_window.resize_to(844, 390)
    wait_until("the page refits in landscape") { page.evaluate_script("document.querySelector('.consumer-page').getBoundingClientRect().height") < 390 }
    assert_equal "2", find(".consumer-pages")["data-page"]
    capture("pdf-landscape.png")
    page.current_window.resize_to(390, 844)
    sleep 0.5
    assert_equal 1, users(:one).consumer_progresses.find_by!(book: @pdf).version, "zooming and rotating are not reading activity"

    visit at(consumer_publication_path(@pdf))
    wait_for_page(2)
    assert_includes text_layer, "Field page 2"
    find(".consumer-pages").send_keys(:escape)
    assert_selector "[data-consumer-reader-target=controls]", visible: true
    assert_selector "[data-consumer-reader-target=location]", text: "Page 2 of 5"
    assert_no_selector "[data-consumer-reader-target=textTools]", visible: true
    assert_no_selector "[data-consumer-reader-target=editionPicker]", visible: true
    assert_no_horizontal_overflow
    capture("pdf-controls-mobile.png")
    fill_in "Page", with: "5"
    find("[data-consumer-reader-target=pageNumber]").send_keys(:enter)
    wait_for_page(5)
    assert_equal 5, wait_for_progress(@pdf, version: 2).locator.dig("locations", "position")
    assert_equal 2, users(:one).consumer_progresses.find_by!(book: @pdf).version

    # A saved page beyond this PDF is shown clamped, and is kept until a real turn.
    users(:one).consumer_progresses.find_by!(book: @pdf).update!(locator: { "href" => "document.pdf", "type" => "application/pdf", "locations" => { "position" => 40 } })
    visit at(consumer_publication_path(@pdf))
    wait_for_page(5)
    assert_selector "[data-consumer-reader-target=notice]", text: "Your saved page isn't in this file any more; showing page 5", wait: 10
    sleep 0.5
    assert_equal 40, users(:one).consumer_progresses.find_by!(book: @pdf).locator.dig("locations", "position")
  end

  test "a CBZ comic shows verified page images in order and saves the exact page" do
    visit at(consumer_library_path(type: "ebook"))
    assert_selector "a[data-offline-publication='#{@comic.id}'] .consumer-format", text: "Comic"
    click_link "Night Market", match: :first
    wait_for_page(1)
    assert_equal fixed_layout_page_color(1), image_pixel
    assert_equal "Page 1 of 6", find(".consumer-page img")["alt"]
    assert_empty users(:one).consumer_progresses
    assert_no_horizontal_overflow
    capture("comic-page-mobile.png")
    find(".consumer-pages").send_keys(:arrow_right)
    wait_for_page(2)
    assert_equal fixed_layout_page_color(2), image_pixel
    progress = wait_for_progress(@comic)
    assert_equal "pages/002.png", progress.locator.fetch("href")
    assert_equal "image/png", progress.locator.fetch("type")
    assert_equal 2, progress.locator.dig("locations", "position")
    swipe_page(-160)
    wait_for_page(3)
    assert_equal fixed_layout_page_color(3), image_pixel
    wait_for_progress(@comic, version: 2)
    tap_page(0.1)
    wait_for_page(2)
    tap_page(0.5)
    assert_selector "[data-consumer-reader-target=controls]", visible: true
    capture("comic-controls-mobile.png")
    find("[data-consumer-reader-target=pageSlider]").set(6)
    wait_for_page(6)
    assert_equal fixed_layout_page_color(6), image_pixel
    # The outbox may coalesce quick moves into one write; the latest page wins.
    saved = wait_until("page 6 is saved") { users(:one).consumer_progresses.find_by(book: @comic)&.then { |row| row if row.locator["href"] == "pages/006.png" } }
    assert_equal 6, saved.locator.dig("locations", "position")
    assert_no_horizontal_overflow

    visit at(consumer_publication_path(@comic))
    wait_for_page(6)
    sleep 0.5
    assert_equal saved.version, users(:one).consumer_progresses.find_by!(book: @comic).version, "restoring is not reading activity"
  end

  test "a damaged comic page is refused with an honest message instead of being shown" do
    pages = comic_pages(3)
    bytes = fixed_layout_zip(pages)
    # Corrupt page 2's compressed data; the directory and headers still agree.
    second = bytes.index("pages/002.png") + "pages/002.png".bytesize + 8
    bytes.setbyte(second, bytes.getbyte(second) ^ 0xff)
    File.binwrite(@comic_path, bytes)
    asset = Consumer::LibraryAssets.new(@comic, formats: Consumer::ReaderFormats::SUPPORTED).list.sole
    saved = users(:one).consumer_progresses.create!(book: @comic, asset_id: asset.id, version: 1,
      client_mutation_id: SecureRandom.uuid, observed_at: 1.hour.ago,
      locator: { "href" => "pages/001.png", "type" => "image/png", "locations" => { "position" => 1 } })
    saved_attributes = saved.attributes.slice("locator", "version", "observed_at", "client_mutation_id")
    visit at(consumer_publication_path(@comic))
    wait_for_page(1)
    find(".consumer-pages").send_keys(:arrow_right)
    assert_selector "[data-consumer-reader-target=error]", text: /damaged|checksum/, wait: 10
    assert_selector ".consumer-page__unavailable", text: "Page 2 couldn't be shown."
    assert_no_selector ".consumer-page img", visible: :all
    capture("comic-damaged-page-mobile.png")
    visit at(consumer_publication_path(@comic))
    wait_for_page(1)
    assert_equal fixed_layout_page_color(1), image_pixel
    assert_equal saved_attributes, saved.reload.attributes.slice(*saved_attributes.keys), "the unseen page must not replace the saved place or time"
    find(".consumer-pages").send_keys(:arrow_right)
    assert_selector ".consumer-page__unavailable", text: "Page 2 couldn't be shown."
    find(".consumer-pages").send_keys(:arrow_right)
    wait_for_page(3)
    assert_equal fixed_layout_page_color(3), image_pixel
    assert_equal 3, wait_for_progress(@comic, version: 2).locator.dig("locations", "position")
    assert_no_selector "[data-consumer-reader-target=error]", visible: true
  end

  test "several formats of one book choose by saved place and never cross-apply it" do
    folder = File.join(@root, "Two Formats")
    FileUtils.mkdir_p(folder)
    write_consumer_epub(File.join(folder, "Two Formats.epub"), chapter: "Text for the reflowable edition. " * 300)
    File.binwrite(File.join(folder, "Two Formats.pdf"), fixed_layout_pdf(pages: 4, label: "Printed page"))
    book = Book.create!(title: "Two Formats", author: "A. Reader", book_type: :ebook, file_path: folder)
    epub = Consumer::LibraryAssets.new(book).list.sole
    users(:one).consumer_progresses.create!(book: book, asset_id: epub.id, version: 1, client_mutation_id: SecureRandom.uuid,
      locator: { "href" => "OEBPS/chapter.xhtml", "type" => "application/xhtml+xml", "locations" => { "progression" => 0.2 } })

    visit at(consumer_publication_path(book))
    assert_selector ".consumer-ebook iframe", wait: 20
    assert_no_selector ".consumer-pages", visible: true
    find("[data-consumer-reader-target=viewport]").send_keys(:escape)
    picker = find("[data-consumer-reader-target=edition]")
    assert_equal [ "EPUB · Two Formats.epub · your place", "PDF · Two Formats.pdf" ], picker.all("option").map(&:text)
    picker.select("PDF · Two Formats.pdf")
    wait_for_page(1)
    assert_selector "[data-consumer-reader-target=editionNote]", text: "Your saved place is in the EPUB. This PDF opens at its beginning"
    assert_selector "[data-consumer-reader-target=pageTools]", visible: true
    assert_no_selector "[data-consumer-reader-target=textTools]", visible: true
    assert_no_horizontal_overflow
    capture("mixed-formats-choice-mobile.png")
    sleep 0.5
    assert_equal epub.id, users(:one).consumer_progresses.find_by!(book: book).asset_id, "choosing a format is not reading activity"
    find("[data-consumer-reader-target=hide]").click
    find(".consumer-pages").send_keys(:arrow_right)
    wait_for_page(2)
    progress = wait_for_progress(book, version: 2)
    assert_equal "document.pdf", progress.locator.fetch("href")
    assert_not_equal epub.id, progress.asset_id

    visit at(consumer_publication_path(book))
    wait_for_page(2)
    assert_includes text_layer, "Printed page 2"
  end

  test "a downloaded comic and PDF reopen offline, turn pages, and sync when reconnected" do
    visit at(consumer_publication_path(@comic))
    wait_for_page(1)
    download_from_controls
    entries = media_entries
    assert(entries.any? { |url| url.end_with?("/reading_order") }, "the comic's reading order is stored with its bytes")
    capture("comic-download-ready-mobile.png")
    visit at(consumer_publication_path(@pdf))
    wait_for_page(1)
    download_from_controls

    ConsumerReachability.offline = true
    visit at(consumer_publication_path(@comic))
    assert_selector ".consumer-preview", text: "Offline", visible: :all, wait: 15
    wait_for_page(1)
    assert_equal fixed_layout_page_color(1), image_pixel
    find(".consumer-pages").send_keys(:arrow_right)
    wait_for_page(2)
    assert_equal fixed_layout_page_color(2), image_pixel
    turned = Time.current
    assert_selector "[data-consumer-reader-target=notice]", text: "Saved on this device. It will sync when you're back online.", wait: 12
    capture("comic-offline-mobile.png")
    visit at(consumer_publication_path(@pdf))
    wait_for_page(1)
    assert page_painted?, "the offline PDF renders with its cached worker and fonts"
    assert_includes text_layer, "Field page 1"
    find(".consumer-pages").send_keys(:arrow_right)
    wait_for_page(2)
    capture("pdf-offline-mobile.png")
    assert_empty users(:one).consumer_progresses

    ConsumerReachability.offline = false
    page.execute_script("window.dispatchEvent(new Event('online'))")
    pdf_progress = wait_for_progress(@pdf)
    assert_equal 2, pdf_progress.locator.dig("locations", "position")
    visit at(consumer_publication_path(@comic))
    comic_progress = wait_for_progress(@comic)
    assert_equal "pages/002.png", comic_progress.locator.fetch("href")
    assert_in_delta turned.to_f, comic_progress.observed_at.to_f, 15
    wait_for_page(2)
  end

  test "an evicted reading order or a replaced comic is never shown as ready" do
    visit at(consumer_publication_path(@comic))
    wait_for_page(1)
    download_from_controls
    # The browser evicts the page list but keeps the bytes.
    page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1]
      caches.keys().then(async names => {
        for (const name of names.filter(name => name.startsWith("shelfarr-offline-media"))) {
          const cache = await caches.open(name)
          for (const request of await cache.keys()) if (request.url.endsWith("/reading_order")) await cache.delete(request)
        }
        done(true)
      })
    JS
    ConsumerReachability.offline = true
    visit at(consumer_publication_path(@comic))
    assert_text "This book isn't available on this device.", wait: 15
    ConsumerReachability.offline = false

    visit at(consumer_publication_path(@comic))
    wait_for_page(1)
    reveal_controls
    within(".consumer-offline") do
      assert_text "Download stopped", wait: 10
      assert_text "The browser removed part of this download."
      click_button "Try again"
      assert_text "Available offline", wait: 20
    end
    old = media_entries
    assert_equal 2, old.size

    # A new edition: the old download stays usable until the update completes.
    File.rename(@comic_path, "#{@comic_path}.old")
    File.binwrite(@comic_path, fixed_layout_zip(comic_pages(4)))
    visit at(consumer_publication_path(@comic))
    wait_for_page(1)
    reveal_controls
    within(".consumer-offline") do
      assert_text "Available offline · an older edition", wait: 10
      click_button "Update"
      assert_text "Available offline · 1.2 KB", wait: 20
    end
    current = media_entries
    assert_equal 2, current.size
    assert_empty current & old, "the replaced edition's bytes and page list are removed"
    capture("comic-updated-mobile.png")

    # Another account never opens these downloads.
    page.driver.browser.manage.delete_all_cookies
    sign_in(users(:two), clear: false)
    visit at(consumer_library_path)
    assert_text "Your library."
    ConsumerReachability.offline = true
    visit at(consumer_publication_path(@comic))
    assert_text "This book isn't available on this device.", wait: 15
    assert_no_selector ".consumer-page img"
  end

  private

  def at(path) = "#{BASE}#{path}"

  def sign_in(user, clear: true)
    session = user.sessions.create!
    signed = ActionDispatch::TestRequest.create.cookie_jar.tap { |jar| jar.signed[:session_id] = session.id }[:session_id]
    clear_browser_offline_state if clear
    # A page without scripts: nothing opens offline storage before the test does.
    visit at("/up")
    page.driver.browser.manage.add_cookie(name: "session_id", value: signed, path: "/")
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

  def reveal_controls
    find(".consumer-pages").send_keys(:escape)
    assert_selector "[data-consumer-reader-target=controls]", visible: true
  end

  def download_from_controls
    reveal_controls
    within(".consumer-offline") do
      assert_text "Read without a connection"
      click_button "Download"
      assert_text "Available offline", wait: 30
    end
    find("[data-consumer-reader-target=hide]").click
  end

  def wait_for_page(position, timeout: 20)
    wait_until("page #{position} is shown", timeout: timeout) do
      element = page.first(".consumer-pages", minimum: 0, visible: true)
      element && element["data-page"] == position.to_s && page.evaluate_script("!!document.querySelector('.consumer-page canvas, .consumer-page img')")
    end
  end

  def page_painted?
    page.evaluate_script(<<~JS)
      (() => { const canvas = document.querySelector('.consumer-page canvas'); if (!canvas) return false
        const data = canvas.getContext('2d').getImageData(0, 0, canvas.width, canvas.height).data
        const colors = new Set(); for (let i = 0; i < data.length; i += 4 * 97) colors.add(data[i] + ',' + data[i + 1] + ',' + data[i + 2])
        return colors.size > 2 })()
    JS
  end

  def text_layer = page.evaluate_script("document.querySelector('.textLayer')?.textContent || ''")

  # The colour at a point between the page's first and second bars.
  def image_pixel
    page.evaluate_script(<<~JS)
      (() => { const image = document.querySelector('.consumer-page img'); const canvas = document.createElement('canvas')
        canvas.width = image.naturalWidth; canvas.height = image.naturalHeight; const context = canvas.getContext('2d'); context.drawImage(image, 0, 0)
        return [...context.getImageData(2, Math.floor(image.naturalHeight / 2), 1, 1).data.slice(0, 3)] })()
    JS
  end

  def tap_page(fraction)
    stage = find(".consumer-pages__stage")
    width = page.evaluate_script("document.querySelector('.consumer-pages__stage').clientWidth")
    stage.click(x: (width * fraction).round - (width / 2), y: 0)
  end

  def swipe_page(distance)
    page.execute_script(<<~JS, distance)
      const stage = document.querySelector('.consumer-pages__stage'); const box = stage.getBoundingClientRect(); const y = box.top + box.height / 2; const x = box.left + box.width / 2
      const event = (type, clientX) => stage.dispatchEvent(new PointerEvent(type, { pointerId: 7, pointerType: 'touch', clientX, clientY: y, bubbles: true }))
      event('pointerdown', x); event('pointermove', x + arguments[0] / 2); event('pointerup', x + arguments[0])
    JS
  end

  def wait_for_progress(book, version: 1, timeout: 20)
    wait_until("saved progress version #{version} for #{book.title}", timeout: timeout) do
      progress = users(:one).consumer_progresses.find_by(book: book)
      progress if progress && progress.version >= version
    end
  end

  def wait_until(what, timeout: 15)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      result = yield
      return result if result
      flunk "Timed out waiting until #{what}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.2
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
