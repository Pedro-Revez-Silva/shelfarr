import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["output"]
  static values = { startedAt: String }

  connect() {
    this.render()
    this.timer = setInterval(() => this.render(), 1000)
  }

  disconnect() {
    if (this.timer) clearInterval(this.timer)
  }

  render() {
    const startedAt = Date.parse(this.startedAtValue)
    if (!Number.isFinite(startedAt)) return

    const seconds = Math.max(0, Math.floor((Date.now() - startedAt) / 1000))
    this.outputTarget.textContent = this.format(seconds)
  }

  format(totalSeconds) {
    if (totalSeconds < 60) return `${totalSeconds}s`

    const minutes = Math.floor(totalSeconds / 60)
    const seconds = totalSeconds % 60
    if (minutes < 60) return `${minutes}m ${seconds}s`

    const hours = Math.floor(minutes / 60)
    return `${hours}h ${minutes % 60}m`
  }
}
