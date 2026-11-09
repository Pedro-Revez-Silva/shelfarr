import { Controller } from "@hotwired/stimulus"

// The Download / Available offline control for one publication. It lives in
// the ebook's reading controls and under the audiobook player, so the book
// text itself stays the whole page.
export default class extends Controller {
  static targets = ["state", "mark", "primary", "secondary", "progress", "note", "manage"]
  static values = { mode: String }

  async connect() {
    this.active = true
    this.reader = this.element.closest("[data-controller~='consumer-reader']")
    const data = this.reader?.querySelector("script[data-consumer-reader-target=publication]")
    try { this.publication = JSON.parse(data?.textContent || "null") } catch (_) { this.publication = null }
    if (!this.publication?.progress_scope?.account) return
    try { this.offline = await import("consumer_offline") } catch (_) { return }
    if (!this.active) return
    const offline = this.offline
    const check = offline.support()
    this.element.hidden = false
    if (!check.ok) return this.message(check.reason === "insecure"
      ? "Offline downloads need a secure (HTTPS) connection to this server." : offline.MESSAGES.unsupported)
    if (this.online && !this.publication.offline?.supported) return this.message("This book can't be kept offline in the web reader.")
    const { base = "", account } = this.publication.progress_scope
    this.base = base
    this.deployment = offline.deploymentOf(base)
    this.downloadScope = offline.scopeOf(this.deployment, account)
    this.key = offline.recordKey(this.downloadScope, this.publication.id)
    // A browser that never downloaded here has nothing to look up yet.
    if (!await offline.hasWorker(base)) return this.render(null)
    await this.watch()
    if (this.online) await offline.rememberProgress(this.key, this.publication.progress, this.publication.reading_status).catch(() => {})
    await this.refresh({ verify: true })
  }

  disconnect() {
    this.active = false
    clearTimeout(this.confirmTimer)
    this.unsubscribe?.()
    if (this.progressHandler) this.reader?.removeEventListener("consumer-reader:server-progress", this.progressHandler)
  }

  get online() { return this.modeValue !== "offline" }

  async watch() {
    if (this.unsubscribe) return
    this.unsubscribe = this.offline.subscribe(this.deployment, (type, detail) => {
      if (detail?.key && detail.key !== this.key) return
      if (type === "progress") this.renderProgress(detail)
      else this.refresh()
    })
    this.progressHandler = event => this.offline.rememberProgress(this.key, event.detail, this.publication.reading_status).catch(() => {})
    this.reader?.addEventListener("consumer-reader:server-progress", this.progressHandler)
  }

  async refresh({ verify = false } = {}) {
    if (!this.active || !this.key) return
    let record = null
    try {
      record = await this.offline.getRecord(this.key)
      if (verify && record?.publication && !record.pending && !await this.offline.verify(record)) record = await this.offline.markEvicted(record)
    } catch (_) { return this.message(this.offline.MESSAGES.storage) }
    if (!this.active) return
    this.render(record, await this.offline.isRunning(this.key))
  }

  // Rendering -------------------------------------------------------------------

  render(record, running = false) {
    const offline = this.offline
    const page = this.publication
    const state = offline.stateOf(record, running)
    this.state = state
    const size = offline.formatBytes(offline.bytesOf(state.kind === "none" ? page : record?.pending || record?.publication))
    const listening = page.book_type === "audiobook"
    const olderEdition = this.online && state.kind === "ready" && offline.editionOf(record.publication) !== offline.editionOf(page)
    let text, mark = "", primary = null, secondary = null, note = null, progress = false
    switch (state.kind) {
      case "none":
        text = `${listening ? "Listen" : "Read"} without a connection · ${size}`
        if (this.online) primary = "Download"
        else text = "Opened from this device"
        break
      case "downloading":
        text = `${state.update ? "Updating" : "Downloading"} · ${this.percent(state)}% of ${size}`
        if (state.update) note = "The current download stays available until the update finishes."
        secondary = "Cancel"
        progress = true
        break
      case "paused":
      case "failed":
        text = state.kind === "paused" ? `Download paused at ${this.percent(state)}%` : "Download stopped"
        note = state.error?.message
        if (state.update) note = `${note} The previous download is still available.`
        if (this.online) { primary = state.kind === "paused" ? "Resume" : "Try again"; secondary = "Cancel" }
        progress = state.done > 0
        break
      case "ready":
        mark = "✓"
        text = olderEdition ? "Available offline · an older edition" : `Available offline · ${size}`
        if (olderEdition) { note = "The server has a newer file. Update to keep the new edition offline."; primary = "Update" }
        if (this.online) secondary = "Remove"
        break
    }
    if (this.confirming && secondary === "Remove") { secondary = "Remove from this device?"; note = "Select again to remove the download. Your saved place is kept." }
    else this.confirming = false
    if (this.persistNote && (state.kind === "downloading" || state.kind === "ready")) note ||= this.persistNote
    this.markTarget.textContent = mark
    this.stateTarget.textContent = text
    this.button(this.primaryTarget, primary)
    this.button(this.secondaryTarget, secondary)
    this.noteTarget.hidden = !note
    this.noteTarget.textContent = note || ""
    this.progressTarget.hidden = !progress
    this.progressTarget.value = state.total && Number.isFinite(state.done) ? state.done / state.total : 0
    this.manageTarget.hidden = !(this.online && state.kind !== "none")
    this.element.dataset.offlineState = olderEdition ? "update" : state.kind
  }

  renderProgress(detail) {
    const state = this.state
    if (!state || state.kind !== "downloading" || !Number.isFinite(detail?.received)) return
    const done = Math.min(state.total, state.done + detail.received)
    this.progressTarget.value = state.total ? done / state.total : 0
    const percent = state.total ? Math.floor(done / state.total * 100) : 0
    this.stateTarget.textContent = `${state.update ? "Updating" : "Downloading"} · ${percent}% of ${this.offline.formatBytes(state.total)}`
  }

  percent(state) { return state.total ? Math.floor(state.done / state.total * 100) : 0 }

  button(target, label) {
    target.hidden = !label
    target.disabled = false
    if (label) target.textContent = label
  }

  message(text) {
    this.element.hidden = false
    this.stateTarget.textContent = text
    this.element.dataset.offlineState = "unavailable"
  }

  // Actions -----------------------------------------------------------------------

  async primary() {
    if (!this.offline || !this.online) return
    this.primaryTarget.disabled = true
    // Asked only after a deliberate download; the browser decides.
    const persistence = this.offline.requestPersistence()
    try {
      const maxAgeDays = Number(document.body.dataset.consumerOfflinePresenceMaxAgeDaysValue)
      await this.offline.confirmAccount({ base: this.base, account: this.publication.progress_scope.account, maxAgeDays })
      await this.watch()
      await this.offline.download(this.publication)
      this.persistNote = this.offline.persistenceNote(await persistence)
      await this.refresh()
    } catch (error) {
      await this.refresh()
      this.noteTarget.hidden = false
      this.noteTarget.textContent = error?.message || this.offline.MESSAGES.storage
    } finally {
      this.primaryTarget.disabled = false
    }
  }

  async secondary() {
    if (!this.offline || !this.online || !this.state) return
    const kind = this.state.kind
    if (kind === "ready" && !this.confirming) {
      this.confirming = true
      clearTimeout(this.confirmTimer)
      this.confirmTimer = setTimeout(() => { this.confirming = false; this.refresh() }, 6000)
      return this.refresh()
    }
    this.confirming = false
    clearTimeout(this.confirmTimer)
    this.secondaryTarget.disabled = true
    try {
      if (kind === "ready") await this.offline.remove(this.key)
      else await this.offline.cancel(this.key)
    } catch (_) {
      this.noteTarget.hidden = false
      this.noteTarget.textContent = "The download couldn't be removed. Try again."
    }
    await this.refresh()
  }
}
