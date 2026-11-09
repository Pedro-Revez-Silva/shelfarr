import { Controller } from "@hotwired/stimulus"

// The page the offline worker serves when the server can't be reached. It
// opens a downloaded book in the usual reader or player, or lists downloads,
// for the account this browser last confirmed. Back online, it asks the
// server who is signed in before any saved place is sent.
export default class extends Controller {
  static targets = ["intro", "heading", "message", "online", "onlineMessage", "library", "reader", "ebook", "audio"]
  static values = { base: String, accountUrl: String, publicationsUrl: String, signInUrl: String }

  async connect() {
    this.active = true
    this.offline = await import("consumer_offline")
    if (!this.active) return
    if (!this.offline.support().ok) return this.say("Downloads aren't available", this.offline.MESSAGES.unsupported)
    this.onlineHandler = () => this.reconnect()
    window.addEventListener("online", this.onlineHandler)
    const active = await this.offline.activeAccount(this.baseValue).catch(() => null)
    if (!active) return this.signedOut("Sign in to use downloads", "Downloads open only for the account that saved them on this browser. Connect to the internet and sign in.")
    if (active.expired) return this.signedOut("Sign in again", "It has been a while since this browser confirmed your account. Connect to the internet and sign in to keep using your downloads.")
    this.account = active.account
    this.downloadScope = this.offline.scopeOf(this.offline.deploymentOf(this.baseValue), this.account)
    const id = this.publicationId()
    if (id) await this.openPublication(id)
    else this.showLibrary()
    this.retryTimer = setTimeout(() => this.reconnect(), 1500)
  }

  disconnect() {
    this.active = false
    clearTimeout(this.retryTimer)
    clearTimeout(this.bannerTimer)
    window.removeEventListener("online", this.onlineHandler)
  }

  publicationId() {
    const path = window.location.pathname.slice(this.baseValue.length)
    return path.match(/^\/read\/([1-9]\d{0,18})\/?$/)?.[1] || null
  }

  say(heading, message) {
    this.headingTarget.textContent = heading
    this.messageTarget.textContent = message
  }

  signedOut(heading, message) {
    this.say(heading, message)
    this.libraryTarget.hidden = true
    this.readerTarget.replaceChildren()
    this.signIn ||= Object.assign(document.createElement("a"), { className: "consumer-button", href: this.signInUrlValue, textContent: "Sign in" })
    this.introTarget.append(this.signIn)
  }

  showLibrary(notice) {
    this.say("On this device.", notice || "You're offline. These downloads open without a connection, and your places sync when you're back.")
    this.libraryTarget.hidden = false
  }

  async openPublication(id) {
    const record = await this.offline.getRecord(this.offline.recordKey(this.downloadScope, id)).catch(() => null)
    const usable = record?.publication && await this.offline.verify(record).catch(() => false)
    if (!usable) {
      if (record?.publication) await this.offline.markEvicted(record).catch(() => {})
      return this.showLibrary("This book isn't available on this device. Downloads that are ready are listed below.")
    }
    this.mount(record.publication)
  }

  mount(publication) {
    const ebook = publication.book_type === "ebook"
    const fragment = (ebook ? this.ebookTarget : this.audioTarget).content.cloneNode(true)
    const fill = (name, apply) => fragment.querySelectorAll(`[data-offline-fill="${name}"]`).forEach(apply)
    fill("publication", node => { node.textContent = JSON.stringify({ ...publication, offline: { supported: true, opened: true } }) })
    fill("title", node => { node.textContent = publication.title })
    fill("author", node => { node.textContent = publication.author })
    fill("description", node => { node.textContent = publication.description })
    fill("label", node => node.setAttribute("aria-label", publication.title))
    fill("tracks", node => node.replaceChildren(...publication.assets.map((asset, index) => Object.assign(document.createElement("option"), { value: String(index), textContent: asset.filename }))))
    fill("cover", node => {
      node.classList.add(`consumer-cover--${publication.cover_style || "stone"}`)
      node.querySelector(".consumer-cover-title").textContent = publication.title
      node.querySelector(".consumer-cover-author").textContent = publication.author
    })
    const track = fragment.querySelector("[data-consumer-reader-target=trackTitle]")
    if (track) track.textContent = publication.assets[0]?.filename || ""
    document.title = `${publication.title} · Shelfarr`
    this.introTarget.hidden = true
    this.libraryTarget.hidden = true
    const main = this.element.closest("main")
    main?.classList.add("consumer-publication")
    if (ebook) {
      document.body.classList.add("consumer-app--reading")
      main?.classList.add("consumer-reading")
      document.querySelectorAll("[data-offline-chrome]").forEach(node => { node.hidden = true })
    }
    this.readerTarget.replaceChildren(fragment)
  }

  get reader() {
    const element = this.readerTarget.querySelector("[data-controller~='consumer-reader']")
    return element && this.application.getControllerForElementAndIdentifier(element, "consumer-reader")
  }

  // Ask who is signed in before anything is synced, then refresh the place.
  async reconnect() {
    clearTimeout(this.retryTimer)
    if (!this.active || !this.account) return
    let response, body
    try {
      response = await fetch(this.accountUrlValue, { credentials: "same-origin", headers: { Accept: "application/json" }, cache: "no-store", redirect: "manual" })
      body = response.ok ? await response.json() : null
    } catch (_) {
      this.retryTimer = setTimeout(() => this.reconnect(), 30_000)
      return
    }
    if (!this.active) return
    if (response.status === 401 || response.type === "opaqueredirect") {
      await this.offline.clearAccount(this.baseValue).catch(() => {})
      return this.banner("You're online, but signed out. Sign in to sync your place; it is kept on this device.", "Sign in", this.signInUrlValue, true)
    }
    if (!body?.account) { this.retryTimer = setTimeout(() => this.reconnect(), 30_000); return }
    if (String(body.account) !== this.account) {
      // Another account signed in here: this account's downloads stay hidden.
      await this.offline.confirmAccount({ base: this.baseValue, account: body.account, maxAgeDays: body.session_max_age_days }).catch(() => {})
      this.readerTarget.replaceChildren()
      window.location.reload()
      return
    }
    await this.offline.confirmAccount({ base: this.baseValue, account: body.account, maxAgeDays: body.session_max_age_days }).catch(() => {})
    const token = document.querySelector("meta[name='csrf-token']")
    if (token && typeof body.csrf_token === "string") token.content = body.csrf_token
    this.banner("You're back online.", "Open your full library", `${this.baseValue}/read`)
    document.querySelectorAll(".consumer-app--offline .consumer-preview").forEach(node => { node.textContent = "Online" })
    const id = this.publicationId()
    const reader = this.reader
    if (id && reader) {
      try {
        const latest = await fetch(`${this.publicationsUrlValue}?ids=${id}`, { credentials: "same-origin", headers: { Accept: "application/json" }, cache: "no-store", redirect: "manual" })
        const data = latest.ok ? await latest.json() : null
        const publication = String(data?.account) === this.account ? data.publications?.find(item => String(item.id) === id) : null
        if (publication?.progress) {
          await this.offline.rememberProgress(this.offline.recordKey(this.downloadScope, id), publication.progress, publication.reading_status).catch(() => {})
          reader.serverProgressRefreshed(publication.progress)
        } else reader.sync?.flush()
      } catch (_) { reader.sync?.flush() }
    }
  }

  // While reading, a passing notice must not stay over the text.
  banner(text, label, href, lasting = false) {
    clearTimeout(this.bannerTimer)
    this.onlineTarget.hidden = false
    this.onlineMessageTarget.textContent = text
    const link = this.onlineTarget.querySelector("a")
    link.textContent = label
    link.href = href
    if (!lasting && document.body.classList.contains("consumer-app--reading")) this.bannerTimer = setTimeout(() => { this.onlineTarget.hidden = true }, 8000)
  }
}
