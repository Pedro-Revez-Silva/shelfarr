import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["status"]
  static values = { url: String }

  connect() {
    this.active = true
    this.schedule()
  }

  disconnect() {
    this.active = false
    clearTimeout(this.timer)
    this.request?.abort()
  }

  schedule() {
    if (this.active) this.timer = setTimeout(() => this.poll(), 5000)
  }

  async poll() {
    this.request = new AbortController()
    try {
      const token = document.querySelector("meta[name='csrf-token']")?.content
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: { "Accept": "application/json", "X-CSRF-Token": token },
        credentials: "same-origin",
        signal: this.request.signal
      })
      if (!this.active) return
      if (response.redirected) {
        window.location.reload()
        return
      }
      if (!response.ok) {
        this.statusTarget.textContent = "This connection could not be checked. Reload the page to continue."
        return
      }
      const result = await response.json()
      if (!this.active) return
      if (result.status === "pending") {
        this.schedule()
      } else if (result.redirect_url) {
        window.Turbo ? window.Turbo.visit(result.redirect_url) : (window.location = result.redirect_url)
      }
    } catch (error) {
      if (!this.active || error.name === "AbortError") return
      this.statusTarget.textContent = "Could not reach Shelfarr. Retrying…"
      this.schedule()
    }
  }
}
