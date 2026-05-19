import { Controller } from "@hotwired/stimulus"

// Stimulus controller for debounced search
// Connects to data-controller="search"
export default class extends Controller {
  static targets = ["input", "results", "spinner"]
  static values = {
    url: String,
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
    const url = `${this.urlValue}?q=${encodeURIComponent(query)}`
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
        const html = await response.text()
        Turbo.renderStreamMessage(html)
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
