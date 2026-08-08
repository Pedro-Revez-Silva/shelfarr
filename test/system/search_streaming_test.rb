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

  test "next page preloads silently and renders immediately with canonical history" do
    sign_in_as(users(:one))
    visit search_path
    install_pagination_search_stub
    page.execute_script('history.replaceState({ ...history.state, reviewMarker: "preserved" }, "", window.location.href)')

    find("[data-search-target='input']").fill_in with: "low"
    assert_selector "body[data-search-fetch-count='1']", visible: :all
    enqueue_paginated_search_result(0, page_number: 1, has_next: true)

    assert_selector "body[data-search-fetch-count='2']", visible: :all
    restoration_identifier = page.evaluate_script("history.state.turbo.restorationIdentifier")
    assert_no_selector "#page-2-result"
    assert_not_equal "search-results-heading", page.evaluate_script("document.activeElement.id")

    click_link "Next"

    assert_selector "#page-2-result", text: "Page 2 result"
    assert_equal({ "q" => "low", "page" => "2" }, current_search_params)
    assert_no_match "snapshot_id", page.current_url
    assert_equal "preserved", page.evaluate_script("history.state.reviewMarker")
    assert_equal 2, page.evaluate_script("history.state.shelfarrSearch.page")
    assert_equal restoration_identifier, page.evaluate_script("history.state.turbo.restorationIdentifier")
    assert_equal "search-results-heading", page.evaluate_script("document.activeElement.id")

    page.go_back

    assert_selector "#page-1-result", text: "Page 1 result"
    assert_equal({ "q" => "low", "page" => "1" }, current_search_params)
    assert_equal 1, page.evaluate_script("window.searchStreams.length")
    assert_equal "preserved", page.evaluate_script("history.state.reviewMarker")
  end

  test "page one and two survive Turbo away Back Back with one federated search" do
    sign_in_as(users(:one))
    visit search_path
    install_pagination_search_stub
    page.execute_script('history.replaceState({ ...history.state, reviewMarker: "turbo-preserved" }, "", window.location.href)')
    restoration_identifier = page.evaluate_script("history.state.turbo.restorationIdentifier")

    find("[data-search-target='input']").fill_in with: "low"
    assert_selector "body[data-search-fetch-count='1']", visible: :all
    enqueue_paginated_search_result(0, page_number: 1, has_next: true)
    assert_selector "#page-1-result"
    assert_equal restoration_identifier, page.evaluate_script("history.state.turbo.restorationIdentifier")

    click_link "Next"
    assert_selector "#page-2-result"
    assert_equal 1, page.evaluate_script("window.searchStreams.length")

    find("nav a", text: "Shelfarr", match: :first).click
    assert_current_path root_path
    assert_link "Search for books by title or author..."

    page.go_back

    assert_selector "#page-2-result"
    assert_equal({ "q" => "low", "page" => "2" }, current_search_params)
    assert_equal 1, page.evaluate_script("window.searchStreams.length")

    page.go_back

    assert_selector "#page-1-result"
    assert_equal({ "q" => "low", "page" => "1" }, current_search_params)
    assert_equal "turbo-preserved", page.evaluate_script("history.state.reviewMarker")
    assert page.evaluate_script("Boolean(history.state.turbo)")
    assert_equal restoration_identifier, page.evaluate_script("history.state.turbo.restorationIdentifier")
    assert_equal 1, page.evaluate_script("window.searchStreams.length")
  end

  test "browser page cache is snapshot-bound across repeated A B A searches" do
    sign_in_as(users(:one))
    visit search_path
    install_pagination_search_stub

    search_with_generation("alpha", "generation-a1", stream_index: 0, has_next: true)
    search_with_generation("beta", "generation-b", stream_index: 1, has_next: false)
    search_with_generation("alpha", "generation-a2", stream_index: 2, has_next: true)

    click_link "Next"

    assert_selector "[data-snapshot-generation='generation-a2']"
    assert_no_selector "[data-snapshot-generation='generation-a1']"
    cache = search_page_cache
    assert_operator cache.fetch("size"), :<=, 5
    assert_includes cache.fetch("snapshotIds"), "generation-a1"
    assert_includes cache.fetch("snapshotIds"), "generation-a2"
  end

  test "reconnect and repeated same query cannot reuse the previous generation" do
    sign_in_as(users(:one))
    visit search_path
    install_pagination_search_stub

    search_with_generation("repeat", "repeat-old", stream_index: 0, has_next: true)
    assert remember_search_controller
    page.execute_script <<~JAVASCRIPT
      window.searchControllerElement = document.querySelector("[data-controller='search']")
      window.searchControllerParent = window.searchControllerElement.parentElement
      window.searchControllerElement.remove()
      window.searchControllerParent.appendChild(window.searchControllerElement)
    JAVASCRIPT
    wait_for_stream_processing
    assert reused_search_controller?

    page.execute_script <<~JAVASCRIPT
      const input = document.querySelector("[data-search-target='input']")
      input.dispatchEvent(new Event("input", { bubbles: true }))
    JAVASCRIPT
    assert_selector "body[data-search-stream-count='2']", visible: :all
    page.execute_script('window.searchSnapshotToken = "repeat-new"')
    enqueue_paginated_search_result(1, page_number: 1, has_next: true, query: "repeat")
    assert_selector "[data-snapshot-generation='repeat-new']"

    click_link "Next"

    assert_selector "[data-snapshot-generation='repeat-new'][data-page='2']"
    assert_no_selector "[data-snapshot-generation='repeat-old'][data-page='2']"
  end

  test "expired snapshot cache is discarded before navigation fallback" do
    sign_in_as(users(:one))
    visit search_path
    install_pagination_search_stub

    search_with_generation("low", "expired-generation", stream_index: 0, has_next: true)
    assert_selector "body[data-search-fetch-count='2']", visible: :all
    expire_current_search_snapshot

    click_link "Next"

    assert_selector "body[data-search-fetch-count='3']", visible: :all
    assert_equal "2", search_request_params(2)["page"]
    assert_no_selector "[data-snapshot-generation='expired-generation'][data-page='2']"

    page.execute_script('window.searchSnapshotToken = "fresh-generation"')
    enqueue_paginated_search_result(1, page_number: 2, has_next: false, query: "low")
    assert_selector "[data-snapshot-generation='fresh-generation']"
  end

  test "clicking Next during preload aborts it and uses a visible snapshot request" do
    sign_in_as(users(:one))
    visit search_path
    install_pagination_search_stub(delay_preload: true)

    search_with_generation("low", "click-generation", stream_index: 0, has_next: true)
    assert_selector "body[data-search-fetch-count='2']", visible: :all

    click_link "Next"

    assert page.evaluate_script("window.searchRequests[1].signal.aborted")
    assert_selector "body[data-search-fetch-count='3']", visible: :all
    assert_selector "#page-2-result"
    assert_selector "[data-snapshot-generation='click-generation']"
  end

  test "server canonical page replaces page ten without accepting another generation" do
    sign_in_as(users(:one))
    visit search_path
    install_pagination_search_stub

    navigate_search_controller(query: "low", page_number: 10)
    assert_selector "body[data-search-fetch-count='1']", visible: :all
    page.execute_script('window.searchSnapshotToken = "canonical-generation"')
    enqueue_paginated_search_result(0, page_number: 2, has_next: false, query: "low")

    assert_selector "#page-2-result"
    assert_equal({ "q" => "low", "page" => "2" }, current_search_params)
    assert_selector "[aria-current='page'][aria-label='Page 2']"
    previous = find_link("Previous")
    assert_equal({ "q" => "low", "page" => "1" }, Rack::Utils.parse_query(URI(previous[:href]).query))
  end

  test "non-OK visible responses render an idle accessible error" do
    sign_in_as(users(:one))
    visit search_path
    install_pagination_search_stub
    page.execute_script("window.failNextSearchRequest = true")

    find("[data-search-target='input']").fill_in with: "low"

    assert_selector "[role='status']", text: "Search failed. Please try again.", visible: :all
    assert_selector "#search-results[aria-busy='false']"
    assert_selector "[data-search-state][data-search-page='1'][data-search-complete='true']"
  end

  test "browser page cache keeps a bounded LRU" do
    sign_in_as(users(:one))
    visit search_path

    cache = fill_search_page_cache(6)

    assert_equal 5, cache.fetch("size")
    assert_not_includes cache.fetch("snapshotIds"), "lru-0"
    assert_equal %w[lru-1 lru-2 lru-3 lru-4 lru-5], cache.fetch("snapshotIds")
  end

  test "query changes abort and invalidate an in-flight page preload" do
    sign_in_as(users(:one))
    visit search_path
    install_pagination_search_stub(delay_preload: true)

    find("[data-search-target='input']").fill_in with: "low"
    assert_selector "body[data-search-fetch-count='1']", visible: :all
    enqueue_paginated_search_result(0, page_number: 1, has_next: true)
    assert_selector "body[data-search-fetch-count='2']", visible: :all

    find("[data-search-target='input']").fill_in with: "different"
    assert page.evaluate_script("window.searchRequests[1].signal.aborted")
    page.execute_script("window.resolveSearchPreload()")
    wait_for_stream_processing

    assert_no_selector "#page-2-result"
    assert_selector "body[data-search-fetch-count='3']", visible: :all
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

  def install_pagination_search_stub(delay_preload: false)
    page.execute_script <<~JAVASCRIPT
      window.nativeSearchFetch = window.fetch
      window.searchRequests = []
      window.searchStreams = []
      window.searchSnapshotToken = "snapshot-token-12345678901234567"
      window.searchSnapshotExpiresAt = Math.floor(Date.now() / 1000) + 600
      window.delayedSearchPreloads = #{delay_preload ? 1 : 0}
      window.failNextSearchRequest = false
      window.fetch = (input, options = {}) => {
        const url = new URL(typeof input === "string" ? input : input.url, window.location.href)
        if (!url.pathname.includes("/search/results")) {
          return window.nativeSearchFetch(input, options)
        }
        window.searchRequests.push({ url: url.toString(), signal: options.signal })
        document.body.dataset.searchFetchCount = window.searchRequests.length.toString()

        if (url.pathname.endsWith("/search/results/snapshot")) {
          const pageNumber = url.searchParams.get("page")
          const query = url.searchParams.get("q")
          const contentKind = url.searchParams.get("content_kind") || ""
          const html = window.searchPageResponse(pageNumber, query, contentKind, false)
          if (window.delayedSearchPreloads > 0) {
            window.delayedSearchPreloads -= 1
            return new Promise((resolve) => {
              window.resolveSearchPreload = () => resolve(new Response(html, {
                status: 200,
                headers: { "Content-Type": "text/vnd.turbo-stream.html" }
              }))
            })
          }
          return Promise.resolve(new Response(html, {
            status: 200,
            headers: { "Content-Type": "text/vnd.turbo-stream.html" }
          }))
        }

        if (window.failNextSearchRequest) {
          window.failNextSearchRequest = false
          return Promise.resolve(new Response("Search failed", { status: 503 }))
        }

        let streamController
        const body = new ReadableStream({
          start(controller) {
            streamController = controller
          }
        })
        window.searchStreams.push(streamController)
        document.body.dataset.searchStreamCount = window.searchStreams.length.toString()
        return Promise.resolve(new Response(body, {
          status: 200,
          headers: { "Content-Type": "text/vnd.turbo-stream.html" }
        }))
      }

      window.searchPageResponse = (pageNumber, query, contentKind, hasNext) => {
        const preloadPage = hasNext ? Number(pageNumber) + 1 : ""
        const kindParam = contentKind ? `&content_kind=${encodeURIComponent(contentKind)}` : ""
        const previousLink = Number(pageNumber) > 1
          ? `<a href="#{search_path}?q=${encodeURIComponent(query)}&page=${Number(pageNumber) - 1}${kindParam}" data-action="click->search#navigate">Previous</a>`
          : '<span aria-disabled="true">Previous</span>'
        const nextLink = hasNext
          ? `<a href="#{search_path}?q=${encodeURIComponent(query)}&page=${preloadPage}${kindParam}" data-action="click->search#navigate" data-search-page="${preloadPage}">Next</a>`
          : '<span aria-disabled="true">Next</span>'
        return `<turbo-stream action="update" target="search-results"><template>
          <div data-search-state data-search-query="${query}" data-search-content-kind="${contentKind}" data-search-page="${pageNumber}" data-search-page-count="2" data-search-has-next="${hasNext}" data-search-complete="true" data-search-snapshot-id="${window.searchSnapshotToken}" data-search-snapshot-expires-at="${window.searchSnapshotExpiresAt}" data-search-preload-page="${preloadPage}">
            <h2 id="search-results-heading" tabindex="-1">Search results</h2>
            <p role="status" aria-live="polite">Page ${pageNumber} loaded</p>
            <p id="page-${pageNumber}-result" data-page="${pageNumber}" data-snapshot-generation="${window.searchSnapshotToken}">Page ${pageNumber} result</p>
            <nav aria-label="Search result pages">${previousLink}<span aria-current="page" aria-label="Page ${pageNumber}">${pageNumber}</span>${nextLink}</nav>
          </div>
        </template></turbo-stream>`
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

  def enqueue_paginated_search_result(stream_index, page_number:, has_next:, query: "low")
    page.execute_script <<~JAVASCRIPT
      window.searchStreams[#{stream_index}].enqueue(new TextEncoder().encode(
        window.searchPageResponse(#{page_number}, "#{query}", "", #{has_next})
      ))
      window.searchStreams[#{stream_index}].close()
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

  def current_search_params
    Rack::Utils.parse_query(URI(page.current_url).query)
  end

  def search_with_generation(query, generation, stream_index:, has_next:)
    find("[data-search-target='input']").fill_in with: query
    assert_selector "body[data-search-stream-count='#{stream_index + 1}']", visible: :all
    page.execute_script("window.searchSnapshotToken = #{generation.to_json}")
    enqueue_paginated_search_result(stream_index, page_number: 1, has_next: has_next, query: query)
    assert_selector "[data-snapshot-generation='#{generation}']"
  end

  def search_page_cache
    page.driver.browser.execute_async_script <<~JAVASCRIPT
      const done = arguments[0]
      import("controllers/application").then(({ application }) => {
        const element = document.querySelector("[data-controller='search']")
        const controller = application.getControllerForElementAndIdentifier(element, "search")
        done({
          size: controller.pageCache.size,
          snapshotIds: Array.from(controller.pageCache.values(), (entry) => entry.snapshotId)
        })
      }).catch((error) => done({ error: error.message }))
    JAVASCRIPT
  end

  def expire_current_search_snapshot
    page.driver.browser.execute_async_script <<~JAVASCRIPT
      const done = arguments[0]
      import("controllers/application").then(({ application }) => {
        const element = document.querySelector("[data-controller='search']")
        const controller = application.getControllerForElementAndIdentifier(element, "search")
        controller.snapshotExpiresAt = Math.floor(Date.now() / 1000) - 1
        done(true)
      }).catch(() => done(false))
    JAVASCRIPT
  end

  def navigate_search_controller(query:, page_number:)
    page.driver.browser.execute_async_script <<~JAVASCRIPT
      const done = arguments[0]
      import("controllers/application").then(({ application }) => {
        const element = document.querySelector("[data-controller='search']")
        const controller = application.getControllerForElementAndIdentifier(element, "search")
        controller.navigateToState(
          { query: #{query.to_json}, contentKind: "", page: #{page_number} },
          { historyMode: "push", focus: true }
        )
        done(true)
      }).catch(() => done(false))
    JAVASCRIPT
  end

  def fill_search_page_cache(count)
    page.driver.browser.execute_async_script <<~JAVASCRIPT
      const done = arguments[0]
      import("controllers/application").then(({ application }) => {
        const element = document.querySelector("[data-controller='search']")
        const controller = application.getControllerForElementAndIdentifier(element, "search")
        const expiresAt = Math.floor(Date.now() / 1000) + 600
        for (let index = 0; index < #{count}; index += 1) {
          controller.storePage(`query-${index}`, "", 1, `lru-${index}`, expiresAt, `<p>${index}</p>`)
        }
        done({
          size: controller.pageCache.size,
          snapshotIds: Array.from(controller.pageCache.values(), (entry) => entry.snapshotId)
        })
      }).catch((error) => done({ error: error.message }))
    JAVASCRIPT
  end
end
