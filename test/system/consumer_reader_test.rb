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
    click_button "Next →"
    assert_text "Your place is saved", wait: 12
    progress = users(:one).consumer_progresses.find_by!(book: @ebook)
    assert_equal "OEBPS/chapter.xhtml", progress.locator.fetch("href")
    assert_operator progress.locator.fetch("locations").fetch("progression"), :>, 0
    assert_no_horizontal_overflow
    capture("consumer-ebook-mobile.png")
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
    within_frame(find(".consumer-ebook iframe")) { assert_text "The next part of the story." }
    assert_text "Your place is saved", wait: 12
    version = users(:one).consumer_progresses.find_by!(book: @ebook).version
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
    click_button "Next →"
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

  private

  def assert_no_horizontal_overflow
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")
  end

  def capture(filename)
    return unless ENV["CONSUMER_SCREENSHOT_DIR"].present?

    FileUtils.mkdir_p(ENV.fetch("CONSUMER_SCREENSHOT_DIR"))
    page.save_screenshot(File.join(ENV.fetch("CONSUMER_SCREENSHOT_DIR"), filename))
  end
end
