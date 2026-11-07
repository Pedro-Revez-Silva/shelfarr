# frozen_string_literal: true

require "application_system_test_case"
require_relative "../test_helpers/consumer_test_helper"

class ConsumerReaderTest < ApplicationSystemTestCase
  include ConsumerTestHelper

  setup do
    prepare_consumer_library
    FileUtils.cp(Rails.root.join("test/fixtures/files/consumer_sample.mp3"), @audio_path)
    sign_in_as(users(:one))
  end
  teardown { FileUtils.remove_entry(@root) }

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
