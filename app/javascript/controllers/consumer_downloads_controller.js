import { Controller } from "@hotwired/stimulus"

// This browser's downloads for one account: their state, size and storage,
// with Open, Resume, Update, Cancel and Remove. Rendered from local records
// only; while online, the library confirms newer editions and saved places.
export default class extends Controller {
  static targets = ["unsupported", "storage", "usage", "persistence", "list", "empty", "footer", "others", "removeOthers", "removeAll"]
  static values = { base: String, account: String, mode: String }

  async connect() {
    this.active = true
    try { this.offline = await import("consumer_offline") } catch (_) { return }
    if (!this.active) return
    const check = this.offline.support()
    if (!check.ok) return this.unsupported(check.reason === "insecure"
      ? "Offline downloads need a secure (HTTPS) connection to this server. Ask the server's administrator to enable HTTPS." : this.offline.MESSAGES.unsupported)
    this.deployment = this.offline.deploymentOf(this.baseValue)
    if (!await this.offline.hasWorker(this.baseValue)) return this.showEmpty()
    // Offline, the account is the one this browser last confirmed.
    let account = this.accountValue
    if (!account && !this.online) {
      const active = await this.offline.activeAccount(this.baseValue).catch(() => null)
      account = active && !active.expired ? active.account : ""
    }
    await this.setAccount(account)
  }

  disconnect() {
    this.active = false
    this.unsubscribe?.()
    clearTimeout(this.renderTimer)
    clearTimeout(this.confirmTimer)
  }

  get online() { return this.modeValue !== "offline" }

  async setAccount(account) {
    if (!account) return this.showEmpty()
    this.account = String(account)
    this.downloadScope = this.offline.scopeOf(this.deployment, this.account)
    this.unsubscribe ||= this.offline.subscribe(this.deployment, (type, detail) => type === "progress" ? this.renderProgress(detail) : this.scheduleRender())
    await this.render({ verify: true })
    if (this.online) this.refreshFromLibrary()
  }

  async refreshFromLibrary() {
    try {
      const records = await this.offline.listRecords(this.downloadScope)
      const url = `${this.baseValue}/read/offline/publications`
      await this.offline.refresh(records, url, this.account)
      if (this.active) await this.render()
    } catch (_) { /* the local list stays as it is */ }
  }

  scheduleRender() {
    clearTimeout(this.renderTimer)
    this.renderTimer = setTimeout(() => this.render(), 100)
  }

  async render({ verify = false } = {}) {
    if (!this.active || !this.downloadScope) return
    const offline = this.offline
    let records
    try {
      records = await offline.listRecords(this.downloadScope)
      if (verify) {
        for (const record of records) {
          if (record.publication && !record.pending && !await offline.verify(record)) await offline.markEvicted(record)
        }
        records = await offline.listRecords(this.downloadScope)
      }
    } catch (_) { return this.unsupported(offline.MESSAGES.storage) }
    if (!this.active) return
    const states = await Promise.all(records.map(async record => [record, offline.stateOf(record, await offline.isRunning(record.key))]))
    this.states = new Map(states.map(([record, state]) => [record.key, state]))
    this.listTarget.replaceChildren(...states.map(([record, state]) => this.row(record, state)))
    this.emptyTarget.hidden = records.length > 0
    await this.renderStorage(records)
  }

  async renderStorage(records) {
    const offline = this.offline
    const used = records.reduce((sum, record) => sum + offline.storedBytes(record), 0)
    const { quota, usage, persisted } = await offline.storageState()
    const free = Number.isFinite(quota) && Number.isFinite(usage) ? Math.max(0, quota - usage) : null
    const count = records.length === 1 ? "1 download" : `${records.length} downloads`
    let text = `${offline.formatBytes(used)} used by ${count}.`
    if (free !== null) text += ` About ${offline.formatBytes(free)} more is available to this browser.`
    text += ` Your account can keep up to ${offline.formatBytes(offline.ACCOUNT_LIMIT_BYTES)} here.`
    this.usageTarget.textContent = text
    this.persistenceTarget.textContent = offline.persistenceNote(persisted)
    this.storageTarget.hidden = records.length === 0
    const others = await offline.otherAccounts(this.deployment, this.account)
    this.othersTarget.hidden = this.removeOthersTarget.hidden = !this.online || others.count === 0
    this.othersTarget.textContent = others.count ? `Downloads from another account on this browser use ${offline.formatBytes(others.bytes)}. They stay hidden from you.` : ""
    this.removeAllTarget.hidden = !this.online || records.length === 0
    this.footerTarget.hidden = this.removeAllTarget.hidden && this.othersTarget.hidden
  }

  row(record, state) {
    const offline = this.offline
    const publication = record.publication || record.pending
    const item = element("li", "consumer-download")
    item.dataset.offlineKey = record.key
    item.dataset.offlineState = record.latest && state.kind === "ready" ? "update" : state.kind
    const cover = element("div", `consumer-cover consumer-cover--${publication.cover_style || "stone"} consumer-download__cover`)
    cover.setAttribute("aria-hidden", "true")
    cover.append(element("span", "consumer-cover-title", publication.title))
    const body = element("div", "consumer-download__body")
    body.append(element("span", "consumer-format", publication.book_type === "audiobook" ? "Audiobook" : "Ebook"))
    const title = element("h2", "consumer-download__title")
    if (record.publication) {
      const link = element("a", null, publication.title)
      link.href = `${this.baseValue}/read/${encodeURIComponent(record.id)}`
      title.append(link)
    } else title.textContent = publication.title
    body.append(title)
    if (publication.author) body.append(element("p", "consumer-download__author", publication.author))
    const status = element("p", "consumer-download__state", this.describe(record, state))
    status.setAttribute("role", "status")
    body.append(status)
    if (state.kind === "downloading" || ((state.kind === "paused" || state.kind === "failed") && state.done > 0)) {
      const bar = element("progress", "consumer-offline__progress")
      bar.max = 1
      bar.value = state.total && Number.isFinite(state.done) ? state.done / state.total : 0
      bar.setAttribute("aria-label", `${publication.title} download progress`)
      body.append(bar)
    }
    const note = this.note(record, state)
    if (note) body.append(element("p", "consumer-download__note", note))
    const actions = element("div", "consumer-download__actions")
    if (record.publication) {
      const open = element("a", "consumer-offline__button", publication.book_type === "audiobook" ? "Listen" : "Read")
      open.href = `${this.baseValue}/read/${encodeURIComponent(record.id)}`
      open.setAttribute("aria-label", `${open.textContent}: ${publication.title}`)
      actions.append(open)
    }
    if (this.online) {
      if (state.kind === "paused" || state.kind === "failed") actions.append(this.action(state.kind === "paused" ? "Resume" : "Try again", "resume", record, publication))
      if (state.kind === "ready" && record.latest) actions.append(this.action("Update", "update", record, publication))
      if (state.kind === "downloading" || state.kind === "paused" || state.kind === "failed") actions.append(this.action("Cancel", "cancel", record, publication, true))
      if (state.kind === "ready") actions.append(this.action(this.confirming === record.key ? "Remove from this device?" : "Remove", "remove", record, publication, true))
    }
    body.append(actions)
    item.append(cover, body)
    return item
  }

  describe(record, state) {
    const offline = this.offline
    const percent = state.total ? Math.floor(state.done / state.total * 100) : 0
    const files = state.files > 1 ? ` · ${state.filesDone} of ${state.files} files` : ""
    switch (state.kind) {
      case "downloading": return `${state.update ? "Updating" : "Downloading"} · ${percent}% of ${offline.formatBytes(state.total)}${files}`
      case "paused": return `Paused at ${percent}% of ${offline.formatBytes(state.total)}${files}`
      case "failed": return `Download stopped${files}`
      case "ready": return `Available offline · ${offline.formatBytes(state.total)}`
      default: return ""
    }
  }

  note(record, state) {
    if (this.confirming === record.key) return "Select again to remove the download. Your saved place is kept."
    const notes = []
    if ((state.kind === "paused" || state.kind === "failed") && state.error?.message) notes.push(state.error.message)
    if (state.update && state.kind !== "ready") notes.push("The previous download is still available.")
    if (record.latest && state.kind === "ready") notes.push("The server has a newer edition.")
    if (record.gone) notes.push("This book is no longer in the library. The download stays here until you remove it.")
    return notes.join(" ")
  }

  action(label, name, record, publication, quiet = false) {
    const button = element("button", `consumer-offline__button${quiet ? " consumer-offline__button--quiet" : ""}`, label)
    button.type = "button"
    button.setAttribute("aria-label", `${label}: ${publication.title}`)
    button.addEventListener("click", () => this.perform(name, record, button))
    return button
  }

  async perform(name, record, button) {
    const offline = this.offline
    if (name === "remove" && this.confirming !== record.key) {
      this.confirming = record.key
      clearTimeout(this.confirmTimer)
      this.confirmTimer = setTimeout(() => { this.confirming = null; this.render() }, 6000)
      await this.render()
      this.listTarget.querySelector(`[data-offline-key="${CSS.escape(record.key)}"] .consumer-offline__button--quiet:last-child`)?.focus()
      return
    }
    button.disabled = true
    try {
      if (name === "resume") {
        offline.requestPersistence()
        await offline.resume(record.key)
      }
      if (name === "update") { offline.requestPersistence(); await offline.download(record.latest) }
      if (name === "cancel") await offline.cancel(record.key)
      if (name === "remove") { this.confirming = null; await offline.remove(record.key) }
    } catch (error) {
      button.disabled = false
      const row = this.listTarget.querySelector(`[data-offline-key="${CSS.escape(record.key)}"] .consumer-download__state`)
      if (row) row.textContent = error?.message || offline.MESSAGES.storage
      return
    }
    await this.render()
  }

  renderProgress(detail) {
    const state = this.states?.get(detail?.key)
    if (!state || state.kind !== "downloading" || !Number.isFinite(detail.received)) return
    const row = this.listTarget.querySelector(`[data-offline-key="${CSS.escape(detail.key)}"]`)
    if (!row) return
    const done = Math.min(state.total, state.done + detail.received)
    const bar = row.querySelector("progress")
    if (bar) bar.value = state.total ? done / state.total : 0
    const text = row.querySelector(".consumer-download__state")
    if (text) text.textContent = this.describe(null, { ...state, done })
  }

  async removeAll() {
    if (!this.confirmAll) {
      this.confirmAll = true
      this.removeAllTarget.textContent = "Remove all downloads from this device?"
      setTimeout(() => { this.confirmAll = false; if (this.active) this.removeAllTarget.textContent = "Remove all my downloads" }, 6000)
      return
    }
    this.confirmAll = false
    this.removeAllTarget.textContent = "Remove all my downloads"
    await this.offline.removeAll(this.downloadScope)
    await this.render()
  }

  async removeOthers() {
    if (!this.confirmOthers) {
      this.confirmOthers = true
      this.removeOthersTarget.textContent = "Remove the other account's downloads?"
      setTimeout(() => { this.confirmOthers = false; if (this.active) this.removeOthersTarget.textContent = "Remove other accounts' downloads" }, 6000)
      return
    }
    this.confirmOthers = false
    this.removeOthersTarget.textContent = "Remove other accounts' downloads"
    await this.offline.removeOtherAccounts(this.deployment, this.account)
    await this.render()
  }

  showEmpty() {
    this.listTarget.replaceChildren()
    this.emptyTarget.hidden = false
    this.storageTarget.hidden = true
    this.footerTarget.hidden = true
  }

  unsupported(text) {
    this.unsupportedTarget.hidden = false
    this.unsupportedTarget.textContent = text
    this.emptyTarget.hidden = true
    this.storageTarget.hidden = true
  }
}

function element(tag, className, text) {
  const node = document.createElement(tag)
  if (className) node.className = className
  if (text !== undefined) node.textContent = text
  return node
}
