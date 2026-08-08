import { Controller } from "@hotwired/stimulus"

const PAGE_CACHE_LIMIT = 5
const PAGE_CACHE_TTL = 10 * 60 * 1000

// Handles progressive federated search and cached aggregate page navigation.
export default class extends Controller {
  static targets = ["input", "results", "spinner", "contentKind"]
  static values = {
    indexUrl: String,
    url: String,
    streamUrl: String,
    snapshotUrl: String,
    page: { type: Number, default: 1 },
    initialSearch: Boolean,
    debounce: { type: Number, default: 700 }
  }

  connect() {
    this.timeout = null
    this.currentAbortController = null
    this.preloadAbortController = null
    this.requestSequence ??= 0
    this.pageCache ??= new Map()

    this.requestSequence += 1
    const urlState = this.stateFromUrl(window.location.href)
    this.pageValue = urlState.page
    const restoredState = this.restoreSnapshotFromPage()

    const query = this.inputTarget.value.trim()
    if (this.completeStateMatches(restoredState, query, this.currentContentKind, this.pageValue) &&
        (!restoredState.snapshotId || !this.snapshotExpired(restoredState.snapshotExpiresAt))) {
      return
    }

    const historyState = this.restoreSnapshotFromHistory(query, this.currentContentKind, this.pageValue)
    if (historyState && query.length >= 2) {
      const requestId = this.beginGeneration()
      this.fetchSnapshotPage(urlState, requestId, { focus: false })
    } else if (query.length >= 2 && (this.initialSearchValue || restoredState)) {
      const requestId = this.beginGeneration()
      this.performSearch(query, this.currentContentKind, this.pageValue, requestId)
    }
  }

  disconnect() {
    if (this.timeout) clearTimeout(this.timeout)
    this.timeout = null
    this.requestSequence += 1
    this.abortVisibleRequest()
    this.abortPreloadRequest()
  }

  search() {
    const query = this.inputTarget.value.trim()
    const contentKind = this.currentContentKind
    const page = 1
    const requestId = this.beginGeneration()

    if (this.timeout) clearTimeout(this.timeout)
    this.timeout = null
    this.pageValue = page
    this.clearSnapshot()

    if (query.length === 0) {
      this.resultsTarget.innerHTML = ""
      this.resultsTarget.setAttribute("aria-busy", "false")
      this.replaceCanonicalState(query, contentKind, page)
      this.hideSpinner()
      return
    }

    if (query.length < 2) {
      this.resultsTarget.innerHTML = ""
      this.resultsTarget.setAttribute("aria-busy", "false")
      this.replaceCanonicalState(query, contentKind, page)
      this.hideSpinner()
      return
    }

    this.timeout = setTimeout(() => {
      this.timeout = null
      this.replaceCanonicalState(query, contentKind, page)
      this.performSearch(query, contentKind, page, requestId)
    }, this.debounceValue)
  }

  navigate(event) {
    if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return

    event.preventDefault()
    const state = this.stateFromUrl(event.currentTarget.href)
    this.navigateToState(state, { historyMode: "push", focus: true })
  }

  async performSearch(query, contentKind, page, requestId, { focus = false } = {}) {
    if (!this.searchStateMatches(requestId, query, contentKind, page)) return

    const params = this.searchParams(query, contentKind, page)
    const url = `${this.searchUrl}?${params.toString()}`
    const abortController = new AbortController()

    this.currentAbortController = abortController
    this.resultsTarget.setAttribute("aria-busy", "true")
    this.showSpinner()

    let completed = false
    try {
      const response = await fetch(url, {
        signal: abortController.signal,
        headers: { "Accept": "text/vnd.turbo-stream.html" }
      })

      if (!this.searchStateMatches(requestId, query, contentKind, page)) return

      if (response.ok) {
        if (response.body) {
          completed = await this.renderStreamingResponse(response, requestId, query, contentKind, page, { focus })
        } else {
          const html = await response.text()
          completed = this.renderStreamMessage(html, requestId, query, contentKind, page, { focus })
        }
      } else {
        this.renderRequestError(requestId, query, contentKind, page, { focus })
      }
    } catch (error) {
      if (error.name !== "AbortError" && this.searchStateMatches(requestId, query, contentKind, page)) {
        console.error("Search failed:", error)
        this.renderRequestError(requestId, query, contentKind, page, { focus })
      }
    } finally {
      if (this.currentAbortController === abortController) {
        this.currentAbortController = null
        this.hideSpinner()
        if (!completed && this.searchStateMatches(requestId, query, contentKind, page) &&
            this.resultsTarget.getAttribute("aria-busy") === "true") {
          this.renderRequestError(requestId, query, contentKind, page, { focus })
        }
      }
    }
  }

  async renderStreamingResponse(response, requestId, query, contentKind, page, { focus }) {
    const reader = response.body.getReader()
    const decoder = new TextDecoder()
    const closingTag = "</turbo-stream>"
    let buffer = ""
    let completed = false

    while (true) {
      const { done, value } = await reader.read()
      buffer += decoder.decode(value || new Uint8Array(), { stream: !done })

      let closingIndex = buffer.indexOf(closingTag)
      while (closingIndex !== -1) {
        const endIndex = closingIndex + closingTag.length
        const message = buffer.slice(0, endIndex)
        buffer = buffer.slice(endIndex)
        completed = this.renderStreamMessage(message, requestId, query, contentKind, page, { focus }) || completed
        closingIndex = buffer.indexOf(closingTag)
      }

      if (done) {
        if (buffer.trim().length > 0) {
          completed = this.renderStreamMessage(buffer, requestId, query, contentKind, page, { focus }) || completed
        }
        break
      }
    }

    return completed
  }

  renderStreamMessage(html, requestId, query, contentKind, page, { focus = false, expectedSnapshotId = null } = {}) {
    if (!this.searchStateMatches(requestId, query, contentKind, page)) return false

    const responseState = this.stateFromResponse(html)
    if (responseState && !this.responseStateMatches(responseState, query, contentKind, page)) return false
    if (expectedSnapshotId && responseState?.snapshotId !== expectedSnapshotId) return false

    Turbo.renderStreamMessage(html)
    if (!responseState) return false

    queueMicrotask(() => {
      if (!this.searchStateMatches(requestId, query, contentKind, page)) return

      this.resultsTarget.setAttribute("aria-busy", responseState.complete ? "false" : "true")
      this.pageValue = responseState.page
      if (responseState.snapshotId && !this.snapshotExpired(responseState.snapshotExpiresAt)) {
        this.currentSnapshotId = responseState.snapshotId
        this.snapshotExpiresAt = responseState.snapshotExpiresAt
        this.snapshotQuery = query
        this.snapshotContentKind = contentKind
      }

      if (!responseState.complete) return

      this.replaceCanonicalState(
        query,
        contentKind,
        responseState.page,
        responseState.snapshotId,
        responseState.snapshotExpiresAt
      )

      this.storePage(query, contentKind, responseState.page, responseState.snapshotId, responseState.snapshotExpiresAt, html)
      if (focus) this.focusResultsHeading()
      this.preloadNextPage(responseState, requestId, query, contentKind, responseState.page)
    })

    return responseState.complete
  }

  async navigateToState(state, { historyMode, focus }) {
    const requestId = this.beginGeneration()
    this.inputTarget.value = state.query
    if (this.hasContentKindTarget) this.contentKindTarget.value = state.contentKind
    this.pageValue = state.page

    if (historyMode === "push") {
      this.pushCanonicalState(state.query, state.contentKind, state.page)
    }

    if (state.query.length < 2) {
      this.resultsTarget.innerHTML = ""
      this.hideSpinner()
      return
    }

    if (this.snapshotMatches(state.query, state.contentKind)) {
      const cached = this.cachedPage(
        state.query,
        state.contentKind,
        state.page,
        this.currentSnapshotId,
        this.snapshotExpiresAt
      )
      if (cached) {
        this.hideSpinner()
        this.renderStreamMessage(cached, requestId, state.query, state.contentKind, state.page, {
          focus,
          expectedSnapshotId: this.currentSnapshotId
        })
        return
      }
      await this.fetchSnapshotPage(state, requestId, { focus })
    } else {
      this.clearSnapshot()
      await this.performSearch(state.query, state.contentKind, state.page, requestId, { focus })
    }
  }

  async fetchSnapshotPage(state, requestId, { focus }) {
    const snapshotId = this.currentSnapshotId
    const abortController = new AbortController()
    this.currentAbortController = abortController
    this.resultsTarget.setAttribute("aria-busy", "true")
    this.showSpinner()

    try {
      const response = await fetch(this.snapshotRequestUrl(snapshotId, state.query, state.contentKind, state.page), {
        signal: abortController.signal,
        headers: { "Accept": "text/vnd.turbo-stream.html" }
      })

      if (!this.searchStateMatches(requestId, state.query, state.contentKind, state.page)) return

      if (response.ok) {
        const html = await response.text()
        const rendered = this.renderStreamMessage(html, requestId, state.query, state.contentKind, state.page, {
          focus,
          expectedSnapshotId: snapshotId
        })
        if (!rendered && this.searchStateMatches(requestId, state.query, state.contentKind, state.page)) {
          this.currentAbortController = null
          this.clearSnapshot()
          await this.performSearch(state.query, state.contentKind, state.page, requestId, { focus })
        }
      } else {
        this.currentAbortController = null
        this.clearSnapshot()
        await this.performSearch(state.query, state.contentKind, state.page, requestId, { focus })
      }
    } catch (error) {
      if (error.name !== "AbortError" && this.searchStateMatches(requestId, state.query, state.contentKind, state.page)) {
        console.error("Search page failed:", error)
        this.currentAbortController = null
        this.clearSnapshot()
        await this.performSearch(state.query, state.contentKind, state.page, requestId, { focus })
      }
    } finally {
      if (this.currentAbortController === abortController) {
        this.currentAbortController = null
        this.hideSpinner()
      }
    }
  }

  preloadNextPage(state, requestId, query, contentKind, page) {
    this.abortPreloadRequest()
    if (!state.preloadPage || !state.snapshotId || this.snapshotExpired(state.snapshotExpiresAt)) return

    const preloadPage = state.preloadPage
    if (this.cachedPage(query, contentKind, preloadPage, state.snapshotId, state.snapshotExpiresAt)) return

    const abortController = new AbortController()
    this.preloadAbortController = abortController

    fetch(this.snapshotRequestUrl(state.snapshotId, query, contentKind, preloadPage), {
      signal: abortController.signal,
      headers: { "Accept": "text/vnd.turbo-stream.html" }
    }).then(async (response) => {
      if (!response.ok) return
      const html = await response.text()
      const responseState = this.stateFromResponse(html)
      if (abortController.signal.aborted ||
          !this.searchStateMatches(requestId, query, contentKind, page) ||
          this.currentSnapshotId !== state.snapshotId ||
          this.snapshotExpired(state.snapshotExpiresAt) ||
          !responseState?.complete ||
          responseState.snapshotId !== state.snapshotId ||
          !this.responseStateMatches(responseState, query, contentKind, preloadPage)) return

      this.storePage(query, contentKind, responseState.page, state.snapshotId, state.snapshotExpiresAt, html)
    }).catch((error) => {
      if (error.name !== "AbortError") console.error("Search page preload failed:", error)
    }).finally(() => {
      if (this.preloadAbortController === abortController) this.preloadAbortController = null
    })
  }

  beginGeneration() {
    this.requestSequence += 1
    this.abortVisibleRequest()
    this.abortPreloadRequest()
    return this.requestSequence
  }

  abortVisibleRequest() {
    if (this.currentAbortController) this.currentAbortController.abort()
    this.currentAbortController = null
  }

  abortPreloadRequest() {
    if (this.preloadAbortController) this.preloadAbortController.abort()
    this.preloadAbortController = null
  }

  clearSnapshot() {
    this.currentSnapshotId = null
    this.snapshotExpiresAt = null
    this.snapshotQuery = null
    this.snapshotContentKind = null
  }

  snapshotMatches(query, contentKind) {
    if (this.snapshotExpired(this.snapshotExpiresAt)) {
      this.deleteSnapshotPages(this.currentSnapshotId)
      this.clearSnapshot()
      return false
    }

    return this.currentSnapshotId && this.snapshotQuery === query && this.snapshotContentKind === contentKind
  }

  get searchUrl() {
    return this.hasStreamUrlValue ? this.streamUrlValue : this.urlValue
  }

  get currentContentKind() {
    return this.hasContentKindTarget ? this.contentKindTarget.value : ""
  }

  searchStateMatches(requestId, query, contentKind, page) {
    return requestId === this.requestSequence &&
      this.inputTarget.value.trim() === query &&
      this.currentContentKind === contentKind &&
      this.pageValue === page
  }

  responseStateMatches(state, query, contentKind, page) {
    const canonicalPage = state.complete && state.page <= page
    return state.query === query && state.contentKind === contentKind &&
      (state.page === page || canonicalPage)
  }

  stateFromResponse(html) {
    const document = new DOMParser().parseFromString(html, "text/html")
    const template = document.querySelector("turbo-stream template")
    const element = template?.content.querySelector("[data-search-state]")
    return element ? this.stateFromElement(element) : null
  }

  stateFromElement(element) {
    return {
      query: element.dataset.searchQuery || "",
      contentKind: element.dataset.searchContentKind || "",
      page: this.normalizePage(element.dataset.searchPage),
      complete: element.dataset.searchComplete === "true",
      snapshotId: element.dataset.searchSnapshotId || null,
      snapshotExpiresAt: Number.parseInt(element.dataset.searchSnapshotExpiresAt || "0", 10),
      preloadPage: element.dataset.searchPreloadPage ? this.normalizePage(element.dataset.searchPreloadPage) : null
    }
  }

  restoreSnapshotFromPage() {
    const element = this.resultsTarget.querySelector("[data-search-state]")
    if (!element) return null

    const state = this.stateFromElement(element)
    if (!state.complete) return null
    if (!state.snapshotId || this.snapshotExpired(state.snapshotExpiresAt)) return state

    this.currentSnapshotId = state.snapshotId
    this.snapshotExpiresAt = state.snapshotExpiresAt
    this.snapshotQuery = state.query
    this.snapshotContentKind = state.contentKind
    return state
  }

  restoreSnapshotFromHistory(query, contentKind, page) {
    const state = history.state?.shelfarrSearch
    if (!state || state.query !== query || state.contentKind !== contentKind || state.page !== page ||
        !state.snapshotId || this.snapshotExpired(state.snapshotExpiresAt)) return null

    this.currentSnapshotId = state.snapshotId
    this.snapshotExpiresAt = state.snapshotExpiresAt
    this.snapshotQuery = query
    this.snapshotContentKind = contentKind
    return state
  }

  completeStateMatches(state, query, contentKind, page) {
    return state?.complete && state.query === query && state.contentKind === contentKind && state.page === page
  }

  stateFromUrl(value) {
    const url = new URL(value, window.location.href)
    return {
      query: (url.searchParams.get("q") || "").trim(),
      contentKind: this.normalizeContentKind(url.searchParams.get("content_kind")),
      page: this.normalizePage(url.searchParams.get("page"))
    }
  }

  normalizeContentKind(value) {
    if (value === "comic" || value === "manga") return "graphic"
    return value === "book" || value === "graphic" ? value : ""
  }

  normalizePage(value) {
    const page = Number.parseInt(value || "1", 10)
    return Number.isFinite(page) ? Math.min(Math.max(page, 1), 10) : 1
  }

  searchParams(query, contentKind, page) {
    const params = new URLSearchParams({ q: query, page: page.toString() })
    if (contentKind) params.set("content_kind", contentKind)
    return params
  }

  snapshotRequestUrl(snapshotId, query, contentKind, page) {
    const params = this.searchParams(query, contentKind, page)
    params.set("snapshot_id", snapshotId)
    return `${this.snapshotUrlValue}?${params.toString()}`
  }

  canonicalUrl(query, contentKind, page) {
    const url = new URL(this.indexUrlValue, window.location.origin)
    if (query) {
      url.search = this.searchParams(query, contentKind, page).toString()
    }
    return `${url.pathname}${url.search}`
  }

  pushCanonicalState(query, contentKind, page) {
    history.pushState(this.searchHistoryState(query, contentKind, page), "", this.canonicalUrl(query, contentKind, page))
  }

  replaceCanonicalState(query, contentKind, page, snapshotId = null, snapshotExpiresAt = null) {
    history.replaceState(
      this.searchHistoryState(query, contentKind, page, snapshotId, snapshotExpiresAt),
      "",
      this.canonicalUrl(query, contentKind, page)
    )
  }

  searchHistoryState(
    query,
    contentKind,
    page,
    snapshotId = this.currentSnapshotId,
    snapshotExpiresAt = this.snapshotExpiresAt
  ) {
    const current = history.state && typeof history.state === "object" ? history.state : {}
    return {
      ...current,
      shelfarrSearch: { query, contentKind, page, snapshotId, snapshotExpiresAt }
    }
  }

  pageKey(query, contentKind, page, snapshotId) {
    return JSON.stringify([snapshotId, query, contentKind, page])
  }

  storePage(query, contentKind, page, snapshotId, snapshotExpiresAt, html) {
    if (!snapshotId || this.snapshotExpired(snapshotExpiresAt)) return

    const key = this.pageKey(query, contentKind, page, snapshotId)
    this.pageCache.delete(key)
    this.pageCache.set(key, { html, snapshotId, snapshotExpiresAt, storedAt: Date.now() })
    while (this.pageCache.size > PAGE_CACHE_LIMIT) {
      this.pageCache.delete(this.pageCache.keys().next().value)
    }
  }

  cachedPage(query, contentKind, page, snapshotId, snapshotExpiresAt) {
    if (!snapshotId || this.snapshotExpired(snapshotExpiresAt)) {
      this.deleteSnapshotPages(snapshotId)
      return null
    }

    const key = this.pageKey(query, contentKind, page, snapshotId)
    const cached = this.pageCache.get(key)
    if (!cached) return null
    if (cached.snapshotId !== snapshotId || cached.snapshotExpiresAt !== snapshotExpiresAt ||
        Date.now() - cached.storedAt > PAGE_CACHE_TTL || this.snapshotExpired(cached.snapshotExpiresAt)) {
      this.pageCache.delete(key)
      return null
    }
    this.pageCache.delete(key)
    this.pageCache.set(key, cached)
    return cached.html
  }

  deleteSnapshotPages(snapshotId) {
    if (!snapshotId) return

    for (const [key, cached] of this.pageCache) {
      if (cached.snapshotId === snapshotId) this.pageCache.delete(key)
    }
  }

  snapshotExpired(expiresAt) {
    return !Number.isFinite(expiresAt) || expiresAt * 1000 <= Date.now()
  }

  renderRequestError(requestId, query, contentKind, page, { focus }) {
    if (!this.searchStateMatches(requestId, query, contentKind, page)) return

    this.clearSnapshot()
    const container = document.createElement("div")
    container.dataset.searchState = ""
    container.dataset.searchQuery = query
    container.dataset.searchContentKind = contentKind
    container.dataset.searchPage = page.toString()
    container.dataset.searchPageCount = "0"
    container.dataset.searchHasNext = "false"
    container.dataset.searchComplete = "true"

    const heading = document.createElement("h2")
    heading.id = "search-results-heading"
    heading.tabIndex = -1
    heading.className = "mb-4 text-xl font-semibold text-white focus:outline-none"
    heading.textContent = "Search results"

    const status = document.createElement("p")
    status.className = "sr-only"
    status.setAttribute("role", "status")
    status.setAttribute("aria-live", "polite")
    status.setAttribute("aria-atomic", "true")
    status.textContent = "Search failed. Please try again."

    const error = document.createElement("div")
    error.className = "rounded-lg border border-red-500/20 bg-red-500/10 p-4 text-red-400"
    error.textContent = "Search failed. Please try again."

    container.append(heading, status, error)
    this.resultsTarget.replaceChildren(container)
    this.resultsTarget.setAttribute("aria-busy", "false")
    if (focus) this.focusResultsHeading()
  }

  focusResultsHeading() {
    requestAnimationFrame(() => {
      this.resultsTarget.querySelector("#search-results-heading")?.focus()
    })
  }

  showSpinner() {
    if (this.hasSpinnerTarget) this.spinnerTarget.classList.remove("hidden")
  }

  hideSpinner() {
    if (this.hasSpinnerTarget) this.spinnerTarget.classList.add("hidden")
  }
}
