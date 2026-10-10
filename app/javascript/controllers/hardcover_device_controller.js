import { Controller } from "@hotwired/stimulus"

// Polls the device sign-in endpoint at the interval Hardcover requested.
// The server enforces the same interval, so this only drives the UI.
export default class extends Controller {
  static targets = ["status"]
  static values = { url: String, interval: Number }

  connect() {
    this.schedule()
  }

  disconnect() {
    clearTimeout(this.timer)
  }

  schedule() {
    const seconds = Math.max(this.intervalValue || 5, 5)
    this.timer = setTimeout(() => this.poll(), seconds * 1000)
  }

  async poll() {
    try {
      const token = document.querySelector("meta[name='csrf-token']")?.content
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: { "Accept": "application/json", "X-CSRF-Token": token },
        credentials: "same-origin"
      })
      const result = await response.json()
      if (result.status === "pending") {
        this.schedule()
        return
      }
      if (result.message && this.hasStatusTarget) this.statusTarget.textContent = result.message
      if (result.redirect_url) window.Turbo ? window.Turbo.visit(result.redirect_url) : (window.location = result.redirect_url)
    } catch (_error) {
      if (this.hasStatusTarget) this.statusTarget.textContent = "Could not reach Shelfarr. Retrying…"
      this.schedule()
    }
  }
}
