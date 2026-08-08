# frozen_string_literal: true

require "application_system_test_case"

class SearchStreamingTest < ApplicationSystemTestCase
  test "stale stream chunks cannot render after the query or content kind changes" do
    sign_in_as(users(:one))
    visit search_path
    install_streaming_search_stub

    search_input = find("[data-search-target='input']")
    search_input.fill_in with: "low"
    assert_selector "body[data-search-fetch-count='1']", visible: :all

    enqueue_search_result(0, "current-result")
    assert_selector "#current-result"

    select "Comics & Manga"
    enqueue_search_result(0, "stale-filter-result")
    wait_for_stream_processing
    assert_no_selector "#stale-filter-result"
    assert_selector "body[data-search-fetch-count='2']", visible: :all
    assert_equal "graphic", search_request_params(1)["content_kind"]

    enqueue_search_result(1, "filtered-result")
    assert_selector "#filtered-result"

    page.execute_script <<~JAVASCRIPT
      const input = document.querySelector("[data-search-target='input']")
      input.value = "different"
      input.dispatchEvent(new Event("input", { bubbles: true }))
      input.value = "low"
      input.dispatchEvent(new Event("input", { bubbles: true }))
    JAVASCRIPT
    enqueue_search_result(1, "stale-query-result")
    wait_for_stream_processing
    assert_no_selector "#stale-query-result"
    assert_selector "body[data-search-fetch-count='3']", visible: :all
  end

  test "reconnecting a reused controller cannot reuse an old request ID" do
    sign_in_as(users(:one))
    visit search_path
    install_streaming_search_stub

    find("[data-search-target='input']").fill_in with: "low"
    assert_selector "body[data-search-fetch-count='1']", visible: :all
    assert remember_search_controller

    page.execute_script <<~JAVASCRIPT
      window.searchControllerElement = document.querySelector("[data-controller='search']")
      window.searchControllerParent = window.searchControllerElement.parentElement
      window.searchControllerElement.remove()
    JAVASCRIPT
    wait_for_stream_processing
    assert page.evaluate_script("window.searchRequests[0].signal.aborted")

    page.execute_script("window.searchControllerParent.appendChild(window.searchControllerElement)")
    wait_for_stream_processing
    assert reused_search_controller?

    page.execute_script <<~JAVASCRIPT
      const input = document.querySelector("[data-search-target='input']")
      input.dispatchEvent(new Event("input", { bubbles: true }))
    JAVASCRIPT
    enqueue_search_result(0, "stale-lifecycle-result")
    wait_for_stream_processing

    assert_no_selector "#stale-lifecycle-result"
    assert_selector "body[data-search-fetch-count='2']", visible: :all
  end

  private

  def install_streaming_search_stub
    page.execute_script <<~JAVASCRIPT
      window.searchRequests = []
      window.searchStreams = []
      window.fetch = (input, options = {}) => {
        const url = typeof input === "string" ? input : input.url
        let streamController
        const body = new ReadableStream({
          start(controller) {
            streamController = controller
          }
        })

        window.searchRequests.push({ url, signal: options.signal })
        window.searchStreams.push(streamController)
        document.body.dataset.searchFetchCount = window.searchRequests.length.toString()
        return Promise.resolve(new Response(body, {
          status: 200,
          headers: { "Content-Type": "text/vnd.turbo-stream.html" }
        }))
      }
    JAVASCRIPT
  end

  def enqueue_search_result(stream_index, element_id)
    page.execute_script <<~JAVASCRIPT
      window.searchStreams[#{stream_index}].enqueue(new TextEncoder().encode(
        '<turbo-stream action="update" target="search-results"><template><p id="#{element_id}">#{element_id}</p></template></turbo-stream>'
      ))
    JAVASCRIPT
  end

  def wait_for_stream_processing
    page.driver.browser.execute_async_script <<~JAVASCRIPT
      const done = arguments[0]
      setTimeout(done, 50)
    JAVASCRIPT
  end

  def remember_search_controller
    page.driver.browser.execute_async_script <<~JAVASCRIPT
      const done = arguments[0]
      import("controllers/application").then(({ application }) => {
        const element = document.querySelector("[data-controller='search']")
        window.rememberedSearchController = application.getControllerForElementAndIdentifier(element, "search")
        done(window.rememberedSearchController !== null)
      }).catch(() => done(false))
    JAVASCRIPT
  end

  def reused_search_controller?
    page.driver.browser.execute_async_script <<~JAVASCRIPT
      const done = arguments[0]
      import("controllers/application").then(({ application }) => {
        const element = document.querySelector("[data-controller='search']")
        const controller = application.getControllerForElementAndIdentifier(element, "search")
        done(controller === window.rememberedSearchController)
      }).catch(() => done(false))
    JAVASCRIPT
  end

  def search_request_params(index)
    page.evaluate_script <<~JAVASCRIPT
      Object.fromEntries(new URL(window.searchRequests[#{index}].url, window.location.href).searchParams)
    JAVASCRIPT
  end
end
