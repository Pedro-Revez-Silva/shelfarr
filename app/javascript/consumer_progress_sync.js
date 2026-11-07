// Serialize writes; retry the same mutation after a network failure. A newer
// device's version is never overwritten without an explicit choice in the UI.
export default class ConsumerProgressSync {
  constructor(url, version, notify, conflict) {
    const endpoint = new URL(url, window.location.href)
    if (endpoint.origin !== window.location.origin) throw new Error("Invalid progress endpoint")
    this.url = endpoint.href
    this.version = version || 0
    this.notify = notify
    this.onConflict = conflict
    this.latest = null
    this.retryPayload = null
    this.blocked = false
    this.closed = false
  }

  save(position) {
    if (this.closed) return
    this.latest = position
    if (!this.timer) this.timer = setTimeout(() => this.flush(), 5000)
  }

  async flush() {
    clearTimeout(this.timer)
    this.timer = null
    if (this.closed || this.writing || this.blocked || (!this.latest && !this.retryPayload)) return
    this.writing = true
    const payload = this.retryPayload || { ...this.latest, expected_version: this.version, client_mutation_id: crypto.randomUUID() }
    if (!this.retryPayload) this.latest = null
    this.retryPayload = payload
    try {
      const response = await fetch(this.url, {
        method: "PUT", credentials: "same-origin", redirect: "error", keepalive: true,
        headers: { "Content-Type": "application/json", "Accept": "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "" },
        body: JSON.stringify(payload)
      })
      const result = await response.json()
      if (response.status === 409) {
        this.blocked = true
        this.serverProgress = result.progress
        this.notify("A newer place was saved on another device", false)
        this.onConflict()
      } else if (response.ok) {
        this.version = result.progress.version
        this.retryPayload = null
        this.notify("Your place is saved", false)
      } else {
        this.notify(response.status === 401 ? "Sign in again to save your place" : "Couldn't save your place. Retry when connected.", true)
      }
    } catch (_) {
      this.notify("Couldn't sync your place. Keep this page open and retry.", true)
    } finally {
      this.writing = false
      if (this.closing) {
        if (!this.retryPayload && this.latest) this.flush()
        else this.closed = true
      } else if (!this.retryPayload && this.latest && !this.timer) {
        this.timer = setTimeout(() => this.flush(), 5000)
      }
    }
  }

  keepLocal() {
    this.version = this.serverProgress?.version || 0
    this.latest = this.latest || this.retryPayload
    if (this.latest) {
      delete this.latest.expected_version
      delete this.latest.client_mutation_id
    }
    this.retryPayload = null
    this.blocked = false
    this.flush()
  }

  close() {
    clearTimeout(this.timer)
    this.timer = null
    this.closing = true
    if (!this.writing) this.closed = true
  }
}
