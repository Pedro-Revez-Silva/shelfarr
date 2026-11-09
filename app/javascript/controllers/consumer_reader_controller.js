import { Controller } from "@hotwired/stimulus"
import ConsumerProgressSync, { ListeningCheckpoints } from "consumer_progress_sync"

const STATUS = {
  saved: ["Your place is saved to your account", false, false],
  local: ["Saved on this device. Syncing to your account…", false, false],
  syncing: ["Saving to your account…", false, false],
  offline: ["Saved on this device. It will sync when you're back online.", true, true],
  signin: ["Saved on this device. Sign in again to sync it to your account.", true, true],
  reload: ["Saved on this device. Reload the page to sync it to your account.", true, true],
  rejected: ["Your account didn't accept this place. It is kept on this device.", true, true],
  storage: ["This browser isn't keeping your place. Keep this page open until it says saved.", true, true],
  conflict: ["Choose which place to keep.", false, true]
}

export default class extends Controller {
  static targets = ["publication", "syncStatus", "retry", "conflict", "conflictMessage", "error", "viewport", "chapters", "location", "audio", "tracks", "trackTitle", "seek", "elapsed", "duration", "play", "speed", "controls", "reveal", "hide", "notice", "remote"]

  connect() {
    this.publication = JSON.parse(this.publicationTarget.textContent)
    this.active = true
    if (!this.publication.assets.length) return
    let preferences = {}
    try { preferences = JSON.parse(localStorage.getItem("shelfarr.reader.preferences.v1") || "{}") || {} } catch (_) { /* storage unavailable */ }
    this.fontSize = Number.isFinite(preferences.fontSize) && preferences.fontSize >= 80 && preferences.fontSize <= 180 ? preferences.fontSize : 105
    this.playbackRate = Number.isFinite(preferences.playbackRate) && preferences.playbackRate >= 0.5 && preferences.playbackRate <= 3 ? preferences.playbackRate : 1
    this.readerReflow = Promise.resolve()
    if (this.hasSpeedTarget) {
      if (![...this.speedTarget.options].some(option => Number(option.value) === this.playbackRate)) this.playbackRate = 1
      this.speedTarget.value = String(this.playbackRate)
    }
    const server = this.publication.progress
    const scope = this.publication.progress_scope || {}
    this.sync = new ConsumerProgressSync({
      url: this.publication.progress_url, account: scope.account, base: scope.base || "", publication: this.publication.id,
      version: server?.version, assets: this.publication.assets.map(asset => asset.id),
      onStatus: (kind, detail) => this.showSyncStatus(kind, detail),
      onConflict: remote => this.showConflict(remote),
      onRemote: remote => this.remoteArrived(remote),
      onServerProgress: progress => this.element.dispatchEvent(new CustomEvent("consumer-reader:server-progress", { detail: progress }))
    })
    this.checkpoints = new ListeningCheckpoints({ record: place => this.recordPlace(place) })
    this.visibilityHandler = () => { if (document.hidden) this.leave(); else if (this.sync.waiting) this.sync.flush() }
    this.pageHandler = () => this.leave()
    document.addEventListener("visibilitychange", this.visibilityHandler)
    window.addEventListener("pagehide", this.pageHandler)

    // A checkpoint still waiting in this browser can be newer than the server.
    const restored = this.sync.restorePlace(server)
    const place = restored?.progress
    this.assetIndex = Math.max(0, this.publication.assets.findIndex(asset => asset.id === place?.asset_id))
    this.initialProgress = place?.asset_id === this.currentAsset.id ? place : null
    if (server && !this.initialProgress && !this.publication.assets.some(asset => asset.id === server.asset_id)) this.showSyncStatus("message", "The file changed. This edition starts afresh.")
    else if (restored?.source === "local") this.showSyncStatus("local")
    if (!this.sync.durable) this.showSyncStatus("storage")
    if (this.sync.conflict) this.showConflict(this.sync.conflict.remote)
    else if (this.sync.waiting) this.sync.flush()
    if (this.publication.book_type === "ebook") this.openEbook()
    else this.openAudio(false)
  }

  disconnect() {
    this.leave()
    this.active = false
    this.sync?.close()
    this.abort?.abort()
    this.statusAbort?.abort()
    clearTimeout(this.tapTimer)
    this.book?.destroy()
    if (this.hasAudioTarget) {
      this.audioTarget.pause()
      this.audioTarget.removeAttribute("src")
      this.audioTarget.load()
    }
    if ("mediaSession" in navigator) {
      navigator.mediaSession.metadata = null
      for (const action of ["play", "pause", "seekbackward", "seekforward", "previoustrack", "nexttrack"]) {
        try { navigator.mediaSession.setActionHandler(action, null) } catch (_) { /* unsupported browser action */ }
      }
    }
    document.removeEventListener("visibilitychange", this.visibilityHandler)
    window.removeEventListener("pagehide", this.pageHandler)
  }

  get currentAsset() { return this.publication.assets[this.assetIndex] }

  assetURL() {
    const url = new URL(this.currentAsset.content_url, window.location.href)
    if (url.origin !== window.location.origin) throw new Error("Invalid media origin")
    return url.href
  }

  // Progress -----------------------------------------------------------------

  // Every genuine checkpoint goes to this browser's outbox first.
  recordPlace(place) {
    this.sessionMoved = true
    this.remotePending = null
    if (this.hasRemoteTarget) this.remoteTarget.hidden = true
    this.sync.record(place)
  }

  // Leaving or hiding the page saves the current place at once.
  leave() {
    if (!this.sync) return
    if (this.hasAudioTarget && this.audioReady) this.checkpoints.settle(this.audioTarget.currentTime, this.currentAsset.id)
    this.sync.flush()
  }

  showSyncStatus(kind, detail) {
    if (!this.active) return
    // The offline shell has no form token until it confirms the account back
    // online, and then syncs by itself; a refused write meanwhile is not a
    // reason to reload.
    if (kind === "reload" && this.publication.offline?.opened && !document.querySelector('meta[name="csrf-token"]')?.content) kind = "offline"
    const [message, retry, notice] = kind === "message" ? [detail, false, true] : STATUS[kind] || STATUS.offline
    const text = kind === "rejected" && detail ? `${message} ${detail}` : message
    if (this.hasSyncStatusTarget) this.syncStatusTarget.textContent = text
    if (this.hasRetryTarget) this.retryTarget.hidden = !retry
    if (this.hasNoticeTarget && kind !== "syncing") {
      this.noticeTarget.hidden = !notice || kind === "conflict"
      this.noticeTarget.textContent = notice ? text : ""
    }
  }

  showConflict(remote) {
    if (!this.active) return
    const describe = progress => {
      if (!progress) return "no saved place"
      if (Number.isFinite(progress.position_seconds)) return this.time(progress.position_seconds)
      const total = progress.locator?.locations?.totalProgression
      return Number.isFinite(total) ? `${Math.round(total * 100)}% through` : "a different place"
    }
    const local = this.sync.restorePlace(null)?.progress
    this.conflictMessageTarget.textContent = `Another device saved a different place (${describe(remote)}; this device: ${describe(local)}). Which place would you like to keep?`
    this.conflictTarget.hidden = false
  }

  // A later place from another device. Move there only at a safe point: now
  // if this visit has not moved yet, otherwise when the reader asks or the
  // listener resumes playback.
  remoteArrived(remote) {
    if (!this.active || !remote || !this.publication.assets.some(asset => asset.id === remote.asset_id)) return
    const playing = this.hasAudioTarget && !this.audioTarget.paused
    if (!this.sessionMoved && !playing) return this.applyPlace(remote)
    if (playing) { this.remotePending = remote; return }
    this.remotePending = remote
    if (this.hasRemoteTarget) this.remoteTarget.hidden = false
  }

  goToRemote() {
    const remote = this.remotePending
    this.remotePending = null
    if (this.hasRemoteTarget) this.remoteTarget.hidden = true
    if (remote) this.applyPlace(remote)
  }

  applyPlace(progress) {
    if (this.publication.book_type === "ebook") {
      if (!this.readerReady) { this.deferredPlace = progress; return }
      this.userMoved = false
      const locator = progress.locator
      const target = locator?.locations?.cfi || (locator?.href ? this.book.path.relative(`/${locator.href.replace(/^\/+/, "")}`) : undefined)
      if (target) this.showPlace(target).catch(() => this.showError("Couldn't open the other device's place."))
      return
    }
    const index = this.publication.assets.findIndex(asset => asset.id === progress.asset_id)
    if (index < 0) return
    if (index !== this.assetIndex) {
      this.assetIndex = index
      this.initialProgress = progress
      this.openAudio(false)
    } else if (this.audioReady) {
      this.audioTarget.currentTime = Math.min(progress.position_seconds || 0, this.audioTarget.duration || 0)
      this.checkpoints.restored(this.audioTarget.currentTime, this.currentAsset.id)
      this.renderAudioPosition()
    } else this.initialProgress = progress
  }

  // The offline shell reconnected and fetched the account's saved place. Treat
  // it like a later place from another device, unless this browser already
  // holds that version or a newer local place.
  serverProgressRefreshed(progress) {
    if (!this.active || !this.sync || !progress || !Number.isInteger(progress.version)) return
    const known = Math.max(this.publication.progress?.version || 0, this.sync.serverVersion || 0)
    if (progress.version > known && this.sync.restorePlace(progress)?.source === "server") {
      this.publication.progress = progress
      this.remoteArrived(progress)
    }
    if (this.sync.waiting) this.sync.flush()
  }

  retrySync() { this.sync?.retry() }
  useServerProgress() { this.sync.useRemote(); window.location.reload() }
  keepLocalProgress() { this.conflictTarget.hidden = true; this.sync.keepLocal() }

  // Ebook --------------------------------------------------------------------

  async openEbook() {
    try {
      if (this.currentAsset.size_bytes > 32 * 1024 * 1024) throw new Error("This ebook is larger than the web preview's 32 MiB limit. Use the native reader or download the file.")
      this.abort = new AbortController()
      const [{ ePub, DOMPurify }, response] = await Promise.all([
        import("consumer_reader_engine"), fetch(this.assetURL(), { credentials: "same-origin", redirect: "error", signal: this.abort.signal })
      ])
      if (!response.ok) throw new Error("This ebook is unavailable. Refresh the publication or sign in again.")
      const buffer = await response.arrayBuffer()
      if (!this.active) return
      this.book = ePub(undefined, { replacements: "blobUrl" })
      const sanitize = (html, section) => {
        const clean = DOMPurify.sanitize(html, {
          WHOLE_DOCUMENT: true, SANITIZE_NAMED_PROPS: true,
          FORBID_TAGS: ["script", "iframe", "frame", "form", "input", "button", "object", "embed", "base", "meta", "audio", "video", "source"],
          FORBID_ATTR: ["srcset", "action", "formaction"]
        })
        const document = new DOMParser().parseFromString(clean, "text/html")
        for (const link of document.querySelectorAll("[href]")) {
          const href = link.getAttribute("href") || ""
          if (/^(?:https?:|javascript:|file:|data:|\/\/)/i.test(href)) link.removeAttribute("href")
        }
        const policy = document.createElement("meta")
        policy.httpEquiv = "Content-Security-Policy"
        policy.content = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline' blob:; img-src data: blob:; font-src data: blob:; connect-src 'none'; form-action 'none'; base-uri 'self'"
        // EPUB.js resolves internal anchors from the section's base URI. Source
        // bases are stripped; only this derived same-origin archive path is used.
        const base = document.createElement("base")
        base.href = new URL(`/${this.book.resolve(section.href).replace(/^\/+/, "")}`, window.location.origin).href
        document.head.prepend(base)
        document.head.prepend(policy)
        return document.documentElement.outerHTML
      }
      await this.book.open(buffer)
      // Sanitize the final serialized result, after EPUB.js's resource hooks.
      // Its hooks receive the original string and can overwrite earlier edits.
      for (const section of this.book.spine.spineItems) {
        const render = section.render.bind(section)
        section.render = async (...args) => {
          section.output = sanitize(await render(...args), section)
          return section.output
        }
      }
      if (!this.active) return
      this.viewportTarget.replaceChildren()
      this.rendition = this.book.renderTo(this.viewportTarget, { width: "100%", height: "100%", spread: "none", allowScriptedContent: false, allowPopups: false })
      const colors = getComputedStyle(document.body)
      this.rendition.themes.default({ body: { color: `${colors.getPropertyValue("--ink")} !important`, background: `${colors.getPropertyValue("--surface")} !important`, "font-family": "Georgia, serif !important", "line-height": "1.7 !important" }, "a": { color: "inherit" } })
      this.rendition.themes.fontSize(`${this.fontSize}%`)
      this.rendition.on("relocated", location => this.ebookPosition(location))
      this.rendition.on("resized", () => this.reflowed())
      this.rendition.hooks.content.register(contents => this.bookInput(contents))
      this.chaptersTarget.replaceChildren()
      const addChapters = (items, depth = 0) => {
        for (const item of items) {
          const option = document.createElement("option")
          option.value = item.href
          option.textContent = `${"— ".repeat(depth)}${item.label.trim()}`
          this.chaptersTarget.append(option)
          addChapters(item.subitems || [], depth + 1)
        }
      }
      addChapters((await this.book.loaded.navigation).toc)
      const locator = this.initialProgress?.locator
      const relativeHref = locator?.href ? this.book.path.relative(`/${locator.href.replace(/^\/+/, "")}`) : undefined
      await this.showPlace(locator?.locations?.cfi || relativeHref)
      if (locator && !locator.locations?.cfi && locator.locations?.progression > 0) {
        const contents = this.rendition.getContents()[0]
        if (contents) {
          const walker = contents.document.createTreeWalker(contents.document.body, NodeFilter.SHOW_TEXT)
          const nodes = []
          while (walker.nextNode()) if (walker.currentNode.textContent.length) nodes.push(walker.currentNode)
          let offset = Math.floor(nodes.reduce((length, node) => length + node.textContent.length, 0) * Math.min(1, locator.locations.progression))
          for (const node of nodes) {
            if (offset <= node.textContent.length) {
              const range = contents.document.createRange()
              range.setStart(node, offset)
              range.collapse(true)
              await this.showPlace(contents.cfiFromRange(range))
              break
            }
            offset -= node.textContent.length
          }
        }
      }
      this.lastEbookCfi = this.rendition.currentLocation()?.start?.cfi
      this.readerReady = true
      if (this.deferredPlace) { const place = this.deferredPlace; this.deferredPlace = null; this.applyPlace(place) }
    } catch (error) {
      if (error.name !== "AbortError" && this.active) {
        this.showError(error.message || "This EPUB couldn't be opened.")
        if (this.hasControlsTarget) this.showControls()
      }
    }
  }

  // EPUB.js 0.3.93 measures a target after the theme and text size reach a
  // newly rendered section, but clamps the page offset to the frame width it
  // measured before they did. The frame grows a moment later and nothing moves
  // back, so a place deep in a long chapter opened pages early. Size the frame
  // to its laid-out text once fonts settle, then position again within the
  // section, which is now shown at its final width.
  async showPlace(target) {
    await this.rendition.display(target)
    if (!target || !this.active) return
    await this.settleFrames()
    if (this.active) await this.rendition.display(target)
  }

  // A window or orientation change re-renders the section the same way. EPUB.js
  // queues its own display of the place right after this event; settle after
  // it. The first place is kept through a burst of resizes.
  reflowed() {
    if (!this.readerReady) return
    const cfi = this.reflowAnchor || this.rendition.location?.start?.cfi
    if (!cfi) return
    this.reflowAnchor = cfi
    this.userMoved = false
    const reflow = this.readerReflow.then(() => this.active && this.showPlace(cfi))
      .catch(() => {})
      .finally(() => { if (this.readerReflow === reflow) this.reflowAnchor = null })
    this.readerReflow = reflow
  }

  async settleFrames() {
    for (const view of this.rendition.views().all?.() || []) {
      view.expand?.()
      await view.contents?.document?.fonts?.ready
      view.expand?.()
    }
  }

  // Keyboard, tap and swipe inside the sandboxed book frame. Side taps turn
  // pages, the middle reveals controls, and selecting text does neither.
  bookInput(contents) {
    const doc = contents.document
    const frame = contents.window.frameElement
    doc.addEventListener("keydown", event => this.readerKey(event))
    // EPUB.js installs onclick handlers for internal links. Keep its URL
    // resolution, but wait for any layout correction before following one.
    for (const link of doc.querySelectorAll("a[href]")) {
      const follow = link.onclick
      if (!follow) continue
      link.onclick = event => {
        this.moveEbook(() => follow.call(link, event), "This link couldn't be opened.")
        return false
      }
    }
    doc.addEventListener("click", event => {
      if (event.target.closest?.("a[href]")) return
      if (this.swiped) { this.swiped = false; return }
      const selection = contents.window.getSelection?.()
      if (selection && !selection.isCollapsed) return
      if (!this.controlsTarget.hidden) return this.hideControls()
      const bounds = this.viewportTarget.getBoundingClientRect()
      const x = (frame?.getBoundingClientRect().left || 0) + event.clientX - bounds.left
      const zone = x / Math.max(1, bounds.width)
      if (zone < 0.3) return this.previousPage()
      if (zone > 0.7) return this.nextPage()
      clearTimeout(this.tapTimer)
      this.tapTimer = setTimeout(() => {
        const current = contents.window.getSelection?.()
        if (this.active && (!current || current.isCollapsed)) this.showControls()
      }, 250)
    })
    doc.addEventListener("dblclick", () => clearTimeout(this.tapTimer))
    doc.addEventListener("touchstart", event => {
      const touch = event.changedTouches[0]
      this.touchStart = touch ? { x: touch.clientX, y: touch.clientY } : null
    }, { passive: true })
    doc.addEventListener("touchend", event => {
      const touch = event.changedTouches[0]
      const start = this.touchStart
      this.touchStart = null
      if (!touch || !start) return
      const dx = touch.clientX - start.x, dy = touch.clientY - start.y
      const selection = contents.window.getSelection?.()
      if (Math.abs(dx) < 48 || Math.abs(dx) < Math.abs(dy) * 1.5 || (selection && !selection.isCollapsed)) return
      this.swiped = true
      setTimeout(() => { this.swiped = false }, 400)
      dx < 0 ? this.nextPage() : this.previousPage()
    }, { passive: true })
  }

  // Taps in the page margins, outside the text column.
  marginTap(event) {
    if (this.viewportTarget.contains(event.target)) return
    if (!this.controlsTarget.hidden) return this.hideControls()
    const bounds = event.currentTarget.getBoundingClientRect()
    const zone = (event.clientX - bounds.left) / Math.max(1, bounds.width)
    if (zone < 0.3) this.previousPage()
    else if (zone > 0.7) this.nextPage()
    else this.showControls()
  }

  readerKey(event) {
    if (!this.hasControlsTarget) return
    if (event.key === "Escape") {
      event.preventDefault()
      this.controlsTarget.hidden ? this.showControls() : this.hideControls()
      return
    }
    if (event.target.closest?.("select, input, textarea")) return
    if (event.key === "ArrowRight" || event.key === "PageDown") { event.preventDefault(); this.nextPage() }
    if (event.key === "ArrowLeft" || event.key === "PageUp") { event.preventDefault(); this.previousPage() }
  }

  // Controls overlay the text, so revealing them never reflows the book.
  showControls() {
    if (!this.hasControlsTarget || !this.controlsTarget.hidden) return
    this.controlsTarget.hidden = false
    this.revealTarget.setAttribute("aria-expanded", "true")
    this.hideTarget.focus()
  }

  hideControls() {
    if (!this.hasControlsTarget || this.controlsTarget.hidden) return
    const hadFocus = this.controlsTarget.contains(document.activeElement)
    this.controlsTarget.hidden = true
    this.revealTarget.setAttribute("aria-expanded", "false")
    if (hadFocus || document.activeElement === document.body) this.viewportTarget.focus({ preventScroll: true })
  }

  ebookPosition(location) {
    if (!this.active) return
    const start = location.start
    const fraction = Math.max(0, (start.displayed.page - 1) / Math.max(1, start.displayed.total))
    const total = Math.min(1, (start.index + fraction) / Math.max(1, this.book.spine.length))
    this.locationTarget.textContent = `${start.displayed.page} / ${start.displayed.total} · chapter ${start.index + 1}`
    const option = [...this.chaptersTarget.options].find(option => option.value.split("#")[0] === start.href)
    if (option) this.chaptersTarget.value = option.value
    // Only the reader's own moves are activity; restoring or reflowing is not.
    if (!this.readerReady) return
    if (!this.userMoved) { this.lastEbookCfi = start.cfi; return }
    if (start.cfi === this.lastEbookCfi) return
    this.lastEbookCfi = start.cfi
    this.recordPlace({ asset_id: this.currentAsset.id, locator: { href: this.book.resolve(start.href).replace(/^\/+/, ""), type: "application/xhtml+xml", locations: { progression: fraction, totalProgression: total, cfi: start.cfi } } })
  }

  async saveReadingStatus(event) {
    event.preventDefault()
    const form = event.currentTarget
    const select = form.querySelector("select[name=status]")
    const submit = form.querySelector("input[type=submit]")
    const feedback = form.querySelector("[role=status]")
    const status = select.value
    select.disabled = submit.disabled = true
    feedback.textContent = "Saving status…"
    this.statusAbort = new AbortController()
    try {
      const response = await fetch(form.action, { method: "PUT", credentials: "same-origin", signal: this.statusAbort.signal,
        headers: { "Content-Type": "application/json", "Accept": "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "" },
        body: JSON.stringify({ status }) })
      if (!response.ok || response.redirected) throw new Error("Status couldn't be saved. Check your connection or sign in again.")
      const publication = await response.json()
      if (!this.active) return
      this.publication.reading_status = publication.reading_status
      select.value = publication.reading_status
      feedback.textContent = "Reading status saved. Your saved place is kept."
    } catch (error) {
      if (error.name !== "AbortError" && this.active) feedback.textContent = error.message || "Status couldn't be saved. Try again."
    } finally {
      if (this.active) select.disabled = submit.disabled = false
    }
  }

  // Automatic reflows stay silent until the next deliberate navigation. The
  // engine's reportLocation promise resolves before its animation-frame report;
  // take a fresh baseline so a trailing report cannot become reading activity.
  async moveEbook(move, message) {
    try {
      let reflow
      do { reflow = this.readerReflow; await reflow } while (reflow !== this.readerReflow)
      if (!this.active || !this.readerReady) return
      this.lastEbookCfi = this.rendition.currentLocation()?.start?.cfi
      this.userMoved = true
      await move()
    } catch (_) { if (this.active) this.showError(message) }
  }

  previousPage() { this.moveEbook(() => this.rendition.prev(), "Couldn't open the previous page.") }
  nextPage() { this.moveEbook(() => this.rendition.next(), "Couldn't open the next page.") }
  chooseChapter() {
    const chapter = this.chaptersTarget.value
    this.moveEbook(() => this.showPlace(chapter), "This chapter couldn't be opened.")
  }
  smallerText() { this.resizeText(-10) }
  largerText() { this.resizeText(10) }
  resizeText(delta) {
    const reflow = this.readerReflow.then(async () => {
      if (!this.active || !this.rendition || !this.readerReady) return
      this.userMoved = false
      const cfi = this.reflowAnchor || this.rendition.currentLocation()?.start?.cfi
      this.fontSize = Math.max(80, Math.min(180, this.fontSize + delta))
      this.savePreferences()
      this.rendition.themes.fontSize(`${this.fontSize}%`)
      await this.settleFrames()
      if (!this.active) return
      if (cfi) await this.rendition.display(cfi)
      await this.rendition.reportLocation()
    }).catch(() => { if (this.active) this.showError("Text size couldn't be changed. Try again.") })
      .finally(() => { if (this.readerReflow === reflow) this.reflowAnchor = null })
    this.readerReflow = reflow
  }
  savePreferences() {
    try { localStorage.setItem("shelfarr.reader.preferences.v1", JSON.stringify({ fontSize: this.fontSize, playbackRate: this.playbackRate })) } catch (_) { /* keep preferences for this visit */ }
  }

  // Audio --------------------------------------------------------------------

  openAudio(autoplay) {
    this.audioReady = false
    this.switching = true
    this.trackTitleTarget.textContent = this.currentAsset.filename
    this.tracksTarget.value = this.assetIndex
    this.audioTarget.src = this.assetURL()
    this.audioTarget.defaultPlaybackRate = this.playbackRate
    this.audioTarget.playbackRate = this.playbackRate
    this.audioTarget.load()
    this.playWhenReady = autoplay
    if ("mediaSession" in navigator) {
      navigator.mediaSession.metadata = new MediaMetadata({ title: this.publication.title, artist: this.publication.author || "", album: this.currentAsset.filename })
      for (const [action, handler] of Object.entries({ play: () => this.playAudio(), pause: () => this.audioTarget.pause(), seekbackward: () => this.backwardAudio(), seekforward: () => this.forwardAudio(), previoustrack: () => this.chooseAudioTrack(Math.max(0, this.assetIndex - 1)), nexttrack: () => this.skipTrack() })) {
        try { navigator.mediaSession.setActionHandler(action, handler) } catch (_) { /* unsupported browser action */ }
      }
    }
  }

  audioLoaded() {
    if (this.initialProgress) {
      this.audioTarget.currentTime = Math.min(this.initialProgress.position_seconds || 0, this.audioTarget.duration || 0)
      this.initialProgress = null
    }
    this.checkpoints.restored(this.audioTarget.currentTime, this.currentAsset.id)
    this.audioReady = true
    this.switching = false
    this.durationTarget.textContent = this.time(this.audioTarget.duration)
    this.renderAudioPosition()
    if (this.playWhenReady) this.playAudio({ resume: false })
  }

  // timeupdate: the display follows every update; storage only every few seconds.
  audioPosition() {
    if (!this.active || !this.audioReady) return
    this.renderAudioPosition()
    if (!this.audioTarget.paused) this.checkpoints.tick(this.audioTarget.currentTime, this.currentAsset.id)
  }

  renderAudioPosition() {
    const audio = this.audioTarget
    this.elapsedTarget.textContent = this.time(audio.currentTime)
    this.seekTarget.value = Number.isFinite(audio.duration) && audio.duration > 0 ? audio.currentTime / audio.duration * 100 : 0
  }

  audioPaused() {
    if (!this.active) return
    this.playTarget.textContent = "▶"
    this.playTarget.setAttribute("aria-label", "Play audiobook")
    if (this.switching || !this.audioReady) return
    this.checkpoints.settle(this.audioTarget.currentTime, this.currentAsset.id)
    this.sync.flush()
  }

  // A genuine resume (Play after a pause or after opening a saved place)
  // rewinds five seconds once; choosing a track or a natural transition does not.
  async playAudio({ resume = true } = {}) {
    const audio = this.audioTarget
    try {
      if (resume && audio.paused && !audio.ended && this.audioReady) {
        if (this.remotePending) { const remote = this.remotePending; this.remotePending = null; this.applyPlace(remote) }
        const from = this.checkpoints.resume(audio.currentTime)
        if (from !== audio.currentTime) audio.currentTime = from
      } else this.checkpoints.active = true
      await audio.play()
      this.playTarget.textContent = "Ⅱ"
      this.playTarget.setAttribute("aria-label", "Pause audiobook")
    } catch (_) { this.showError("Playback couldn't start. Check your connection and try Play again.") }
  }
  toggleAudio() { this.audioTarget.paused ? this.playAudio() : this.audioTarget.pause() }
  seekAudio() {
    if (!Number.isFinite(this.audioTarget.duration)) return
    this.audioTarget.currentTime = this.audioTarget.duration * Number(this.seekTarget.value) / 100
    this.renderAudioPosition()
  }
  seekCommitted() { this.seekAudio(); this.deliberateMove() }
  backwardAudio() { this.audioTarget.currentTime = Math.max(0, this.audioTarget.currentTime - 15); this.renderAudioPosition(); this.deliberateMove() }
  forwardAudio() { if (Number.isFinite(this.audioTarget.duration)) { this.audioTarget.currentTime = Math.min(this.audioTarget.duration, this.audioTarget.currentTime + 30); this.renderAudioPosition(); this.deliberateMove() } }
  deliberateMove() {
    if (!this.audioReady) return
    this.checkpoints.deliberate(this.audioTarget.currentTime, this.currentAsset.id, this.audioTarget.paused)
    this.sync.flush()
  }
  changeSpeed(event) {
    this.playbackRate = Number(event.target.value)
    this.audioTarget.defaultPlaybackRate = this.playbackRate
    this.audioTarget.playbackRate = this.playbackRate
    this.savePreferences()
  }
  chooseTrack() { this.chooseAudioTrack(Number(this.tracksTarget.value)) }
  chooseAudioTrack(index, autoplay = !this.audioTarget.paused) {
    if (this.audioReady) this.checkpoints.settle(this.audioTarget.currentTime, this.currentAsset.id)
    this.assetIndex = index
    this.initialProgress = null
    this.remotePending = null
    this.checkpoints.deliberate(0, this.currentAsset.id, !autoplay)
    this.sync.flush()
    this.openAudio(autoplay)
  }
  skipTrack() { if (this.assetIndex + 1 < this.publication.assets.length) this.chooseAudioTrack(this.assetIndex + 1) }
  nextTrack() {
    if (this.assetIndex + 1 >= this.publication.assets.length) return this.audioPaused()
    // A natural transition keeps playing from the start of the next track.
    this.assetIndex += 1
    this.initialProgress = null
    this.checkpoints.continued(this.currentAsset.id)
    this.sync.flush()
    this.openAudio(true)
  }
  audioError() { if (this.active) this.showError("This track couldn't be loaded. Check the connection, file format, or sign in again.") }
  showError(message) { if (this.hasErrorTarget) { this.errorTarget.textContent = message; this.errorTarget.hidden = false } }
  time(seconds) { if (!Number.isFinite(seconds)) return "—"; const value = Math.max(0, Math.floor(seconds)); return `${Math.floor(value / 60)}:${String(value % 60).padStart(2, "0")}` }
}
