import { Controller } from "@hotwired/stimulus"

// On every reader page: once this browser has been set up for downloads,
// remember which account is signed in here (so offline pages show only its
// downloads) and mark downloaded books on the shelf.
export default class extends Controller {
  static values = { account: String, base: String, maxAgeDays: Number }

  async connect() {
    this.active = true
    let offline
    try { offline = await import("consumer_offline") } catch (_) { return }
    if (!this.active || !this.accountValue || !await offline.hasWorker(this.baseValue)) return
    try {
      await offline.confirmAccount({ base: this.baseValue, account: this.accountValue, maxAgeDays: this.maxAgeDaysValue })
      const scope = offline.scopeOf(offline.deploymentOf(this.baseValue), this.accountValue)
      const records = await offline.listRecords(scope)
      if (!this.active) return
      for (const link of this.element.querySelectorAll("[data-offline-downloads-link]")) link.hidden = records.length === 0
      const downloads = new Map(records.map(record => [record.id, record]))
      for (const card of this.element.querySelectorAll("[data-offline-publication]")) {
        const record = downloads.get(card.dataset.offlinePublication)
        if (!record || !(record.publication || record.pending) || card.querySelector(".consumer-offline-chip")) continue
        // An update in progress keeps the earlier complete copy readable.
        const ready = Boolean(record.publication)
        const chip = document.createElement("span")
        chip.className = `consumer-offline-chip consumer-offline-chip--${ready ? "ready" : "paused"}`
        chip.textContent = ready ? "On this device" : "Download not finished"
        const place = card.querySelector(".consumer-resume-copy") || card
        place.append(chip)
      }
    } catch (_) { /* marks are a convenience; the shelf works without them */ }
  }

  disconnect() { this.active = false }
}
