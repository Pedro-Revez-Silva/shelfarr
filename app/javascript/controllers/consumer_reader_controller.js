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

const FORMAT_LABELS = { epub: "EPUB", pdf: "PDF", cbz: "Comic (CBZ)" }
const PAGE_FORMATS = new Set(["pdf", "cbz"])
const WEB_EBOOK_LIMIT = 32 * 1024 * 1024
const READ_ALONG_ACTIVE = "shelfarr-read-along-active"

export default class extends Controller {
  static targets = ["publication", "syncStatus", "retry", "conflict", "conflictMessage", "error", "viewport", "chapters", "location", "audio", "tracks", "trackTitle", "seek", "elapsed", "duration", "play", "speed", "controls", "reveal", "hide", "notice", "remote",
    "desktopNav", "desktopChapters", "desktopTextTools", "desktopReveal", "pdfResources", "textFrame", "pages", "announce", "editionPicker", "edition", "editionNote", "pageTools", "textTools", "pageNumber", "pageTotal", "pageSlider", "zoomLabel",
    "readAlong", "readAlongNote", "readAlongTools", "readAlongPlay", "readAlongFollow", "readAlongSpeed", "readAlongAudio", "readAlongPill", "readAlongPillPlay", "readAlongReturn", "readAlongOffer"]

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
    this.savedPlace = place || null
    const placeIndex = this.publication.assets.findIndex(asset => asset.id === place?.asset_id)
    this.assetIndex = placeIndex >= 0 ? placeIndex : this.preferredAsset()
    this.initialProgress = place?.asset_id === this.currentAsset.id ? place : null
    if (server && !this.initialProgress && !this.publication.assets.some(asset => asset.id === server.asset_id)) this.showSyncStatus("message", "The file changed. This edition starts afresh.")
    else if (restored?.source === "local") this.showSyncStatus("local")
    if (!this.sync.durable) this.showSyncStatus("storage")
    if (this.sync.conflict) this.showConflict(this.sync.conflict.remote)
    else if (this.sync.waiting) this.sync.flush()
    if (this.publication.book_type === "ebook") this.openReading()
    else this.openAudio(false)
  }

  // Without a saved place, open the format that suits the publication: comics
  // as pages, other books as text when there is an EPUB.
  preferredAsset() {
    if (this.publication.book_type !== "ebook") return 0
    const order = this.publication.content_kind === "graphic" ? ["cbz", "pdf", "epub"] : ["epub", "pdf", "cbz"]
    for (const format of order) {
      const index = this.publication.assets.findIndex(asset => asset.format === format)
      if (index >= 0) return index
    }
    return 0
  }

  get pageFormat() { return PAGE_FORMATS.has(this.currentAsset?.format) }

  disconnect() {
    this.leave()
    this.active = false
    this.sync?.close()
    this.abort?.abort()
    this.statusAbort?.abort()
    clearTimeout(this.tapTimer)
    this.closeReadAlong()
    this.book?.destroy()
    this.pageReader?.destroy()
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

  assetURL(path = this.currentAsset.content_url) {
    const url = new URL(path, window.location.href)
    if (url.origin !== window.location.origin) throw new Error("Invalid media origin")
    return url.href
  }

  // Progress -----------------------------------------------------------------

  // Every genuine checkpoint goes to this browser's outbox first.
  recordPlace(place, observedAt) {
    this.sessionMoved = true
    this.remotePending = null
    if (this.hasRemoteTarget) this.remoteTarget.hidden = true
    this.sync.record(place, observedAt)
  }

  // Leaving or hiding the page saves the current place at once.
  leave() {
    if (!this.sync) return
    if (this.hasAudioTarget && this.audioReady) this.checkpoints.settle(this.audioTarget.currentTime, this.currentAsset.id)
    this.readAlong?.session.settle()
    this.sync.flush()
    this.readAlong?.pairedSync?.flush()
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
      const page = progress.locator?.locations?.position
      if (/^(application\/pdf|image\/)/.test(progress.locator?.type || "") && Number.isInteger(page)) return `page ${page}`
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
    const playing = (this.hasAudioTarget && !this.audioTarget.paused) || Boolean(this.readAlong?.session.playing)
    if (!this.sessionMoved && !playing) return this.applyPlace(remote)
    if (playing) { this.remotePending = remote; return }
    this.remotePending = remote
    if (this.hasRemoteTarget) this.remoteTarget.hidden = false
  }

  async goToRemote() {
    const remote = this.remotePending
    if (!remote) return
    this.remotePending = null
    if (this.hasRemoteTarget) this.remoteTarget.hidden = true
    if (this.hasErrorTarget) this.errorTarget.hidden = true
    const applied = await this.applyPlace(remote)
    if (applied === false && this.active && !this.remotePending) {
      this.remotePending = remote
      if (this.hasRemoteTarget) this.remoteTarget.hidden = false
    }
    return applied
  }

  applyPlace(progress) {
    if (this.publication.book_type === "ebook") {
      const index = this.publication.assets.findIndex(asset => asset.id === progress.asset_id)
      if (index < 0) return
      // A place in another format of this book opens that format; one
      // format's place is never applied to another.
      if (index !== this.assetIndex) return this.switchAsset(index, progress)
      if (!this.readerReady) { this.deferredPlace = progress; return }
      if (this.pageReader) {
        const { position } = this.pageModule.restoredPage(this.currentAsset.format, progress.locator, this.pageReader.count, this.pageReader.items())
        return this.pageReader.show(position).catch(() => { this.showError("Couldn't open the other device's place."); return false })
      }
      this.userMoved = false
      return this.showLocator(progress.locator).then(() => this.readAlongRestored(progress.locator, progress.observed_at))
        .catch(() => { this.showError("Couldn't open the other device's place."); return false })
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

  // Reading formats ------------------------------------------------------------

  openReading() {
    this.renderEditions()
    this.pageMode(this.pageFormat)
    return this.pageFormat ? this.openPages() : this.openEbook()
  }

  // Text and page readers share the overlay; each shows only its own tools.
  pageMode(on) {
    if (this.hasTextFrameTarget) this.textFrameTarget.hidden = on
    if (this.hasPagesTarget) this.pagesTarget.hidden = !on
    if (this.hasPageToolsTarget) this.pageToolsTarget.hidden = !on
    if (this.hasTextToolsTarget) this.textToolsTarget.hidden = on
    if (this.hasDesktopTextToolsTarget) this.desktopTextToolsTarget.hidden = on
    this.element.classList.toggle("consumer-reading-session--pages", on)
  }

  get readingSurface() { return this.pageFormat && this.hasPagesTarget ? this.pagesTarget : this.viewportTarget }

  // Several formats of one book: choose one. The saved place belongs to one
  // file; another format opens at its beginning until a page is turned there.
  renderEditions() {
    if (!this.hasEditionTarget) return
    const assets = this.publication.assets
    this.editionPickerTarget.hidden = assets.length < 2
    const saved = this.savedPlace?.asset_id
    this.editionTarget.replaceChildren(...assets.map((asset, index) => Object.assign(document.createElement("option"), {
      value: String(index), selected: index === this.assetIndex,
      textContent: `${FORMAT_LABELS[asset.format] || asset.format.toUpperCase()} · ${asset.filename}${asset.id === saved ? " · your place" : ""}`
    })))
    const savedAsset = assets.find(asset => asset.id === saved)
    const note = savedAsset && savedAsset.id !== this.currentAsset.id
      ? `Your saved place is in the ${FORMAT_LABELS[savedAsset.format] || savedAsset.format}. This ${FORMAT_LABELS[this.currentAsset.format] || "file"} opens at its beginning; turning a page here saves your place in it instead.`
      : ""
    if (this.hasEditionNoteTarget) { this.editionNoteTarget.hidden = !note; this.editionNoteTarget.textContent = note }
  }

  chooseEdition() {
    const index = Number(this.editionTarget.value)
    if (!Number.isInteger(index) || index === this.assetIndex || !this.publication.assets[index]) return
    const place = this.savedPlace?.asset_id === this.publication.assets[index].id ? this.savedPlace : null
    this.switchAsset(index, place)
  }

  switchAsset(index, progress) {
    this.abort?.abort()
    this.closeReadAlong()
    this.book?.destroy()
    this.book = null
    this.rendition = null
    this.pageReader?.destroy()
    this.pageReader = null
    this.readerReady = false
    this.readingAnchor = null
    this.deferredPlace = null
    if (this.hasErrorTarget) this.errorTarget.hidden = true
    this.assetIndex = index
    this.initialProgress = progress?.asset_id === this.currentAsset.id ? progress : null
    if (progress) this.savedPlace = progress
    if (!this.pageFormat) this.viewportTarget.replaceChildren(Object.assign(document.createElement("p"), { className: "consumer-opening", textContent: "Opening your book…" }))
    return this.openReading()
  }

  // PDF and CBZ ------------------------------------------------------------------

  async openPages() {
    const asset = this.currentAsset
    this.locationTarget.textContent = "Opening…"
    try {
      this.pageModule ||= await import("consumer_page_reader")
      if (!this.active || this.currentAsset !== asset) return
      let resources = null
      try { resources = JSON.parse(this.hasPdfResourcesTarget ? this.pdfResourcesTarget.textContent : "null") } catch (_) { resources = null }
      const reader = new this.pageModule.PageReader({
        element: this.pagesTarget, asset, format: asset.format, resources,
        orderURL: asset.reading_order_url ? this.assetURL(asset.reading_order_url) : null,
        label: "Page",
        onChange: (position, count, { activity, shown }) => this.pagePosition(reader, position, count, activity, shown),
        onTap: zone => this.pageTap(zone),
        onError: message => this.showError(message)
      })
      this.pageReader = reader
      const count = await reader.open(this.assetURL())
      if (!this.active || this.pageReader !== reader) return
      this.pageSliderTarget.max = String(count)
      this.pageNumberTarget.max = String(count)
      this.pageTotalTarget.textContent = `of ${count}`
      // Restoring is display only: an unusable saved place is kept, not
      // replaced by an invented page-one activity.
      const restored = this.pageModule.restoredPage(asset.format, this.initialProgress?.locator, count, reader.items())
      await reader.show(restored.position)
      if (!this.active || this.pageReader !== reader) return
      if (this.initialProgress && !restored.exact) this.showSyncStatus("message", `Your saved page isn't in this file any more; showing page ${restored.position}. Your saved place is kept until you turn a page.`)
      this.readerReady = true
      if (this.deferredPlace) { const place = this.deferredPlace; this.deferredPlace = null; this.applyPlace(place) }
    } catch (error) {
      if (error?.name !== "AbortError" && this.active && this.currentAsset === asset) {
        this.showError(error?.message || "This file couldn't be opened.")
        this.locationTarget.textContent = "Unavailable"
        if (this.hasControlsTarget) this.showControls()
      }
    }
  }

  pagePosition(reader, position, count, activity, shown) {
    if (!this.active || reader !== this.pageReader) return
    // A page that now shows replaces an earlier page's error.
    if (shown && this.hasErrorTarget) this.errorTarget.hidden = true
    const label = `Page ${position} of ${count}`
    this.locationTarget.textContent = label
    this.pageNumberTarget.value = String(position)
    this.pageSliderTarget.value = String(position)
    this.zoomLabelTarget.textContent = reader.zoomed ? `${Math.round(reader.zoom * 100)}%` : "Fit"
    if (!shown || !activity || !this.readerReady) return
    if (this.hasAnnounceTarget) this.announceTarget.textContent = label
    this.recordPlace({ asset_id: this.currentAsset.id, locator: reader.locator(position) })
  }

  pageTap(zone) {
    if (!this.controlsTarget.hidden) return this.hideControls()
    if (zone === "previous") return this.previousPage()
    if (zone === "next") return this.nextPage()
    this.showControls()
  }

  movePage(move, message) {
    if (!this.pageReader || !this.readerReady) return
    Promise.resolve(move(this.pageReader)).catch(() => { if (this.active) this.showError(message) })
  }

  jumpToPage(event) {
    event?.preventDefault?.()
    const value = Number(this.pageNumberTarget.value)
    if (Number.isFinite(value)) this.movePage(reader => reader.go(value), "This page couldn't be opened.")
  }
  previewPage() { this.pageNumberTarget.value = this.pageSliderTarget.value }
  slidePage() { this.movePage(reader => reader.go(Number(this.pageSliderTarget.value)), "This page couldn't be opened.") }
  zoomIn() { this.movePage(reader => reader.zoomIn().then(() => this.zoomShown(reader)), "Couldn't zoom this page.") }
  zoomOut() { this.movePage(reader => reader.zoomOut().then(() => this.zoomShown(reader)), "Couldn't zoom this page.") }
  zoomFit() { this.movePage(reader => reader.fit().then(() => this.zoomShown(reader)), "Couldn't fit this page.") }
  zoomShown(reader) { if (this.active && reader === this.pageReader) this.zoomLabelTarget.textContent = reader.zoomed ? `${Math.round(reader.zoom * 100)}%` : "Fit" }

  // Ebook --------------------------------------------------------------------

  async openEbook() {
    const asset = this.currentAsset
    const summary = asset.read_along
    this.renderReadAlongInfo(summary)
    // A read-along EPUB is read entry by entry from the server (or this
    // browser's download), so its narration never enters the text engine and
    // the web limit applies to the text, styles and images alone.
    const streamed = summary?.status === "available" && Number.isFinite(summary.text_bytes) && summary.text_bytes <= WEB_EBOOK_LIMIT
    try {
      if (!streamed && this.currentAsset.size_bytes > WEB_EBOOK_LIMIT) throw new Error("This ebook is larger than the web preview's 32 MiB limit. Use the native reader or download the file.")
      this.abort = new AbortController()
      let buffer = null, prepared = null, readAlongModule = null
      const engine = import("consumer_reader_engine")
      if (streamed) {
        readAlongModule = await import("consumer_read_along")
        const response = await fetch(this.assetURL(summary.manifest_url), { credentials: "same-origin", redirect: "error", signal: this.abort.signal, headers: { Accept: "application/json" } })
        if (!response.ok) throw new Error("This book's read-along data is unavailable. Refresh the publication or sign in again.")
        prepared = readAlongModule.prepareManifest(await response.json(), { assetId: asset.id, generation: summary.generation })
        this.streamBase = this.assetURL(prepared.resourcesUrl)
      } else {
        this.streamBase = null
        const response = await fetch(this.assetURL(), { credentials: "same-origin", redirect: "error", signal: this.abort.signal })
        if (!response.ok) throw new Error("This ebook is unavailable. Refresh the publication or sign in again.")
        buffer = await response.arrayBuffer()
      }
      const { ePub, DOMPurify } = await engine
      if (!this.active || this.currentAsset !== asset) return
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
        base.href = this.sectionBase(section.href)
        document.head.prepend(base)
        document.head.prepend(policy)
        return document.documentElement.outerHTML
      }
      if (streamed) {
        // Narration, overlays and video are played (or ignored) by the
        // reader; EPUB.js would otherwise load every one into memory.
        const unpack = this.book.unpack.bind(this.book)
        this.book.unpack = packaging => {
          for (const [id, item] of Object.entries(packaging.manifest || {})) {
            if (/^(?:audio|video)\//.test(item.type || "") || item.type === "application/smil+xml") delete packaging.manifest[id]
          }
          return unpack(packaging)
        }
        await this.book.open(this.streamBase, "directory")
      } else await this.book.open(buffer)
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
      this.rendition.themes.default({ body: { color: `${colors.getPropertyValue("--ink")} !important`, background: `${colors.getPropertyValue("--surface")} !important`, "font-family": "Georgia, serif !important", "line-height": "1.7 !important" }, "a": { color: "inherit" },
        [`.${READ_ALONG_ACTIVE}`]: { background: `${colors.getPropertyValue("--accent-soft")} !important`, "border-radius": "3px", "box-shadow": `0 0 0 3px ${colors.getPropertyValue("--accent-soft")}`, transition: "background-color .2s" } })
      this.rendition.themes.fontSize(`${this.fontSize}%`)
      this.rendition.on("relocated", location => this.ebookPosition(location))
      this.rendition.on("resized", () => this.reflowed())
      this.rendition.hooks.content.register(contents => this.bookInput(contents))
      if (prepared) this.startReadAlong(readAlongModule, prepared)
      for (const menu of this.chapterMenus) menu.replaceChildren()
      const addChapters = (items, depth = 0) => {
        for (const item of items) {
          const option = document.createElement("option")
          option.value = item.href
          option.textContent = `${"— ".repeat(depth)}${item.label.trim()}`
          for (const menu of this.chapterMenus) menu.append(option.cloneNode(true))
          addChapters(item.subitems || [], depth + 1)
        }
      }
      addChapters((await this.book.loaded.navigation).toc)
      const locator = this.initialProgress?.locator
      await this.showLocator(locator)
      if (locator && !locator.locations?.cfi && !this.fragmentOf(locator) && locator.locations?.progression > 0) {
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
      await this.readAlongRestored(locator)
      if (this.deferredPlace) { const place = this.deferredPlace; this.deferredPlace = null; this.applyPlace(place) }
    } catch (error) {
      if (error.name !== "AbortError" && this.active) {
        this.showError(error.message || "This EPUB couldn't be opened.")
        if (this.hasControlsTarget) this.showControls()
      }
    }
  }

  // Archive paths ("OEBPS/chapter.xhtml") are what saved places and the
  // read-along manifest use, whichever way the book was opened.
  zipHref(href) {
    const resolved = this.book.resolve(href)
    if (!this.streamBase) return resolved.replace(/^\/+/, "")
    const url = new URL(resolved, window.location.href)
    const base = new URL(this.streamBase)
    if (url.origin !== base.origin || !url.pathname.startsWith(base.pathname)) return ""
    try { return decodeURIComponent(url.pathname.slice(base.pathname.length)) } catch (_) { return "" }
  }

  // The EPUB.js target for an archive path.
  bookTarget(href) {
    const clean = String(href).replace(/^\/+/, "")
    const absolute = this.streamBase ? new URL(clean.split("/").map(encodeURIComponent).join("/"), this.streamBase).pathname : `/${clean}`
    return this.book.path.relative(absolute)
  }

  sectionBase(href) {
    const resolved = this.book.resolve(href)
    if (/^[a-z][a-z0-9+.-]*:/i.test(resolved)) {
      const url = new URL(resolved)
      if (url.origin === window.location.origin) return url.href
    }
    return new URL(`/${resolved.replace(/^\/+/, "")}`, window.location.origin).href
  }

  fragmentOf(locator) {
    const fragment = Array.isArray(locator?.locations?.fragments) ? locator.locations.fragments[0] : null
    return typeof fragment === "string" && fragment && !fragment.includes("=") ? fragment : null
  }

  // Show a saved place: its CFI, else its element (read-along places name
  // the element heard), else its section.
  async showLocator(locator) {
    if (locator?.locations?.cfi) return this.showPlace(locator.locations.cfi)
    const target = locator?.href ? this.bookTarget(locator.href) : undefined
    await this.showPlace(target)
    const fragment = this.fragmentOf(locator)
    if (!target || !fragment || !this.active) return
    const element = this.elementFor(locator.href, fragment)
    const contents = element && this.contentsFor(locator.href)
    if (contents) await this.showPlace(this.elementCfi(contents, element))
  }

  // The loaded document (EPUB.js contents) for an archive path, if shown.
  contentsFor(href) {
    return this.rendition?.getContents().find(contents => {
      const section = this.book.spine.get(contents.sectionIndex)
      return section && this.zipHref(section.href) === href
    }) || null
  }

  // A CFI for the start of an element's text. EPUB.js positions a collapsed
  // text range cleanly; an element CFI makes it log range errors.
  elementCfi(contents, element) {
    const range = element.ownerDocument.createRange()
    range.selectNodeContents(element)
    range.collapse(true)
    return contents.cfiFromRange(range)
  }

  // Sanitized documents prefix IDs ("user-content-"); look up both.
  elementFor(href, fragment) {
    const document = this.contentsFor(href)?.document
    if (!document) return null
    return document.getElementById(`user-content-${fragment}`) || document.getElementById(fragment)
  }

  // EPUB.js 0.3.93 measures a target after the theme and text size reach a
  // newly rendered section, but clamps the page offset to the frame width it
  // measured before they did. The frame grows a moment later and nothing moves
  // back, so a place deep in a long chapter opened pages early. Size the frame
  // to its laid-out text once fonts settle, then position again within the
  // section, which is now shown at its final width.
  async showPlace(target) {
    await this.rendition.display(target)
    if (target && this.active) {
      await this.settleFrames()
      if (this.active) await this.rendition.display(target)
    }
    if (this.active) this.anchorAt(target)
  }

  // The reading anchor is the exact place being read: a restored CFI, the
  // start of a page the reader turned to, or the element narration followed.
  // Layout changes show it again and never replace it with the start of the
  // page they produced. That start lies before the place, so re-anchoring on it
  // let each change drift earlier until the saved text left the page.
  anchorAt(target) {
    const cfi = typeof target === "string" && target.startsWith("epubcfi(") ? target : this.rendition.currentLocation()?.start?.cfi
    if (cfi) this.readingAnchor = cfi
  }

  layoutAnchor() {
    return this.readingAnchor || this.rendition.location?.start?.cfi || this.rendition.currentLocation()?.start?.cfi
  }

  // While the text follows narration, the place being read is the text being
  // heard. Following turns a page only when the heard cue changes, so a cue
  // already in view is not the reading anchor yet; a layout change must show
  // that cue itself, or it can land on a later page and stay unseen while it
  // sounds. Browsing (suspended), Follow off, a pause or the gap between cues
  // keep the reading anchor. Display only: never a reading observation.
  // EPUB.js clears its views before it reports a resize, so the cue's place is
  // the CFI kept when it was highlighted, not a lookup in the cleared page.
  heardAnchor() {
    const readAlong = this.readAlong
    if (!readAlong?.follow || readAlong.suspended || !readAlong.session.playing) return null
    const cue = readAlong.session.cue
    return cue >= 0 && readAlong.heardPlace?.cue === cue ? readAlong.heardPlace.cfi : null
  }

  // A window or orientation change re-renders the section the same way. EPUB.js
  // queues its own display of the place right after this event; settle after
  // it. The anchor is kept through a burst of resizes; the heard cue is read
  // when the layout runs, after any follow queued before it.
  reflowed() {
    if (!this.readerReady) return
    const cfi = this.layoutAnchor()
    if (!cfi) return
    this.userMoved = false
    const reflow = this.readerReflow.then(() => this.active && this.showPlace(this.heardAnchor() || cfi))
      .catch(() => {})
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
    if (this.readAlong && event.key === " " && !event.target.closest?.("button, a")) { event.preventDefault(); return this.readAlongToggle() }
    if (this.pageReader) {
      if (event.key === "+" || event.key === "=") { event.preventDefault(); return this.zoomIn() }
      if (event.key === "-") { event.preventDefault(); return this.zoomOut() }
      if (event.key === "0") { event.preventDefault(); return this.zoomFit() }
      if (event.key === "Home") { event.preventDefault(); return this.movePage(reader => reader.go(1), "This page couldn't be opened.") }
      if (event.key === "End") { event.preventDefault(); return this.movePage(reader => reader.go(reader.count), "This page couldn't be opened.") }
    }
    if (event.key === "ArrowRight" || event.key === "PageDown") { event.preventDefault(); this.nextPage() }
    if (event.key === "ArrowLeft" || event.key === "PageUp") { event.preventDefault(); this.previousPage() }
  }

  // Controls overlay the text, so revealing them never reflows the book.
  showControls() {
    if (!this.hasControlsTarget || !this.controlsTarget.hidden) return
    this.controlsTarget.hidden = false
    if (this.hasDesktopNavTarget) this.desktopNavTarget.hidden = true
    if (this.hasDesktopRevealTarget) this.desktopRevealTarget.setAttribute("aria-expanded", "true")
    this.revealTarget.setAttribute("aria-expanded", "true")
    this.hideTarget.focus()
  }

  hideControls() {
    if (!this.hasControlsTarget || this.controlsTarget.hidden) return
    const hadFocus = this.controlsTarget.contains(document.activeElement)
    this.controlsTarget.hidden = true
    if (this.hasDesktopNavTarget) this.desktopNavTarget.hidden = false
    if (this.hasDesktopRevealTarget) this.desktopRevealTarget.setAttribute("aria-expanded", "false")
    this.revealTarget.setAttribute("aria-expanded", "false")
    if (hadFocus || document.activeElement === document.body) this.readingSurface.focus({ preventScroll: true })
  }

  ebookPosition(location) {
    if (!this.active || this.pageReader || !this.book) return
    const start = location.start
    const fraction = Math.max(0, (start.displayed.page - 1) / Math.max(1, start.displayed.total))
    const total = Math.min(1, (start.index + fraction) / Math.max(1, this.book.spine.length))
    this.locationTarget.textContent = `${start.displayed.page} / ${start.displayed.total} · chapter ${start.index + 1}`
    const option = [...this.chaptersTarget.options].find(option => option.value.split("#")[0] === start.href)
    if (option) for (const menu of this.chapterMenus) menu.value = option.value
    // Only the reader's own moves are activity; restoring or reflowing is not.
    if (!this.readerReady) return
    if (!this.userMoved) { this.lastEbookCfi = start.cfi; return }
    this.readingAnchor = start.cfi
    if (start.cfi === this.lastEbookCfi) return
    this.lastEbookCfi = start.cfi
    // While narration plays, the place heard is the activity; turning pages
    // meanwhile is browsing and leaves it alone.
    if (this.readAlong?.session.playing) return
    if (this.readAlong) this.readAlong.readSinceHeard = true
    this.recordPlace({ asset_id: this.currentAsset.id, locator: { href: this.zipHref(start.href), type: "application/xhtml+xml", locations: { progression: fraction, totalProgression: total, cfi: start.cfi } } })
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
      // Moving away while narration plays pauses page-follow until the
      // reader returns to the narration.
      if (this.readAlong?.session.playing) this.suspendFollow()
      await move()
    } catch (_) { if (this.active) this.showError(message) }
  }

  previousPage() {
    if (this.pageReader) return this.movePage(reader => reader.previous(), "Couldn't open the previous page.")
    this.moveEbook(() => this.rendition.prev(), "Couldn't open the previous page.")
  }
  nextPage() {
    if (this.pageReader) return this.movePage(reader => reader.next(), "Couldn't open the next page.")
    this.moveEbook(() => this.rendition.next(), "Couldn't open the next page.")
  }
  get chapterMenus() { return [this.chaptersTarget, ...(this.hasDesktopChaptersTarget ? [this.desktopChaptersTarget] : [])] }

  chooseChapter(event) {
    const chapter = event?.currentTarget?.value ?? this.chaptersTarget.value
    this.moveEbook(() => this.showPlace(chapter), "This chapter couldn't be opened.")
  }
  smallerText() { this.resizeText(-10) }
  largerText() { this.resizeText(10) }
  resizeText(delta) {
    const reflow = this.readerReflow.then(async () => {
      if (!this.active || !this.rendition || !this.readerReady) return
      this.userMoved = false
      const heard = this.heardAnchor()
      if (heard) this.readingAnchor = heard
      const cfi = this.layoutAnchor()
      this.fontSize = Math.max(80, Math.min(180, this.fontSize + delta))
      this.savePreferences()
      this.rendition.themes.fontSize(`${this.fontSize}%`)
      await this.settleFrames()
      if (!this.active) return
      if (cfi) await this.rendition.display(cfi)
      await this.rendition.reportLocation()
    }).catch(() => { if (this.active) this.showError("Text size couldn't be changed. Try again.") })
    this.readerReflow = reflow
  }
  savePreferences() {
    try { localStorage.setItem("shelfarr.reader.preferences.v1", JSON.stringify({ fontSize: this.fontSize, playbackRate: this.playbackRate })) } catch (_) { /* keep preferences for this visit */ }
  }

  // Read-along ---------------------------------------------------------------

  // What the reading controls say about narration for this edition. Plain
  // EPUBs with no related audiobook say nothing.
  renderReadAlongInfo(summary) {
    if (!this.hasReadAlongTarget) return
    const audiobook = summary?.audiobook
    let note = ""
    let tools = false
    switch (summary?.status) {
      case "available":
        if (!(summary.text_bytes <= WEB_EBOOK_LIMIT)) note = "This book's narration is aligned, but its text and images exceed the web reader's 32 MiB limit. Use a native Shelfarr app to read along."
        else { tools = true; note = "Checking the narration…" }
        break
      case "stale":
      case "invalid":
        note = `${summary.reason || "This book's narration data can't be used."} Reading works as usual.`
        break
      case "unaligned":
        if (audiobook) note = `“${audiobook.title}” isn't aligned with this text, so read-along isn't available. You can listen to it on its own.`
        break
    }
    this.readAlongTarget.hidden = !note
    this.readAlongNoteTarget.textContent = note
    this.readAlongToolsTarget.hidden = !tools
    this.readAlongPillTarget.hidden = true
  }

  startReadAlong(module, prepared) {
    const asset = this.currentAsset
    const paired = this.publication.read_along_audiobook
    const scope = this.publication.progress_scope || {}
    let pairedSync = null
    if (prepared.source === "imported" && paired?.progress_url) {
      pairedSync = new ConsumerProgressSync({
        url: paired.progress_url, account: scope.account, base: scope.base || "", publication: paired.id,
        version: paired.progress?.version, assets: prepared.audio.map(track => track.asset_id).filter(Boolean),
        onConflict: () => this.showSyncStatus("message", `“${paired.title}” has a different place on another device. Open the audiobook to choose which to keep.`)
      })
    }
    const checkpoints = new ListeningCheckpoints({ record: place => this.recordHeard(place) })
    const audio = this.readAlongAudioTarget
    audio.defaultPlaybackRate = this.playbackRate
    audio.playbackRate = this.playbackRate
    if (this.hasReadAlongSpeedTarget) this.readAlongSpeedTarget.value = String(this.playbackRate)
    const session = new module.ReadAlongSession({
      prepared, audio, checkpoints,
      resolveUrl: url => this.assetURL(url),
      onCue: (cue, detail) => this.readAlongCue(cue, detail),
      onState: state => this.readAlongState(state),
      onError: message => this.showError(message),
      onRecord: () => { this.sync.flush(); pairedSync?.flush() }
    })
    this.readAlong = { module, prepared, session, checkpoints, pairedSync, paired, assetId: asset.id, follow: true, suspended: false,
      readSinceHeard: false, highlighted: null, followChain: Promise.resolve() }
    try { this.readAlong.follow = localStorage.getItem("shelfarr.reader.readAlongFollow.v1") !== "off" } catch (_) { /* default on */ }
    if (this.hasReadAlongFollowTarget) this.readAlongFollowTarget.checked = this.readAlong.follow
    this.rendition.hooks.content.register(contents => this.readAlongContent(contents))
    this.readAlongNoteTarget.textContent = [prepared.source === "imported" ? `Narrated by “${paired?.title || "the audiobook"}”, aligned to this edition.` : "Narration from this book.",
      module.describeCoverage(prepared.coverage)].filter(Boolean).join(" ")
    this.readAlongState("paused")
    if ("mediaSession" in navigator) {
      navigator.mediaSession.metadata = new MediaMetadata({ title: this.publication.title, artist: this.publication.author || "", album: "Read along" })
      for (const [action, handler] of Object.entries({ play: () => this.readAlongToggle(true), pause: () => session.pause(), seekbackward: () => session.skip(-15), seekforward: () => session.skip(30) })) {
        try { navigator.mediaSession.setActionHandler(action, handler) } catch (_) { /* unsupported browser action */ }
      }
    }
  }

  closeReadAlong() {
    const readAlong = this.readAlong
    if (!readAlong) return
    readAlong.session.settle()
    readAlong.session.close()
    this.sync?.flush()
    readAlong.pairedSync?.close()
    this.readAlong = null
    if (this.hasReadAlongPillTarget) this.readAlongPillTarget.hidden = true
  }

  // After the text shows a saved or remote place, put the narration there
  // too, without playing or recording. A read-along place names its exact
  // audio offset; a reading place names an element or nothing.
  async readAlongRestored(locator, observedAt = null) {
    const readAlong = this.readAlong
    if (!readAlong || readAlong.session.playing) return
    const { module, prepared } = readAlong
    let place = locator ? module.placeFromLocator(prepared, locator) : null
    // A separate audiobook may have been heard further since (on its own
    // player or another device). Offer it; never write it as reading.
    const timeOf = restored => Date.parse(restored?.observedAt ?? restored?.progress?.observed_at ?? "")
    const audiobookPlace = readAlong.pairedSync?.restorePlace(readAlong.paired?.progress)
    const audiobook = audiobookPlace?.progress
    const heard = audiobook ? module.placeFromAudio(prepared, audiobook.asset_id, audiobook.position_seconds) : null
    const ebookTime = observedAt ? Date.parse(observedAt) : timeOf(this.sync.restorePlace(this.publication.progress))
    const audioTime = timeOf(audiobookPlace)
    const later = Number.isFinite(audioTime) && (!Number.isFinite(ebookTime) || audioTime > ebookTime)
    if (heard && (!place || later) && heard.cue !== place?.cue) {
      readAlong.offer = heard
      if (this.hasReadAlongOfferTarget) this.readAlongOfferTarget.hidden = false
    }
    if (!place) return
    const restored = await readAlong.session.prepare(place.track, place.ms)
    if (restored === false || !this.active || this.readAlong !== readAlong) return false
    readAlong.readSinceHeard = !locator?.locations?.readAlong
  }

  // "Go to the audiobook's place": show and prepare it (still not activity).
  async useAudiobookPlace() {
    const readAlong = this.readAlong
    const place = readAlong?.offer
    if (this.hasReadAlongOfferTarget) this.readAlongOfferTarget.hidden = true
    if (!place) return
    readAlong.offer = null
    await readAlong.session.prepare(place.track, place.ms)
    readAlong.readSinceHeard = false
    readAlong.suspended = false
    await this.followCue(place.cue, { force: true })
  }

  dismissAudiobookPlace() {
    if (this.readAlong) this.readAlong.offer = null
    if (this.hasReadAlongOfferTarget) this.readAlongOfferTarget.hidden = true
  }

  // A checkpoint of narration actually heard: the ebook place is the
  // reached cue's element with the exact audio offset, and a separate
  // audiobook's place is that file and second, both at the same time.
  recordHeard({ asset_id: key, position_seconds: seconds }) {
    const readAlong = this.readAlong
    if (!readAlong || !this.active) return
    const track = Number(String(key).split(":")[1])
    const ms = Math.round(seconds * 1000)
    const { module, prepared } = readAlong
    const cue = module.cueReached(prepared, track, ms)
    const observedAt = new Date().toISOString()
    if (cue >= 0) {
      const href = module.hrefOf(prepared, cue)
      const element = this.elementFor(href, prepared.fragments[cue])
      const contents = element && this.contentsFor(href)
      const sectionIndex = this.book.spine.get(this.bookTarget(href))?.index
      const extra = { cfi: contents ? this.elementCfi(contents, element) : undefined,
        totalProgression: Number.isInteger(sectionIndex) ? Math.min(1, sectionIndex / Math.max(1, this.book.spine.length)) : undefined }
      this.recordPlace({ asset_id: readAlong.assetId, locator: module.locatorFor(prepared, track, ms, extra) }, observedAt)
      readAlong.readSinceHeard = false
    }
    const audioAsset = prepared.audio[track]?.asset_id
    if (readAlong.pairedSync && audioAsset) readAlong.pairedSync.record({ asset_id: audioAsset, position_seconds: Math.max(0, seconds) }, observedAt)
  }

  readAlongState(state) {
    if (!this.active || !this.readAlong) return
    const playing = state === "playing"
    for (const button of [this.hasReadAlongPlayTarget && this.readAlongPlayTarget, this.hasReadAlongPillPlayTarget && this.readAlongPillPlayTarget].filter(Boolean)) {
      button.textContent = playing ? "Pause" : state === "finished" ? "Play again" : "Play"
      button.setAttribute("aria-pressed", playing ? "true" : "false")
      button.setAttribute("aria-label", playing ? "Pause narration" : "Play narration")
    }
    this.element.classList.toggle("consumer-reading-session--narrating", playing)
    this.readAlongPillTarget.hidden = !playing && !this.readAlong.pillAfterPause
    this.readAlongReturnTarget.hidden = !this.readAlong.suspended
    if (playing) {
      this.readAlong.pillAfterPause = true
      // Choosing to play here answers the audiobook-place offer.
      this.dismissAudiobookPlace()
    }
    if (state === "finished") this.readAlong.finished = true
  }

  // The Play/Pause buttons (Stimulus passes the click event, not a flag).
  playPause() { return this.readAlongToggle() }

  async readAlongToggle(forcePlay = false) {
    const readAlong = this.readAlong
    if (!readAlong || !this.readerReady) return
    const { session } = readAlong
    if (session.playing && !forcePlay) return session.pause()
    if (session.playing) return
    if (readAlong.resuming) return
    readAlong.resuming = true
    try {
      // A genuine resume is the safe point for an accepted remote place,
      // even after this visit has listened. Text and narration must both be
      // restored before playback; a second Play cannot bypass that work.
      if (this.remotePending && await this.goToRemote() === false) return
      if (!this.active || !this.readerReady || this.readAlong !== readAlong) return
      // After reading on (or with no narration place yet), start with the
      // narration of the page in view; otherwise resume where it paused.
      if (readAlong.readSinceHeard || session.track < 0 || readAlong.finished) {
        readAlong.finished = false
        const cue = this.visibleCue()
        readAlong.suspended = false
        readAlong.readSinceHeard = false
        return await session.playFrom(cue >= 0 ? cue : 0)
      }
      readAlong.suspended = false
      return await session.resume()
    } finally {
      readAlong.resuming = false
    }
  }

  toggleFollow() {
    const readAlong = this.readAlong
    if (!readAlong) return
    readAlong.follow = this.readAlongFollowTarget.checked
    try { localStorage.setItem("shelfarr.reader.readAlongFollow.v1", readAlong.follow ? "on" : "off") } catch (_) { /* this visit only */ }
    if (readAlong.follow && readAlong.session.playing) { readAlong.suspended = false; this.followCue(readAlong.session.cue, { force: true }) }
    this.readAlongReturnTarget.hidden = !readAlong.suspended
  }

  readAlongSpeed() {
    this.playbackRate = Number(this.readAlongSpeedTarget.value)
    this.readAlongAudioTarget.defaultPlaybackRate = this.playbackRate
    this.readAlongAudioTarget.playbackRate = this.playbackRate
    this.savePreferences()
  }

  readAlongBack() { this.readAlong?.session.skip(-15) }
  readAlongForward() { this.readAlong?.session.skip(30) }

  suspendFollow() {
    if (!this.readAlong || !this.readAlong.follow) return
    this.readAlong.suspended = true
    this.readAlongReturnTarget.hidden = false
  }

  returnToNarration() {
    const readAlong = this.readAlong
    if (!readAlong) return
    readAlong.suspended = false
    this.readAlongReturnTarget.hidden = true
    const cue = readAlong.session.cue >= 0 ? readAlong.session.cue : readAlong.module.cueReached(readAlong.prepared, readAlong.session.track, readAlong.session.positionMs)
    this.followCue(cue, { force: true })
  }

  // The cue being heard changed (-1 between cues: nothing is highlighted).
  readAlongCue(cue, { reached } = {}) {
    const readAlong = this.readAlong
    if (!readAlong || !this.active) return
    const shown = cue >= 0 ? cue : (readAlong.session.playing ? -1 : reached)
    this.highlight(shown)
    if (cue >= 0 && readAlong.session.playing && readAlong.follow && !readAlong.suspended) this.followCue(cue)
  }

  highlight(cue) {
    const readAlong = this.readAlong
    readAlong.highlighted?.classList.remove(READ_ALONG_ACTIVE)
    readAlong.highlighted = null
    readAlong.highlightedCue = cue
    if (cue < 0) return
    const href = readAlong.module.hrefOf(readAlong.prepared, cue)
    const element = this.elementFor(href, readAlong.prepared.fragments[cue])
    if (!element) return
    element.classList.add(READ_ALONG_ACTIVE)
    readAlong.highlighted = element
    // Where this cue's text starts, for layout changes while it sounds.
    const contents = this.contentsFor(href)
    if (contents && readAlong.heardPlace?.cue !== cue) readAlong.heardPlace = { cue, cfi: this.elementCfi(contents, element) }
  }

  // A newly shown document gets the current highlight back.
  readAlongContent() {
    const readAlong = this.readAlong
    if (readAlong && Number.isInteger(readAlong.highlightedCue)) this.highlight(readAlong.highlightedCue)
  }

  // Turn to the page with the heard cue, only when it isn't in view. These
  // moves are display only: they never become reading activity.
  followCue(cue, { force = false } = {}) {
    const readAlong = this.readAlong
    if (!readAlong || cue < 0) return Promise.resolve()
    const run = async () => {
      if (!this.active || this.readAlong !== readAlong || !this.readerReady) return
      if (!force && (readAlong.suspended || !readAlong.follow || readAlong.session.cue !== cue)) return
      const href = readAlong.module.hrefOf(readAlong.prepared, cue)
      let element = this.elementFor(href, readAlong.prepared.fragments[cue])
      if (element && this.elementVisible(element)) return
      this.userMoved = false
      if (!element) {
        await this.showPlace(this.bookTarget(href))
        element = this.elementFor(href, readAlong.prepared.fragments[cue])
        this.highlight(readAlong.highlightedCue ?? cue)
      }
      const contents = element && this.contentsFor(href)
      if (contents && !this.elementVisible(element)) {
        this.userMoved = false
        const cfi = this.elementCfi(contents, element)
        await this.rendition.display(cfi)
        this.readingAnchor = cfi
      }
      this.lastEbookCfi = this.rendition.currentLocation()?.start?.cfi
    }
    const chain = this.readerReflow.then(run).catch(() => {})
    this.readerReflow = chain
    return chain
  }

  elementVisible(element) {
    const frame = element.ownerDocument?.defaultView?.frameElement
    const rect = element.getClientRects()[0]
    if (!frame || !rect) return false
    const frameRect = frame.getBoundingClientRect(), bounds = this.viewportTarget.getBoundingClientRect()
    const x = frameRect.left + rect.left, y = frameRect.top + rect.top
    return x >= bounds.left - 2 && x < bounds.right - 2 && y >= bounds.top - 2 && y < bounds.bottom - 2
  }

  // The first cue starting on the page in view, else the cue whose text the
  // page continues, else the next narrated cue after this section.
  visibleCue() {
    const readAlong = this.readAlong
    const { prepared, module } = readAlong
    const start = this.rendition.currentLocation()?.start
    if (!start) return -1
    const href = this.zipHref(start.href)
    const text = prepared.texts.indexOf(href)
    const bounds = this.viewportTarget.getBoundingClientRect()
    let before = -1
    if (text >= 0) {
      for (let cue = 0; cue < prepared.count; cue++) {
        if (prepared.textOf[cue] !== text) continue
        const element = this.elementFor(href, prepared.fragments[cue])
        if (!element) continue
        if (this.elementVisible(element)) return cue
        const frame = element.ownerDocument.defaultView.frameElement
        const rect = element.getClientRects()[0]
        if (frame && rect && frame.getBoundingClientRect().left + rect.left < bounds.left) before = cue
      }
      if (before >= 0) return before
    }
    const section = this.book.spine.get(start.href)?.index ?? 0
    for (let cue = 0; cue < prepared.count; cue++) {
      const index = this.book.spine.get(this.bookTarget(module.hrefOf(prepared, cue)))?.index
      if (Number.isInteger(index) && index > section) return cue
    }
    return -1
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
