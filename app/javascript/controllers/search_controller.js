import { Controller } from "@hotwired/stimulus"

// Stimulus controller for debounced search
// Connects to data-controller="search"
export default class extends Controller {
  static targets = ["input", "results", "spinner", "contentKind"]
  static values = {
    url: String,
    streamUrl: String,
    debounce: { type: Number, default: 700 }
  }

  connect() {
    this.timeout = null
    this.currentAbortController = null
    this.requestSequence = 0
  }

  disconnect() {
    if (this.timeout) {
      clearTimeout(this.timeout)
    }
    this.abortCurrentRequest()
  }

  search() {
    const query = this.inputTarget.value.trim()

    // Clear existing timeout
    if (this.timeout) {
      clearTimeout(this.timeout)
    }
    this.abortCurrentRequest()

    // If query is empty, clear results
    if (query.length === 0) {
      this.resultsTarget.innerHTML = ""
      this.hideSpinner()
      return
    }

    // Don't search for very short queries
    if (query.length < 2) {
      this.hideSpinner()
      return
    }

    this.timeout = setTimeout(() => {
      this.performSearch(query)
    }, this.debounceValue)
  }

  async performSearch(query) {
    const params = new URLSearchParams({ q: query })
    if (this.hasContentKindTarget && this.contentKindTarget.value) {
      params.set("content_kind", this.contentKindTarget.value)
    }
    const url = `${this.searchUrl}?${params.toString()}`
    const requestId = ++this.requestSequence
    const abortController = new AbortController()

    this.currentAbortController = abortController
    this.showSpinner()

    try {
      const response = await fetch(url, {
        signal: abortController.signal,
        headers: {
          "Accept": "text/vnd.turbo-stream.html"
        }
      })

      if (response.ok && requestId === this.requestSequence && this.inputTarget.value.trim() === query) {
        if (response.body) {
          await this.renderStreamingResponse(response, requestId, query)
        } else {
          const html = await response.text()
          this.renderStreamMessage(html, requestId, query)
        }
      }
    } catch (error) {
      if (error.name === "AbortError") {
        return
      }

      console.error("Search failed:", error)
    } finally {
      if (this.currentAbortController === abortController) {
        this.currentAbortController = null
        this.hideSpinner()
      }
    }
  }

  abortCurrentRequest() {
    if (this.currentAbortController) {
      this.currentAbortController.abort()
      this.currentAbortController = null
    }
  }

  get searchUrl() {
    return this.hasStreamUrlValue ? this.streamUrlValue : this.urlValue
  }

  async renderStreamingResponse(response, requestId, query) {
    const reader = response.body.getReader()
    const decoder = new TextDecoder()
    const closingTag = "</turbo-stream>"
    let buffer = ""

    while (true) {
      const { done, value } = await reader.read()
      buffer += decoder.decode(value || new Uint8Array(), { stream: !done })

      let closingIndex = buffer.indexOf(closingTag)
      while (closingIndex !== -1) {
        const endIndex = closingIndex + closingTag.length
        const message = buffer.slice(0, endIndex)
        buffer = buffer.slice(endIndex)
        this.renderStreamMessage(message, requestId, query)
        closingIndex = buffer.indexOf(closingTag)
      }

      if (done) {
        if (buffer.trim().length > 0) {
          this.renderStreamMessage(buffer, requestId, query)
        }
        break
      }
    }
  }

  renderStreamMessage(html, requestId, query) {
    if (requestId === this.requestSequence && this.inputTarget.value.trim() === query) {
      Turbo.renderStreamMessage(html)
    }
  }

  showSpinner() {
    if (this.hasSpinnerTarget) {
      this.spinnerTarget.classList.remove("hidden")
    }
  }

  hideSpinner() {
    if (this.hasSpinnerTarget) {
      this.spinnerTarget.classList.add("hidden")
    }
  }
}
