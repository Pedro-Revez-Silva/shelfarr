import { Controller } from "@hotwired/stimulus"
import ConsumerProgressSync from "consumer_progress_sync"

export default class extends Controller {
  static targets = ["publication", "syncStatus", "retry", "conflict", "error", "viewport", "chapters", "location", "audio", "tracks", "trackTitle", "seek", "elapsed", "duration", "play"]

  connect() {
    this.publication = JSON.parse(this.publicationTarget.textContent)
    if (!this.publication.assets.length) return
    this.active = true
    this.fontSize = 105
    this.playbackRate = 1
    this.sync = new ConsumerProgressSync(this.publication.progress_url, this.publication.progress?.version,
      (message, retry) => { if (this.active) { this.syncStatusTarget.textContent = message; this.retryTarget.hidden = !retry } },
      () => { if (this.active) this.conflictTarget.hidden = false })
    this.visibilityHandler = () => { if (document.hidden) this.flush() }
    this.pageHandler = () => this.flush()
    document.addEventListener("visibilitychange", this.visibilityHandler)
    window.addEventListener("pagehide", this.pageHandler)
    const progress = this.publication.progress
    this.assetIndex = Math.max(0, this.publication.assets.findIndex(asset => asset.id === progress?.asset_id))
    this.initialProgress = progress?.asset_id === this.currentAsset.id ? progress : null
    if (progress && !this.initialProgress) this.syncStatusTarget.textContent = "The file changed. This edition starts afresh."
    if (this.publication.book_type === "ebook") this.openEbook()
    else this.openAudio(false)
  }

  disconnect() {
    this.flush()
    this.active = false
    this.sync?.close()
    this.abort?.abort()
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
      this.rendition.hooks.content.register(contents => {
        contents.document.addEventListener("click", event => { if (event.target.closest?.("a[href]")) this.userMoved = true })
        contents.document.addEventListener("keydown", event => {
          if (event.key === "ArrowRight") { event.preventDefault(); this.nextPage() }
          if (event.key === "ArrowLeft") { event.preventDefault(); this.previousPage() }
        })
      })
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
      await this.rendition.display(locator?.locations?.cfi || relativeHref)
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
              await this.rendition.display(contents.cfiFromRange(range))
              break
            }
            offset -= node.textContent.length
          }
        }
      }
      this.readerReady = true
    } catch (error) {
      if (error.name !== "AbortError" && this.active) this.showError(error.message || "This EPUB couldn't be opened.")
    }
  }

  ebookPosition(location) {
    if (!this.active) return
    const start = location.start
    const fraction = Math.max(0, (start.displayed.page - 1) / Math.max(1, start.displayed.total))
    const total = Math.min(1, (start.index + fraction) / Math.max(1, this.book.spine.length))
    this.locationTarget.textContent = `${start.displayed.page} / ${start.displayed.total} · chapter ${start.index + 1}`
    const option = [...this.chaptersTarget.options].find(option => option.value.split("#")[0] === start.href)
    if (option) this.chaptersTarget.value = option.value
    if (this.readerReady && this.userMoved) this.sync.save({ asset_id: this.currentAsset.id, locator: { href: this.book.resolve(start.href).replace(/^\/+/, ""), type: "application/xhtml+xml", locations: { progression: fraction, totalProgression: total, cfi: start.cfi } } })
  }

  previousPage() { this.userMoved = true; this.rendition?.prev().catch(() => this.showError("Couldn't open the previous page.")) }
  nextPage() { this.userMoved = true; this.rendition?.next().catch(() => this.showError("Couldn't open the next page.")) }
  chooseChapter() { this.userMoved = true; this.rendition?.display(this.chaptersTarget.value).catch(() => this.showError("This chapter couldn't be opened.")) }
  smallerText() { this.userMoved = true; this.fontSize = Math.max(80, this.fontSize - 10); this.rendition?.themes.fontSize(`${this.fontSize}%`) }
  largerText() { this.userMoved = true; this.fontSize = Math.min(180, this.fontSize + 10); this.rendition?.themes.fontSize(`${this.fontSize}%`) }

  openAudio(autoplay) {
    this.audioReady = false
    this.trackTitleTarget.textContent = this.currentAsset.filename
    this.tracksTarget.value = this.assetIndex
    this.audioTarget.src = this.assetURL()
    this.audioTarget.defaultPlaybackRate = this.playbackRate
    this.audioTarget.playbackRate = this.playbackRate
    this.audioTarget.load()
    this.playWhenReady = autoplay
    if ("mediaSession" in navigator) {
      navigator.mediaSession.metadata = new MediaMetadata({ title: this.publication.title, artist: this.publication.author || "", album: this.currentAsset.filename })
      for (const [action, handler] of Object.entries({ play: () => this.playAudio(), pause: () => this.audioTarget.pause(), seekbackward: () => this.backwardAudio(), seekforward: () => this.forwardAudio(), previoustrack: () => this.chooseAudioTrack(Math.max(0, this.assetIndex - 1)), nexttrack: () => this.nextTrack() })) {
        try { navigator.mediaSession.setActionHandler(action, handler) } catch (_) { /* unsupported browser action */ }
      }
    }
  }

  audioLoaded() {
    if (this.initialProgress) {
      this.audioTarget.currentTime = Math.min(this.initialProgress.position_seconds || 0, this.audioTarget.duration || 0)
      this.initialProgress = null
    }
    this.audioReady = true
    this.durationTarget.textContent = this.time(this.audioTarget.duration)
    this.audioPosition()
    if (this.playWhenReady) this.playAudio()
  }

  audioPosition() {
    if (!this.active || !this.audioReady) return
    const audio = this.audioTarget
    this.elapsedTarget.textContent = this.time(audio.currentTime)
    this.seekTarget.value = Number.isFinite(audio.duration) && audio.duration > 0 ? audio.currentTime / audio.duration * 100 : 0
    if (!audio.paused || this.hasPlayed) this.sync.save({ asset_id: this.currentAsset.id, position_seconds: audio.currentTime })
  }

  audioPaused() {
    if (!this.active) return
    this.playTarget.textContent = "▶"
    this.playTarget.setAttribute("aria-label", "Play audiobook")
    this.flush()
  }

  async playAudio() {
    try {
      await this.audioTarget.play()
      this.hasPlayed = true
      this.playTarget.textContent = "Ⅱ"
      this.playTarget.setAttribute("aria-label", "Pause audiobook")
    } catch (_) { this.showError("Playback couldn't start. Check your connection and try Play again.") }
  }
  toggleAudio() { this.audioTarget.paused ? this.playAudio() : this.audioTarget.pause() }
  seekAudio() { if (Number.isFinite(this.audioTarget.duration)) { this.audioTarget.currentTime = this.audioTarget.duration * Number(this.seekTarget.value) / 100; this.hasPlayed = true; this.audioPosition() } }
  backwardAudio() { this.audioTarget.currentTime = Math.max(0, this.audioTarget.currentTime - 15); this.audioPosition() }
  forwardAudio() { if (Number.isFinite(this.audioTarget.duration)) this.audioTarget.currentTime = Math.min(this.audioTarget.duration, this.audioTarget.currentTime + 30); this.audioPosition() }
  changeSpeed(event) {
    this.playbackRate = Number(event.target.value)
    this.audioTarget.defaultPlaybackRate = this.playbackRate
    this.audioTarget.playbackRate = this.playbackRate
  }
  chooseTrack() { this.chooseAudioTrack(Number(this.tracksTarget.value)) }
  chooseAudioTrack(index) {
    this.audioPosition()
    this.sync.flush()
    this.assetIndex = index
    this.initialProgress = null
    this.openAudio(this.hasPlayed)
  }
  nextTrack() {
    if (this.assetIndex + 1 < this.publication.assets.length) this.chooseAudioTrack(this.assetIndex + 1)
    else this.audioPaused()
  }
  audioError() { if (this.active) this.showError("This track couldn't be loaded. Check the connection, file format, or sign in again.") }
  showError(message) { if (this.hasErrorTarget) { this.errorTarget.textContent = message; this.errorTarget.hidden = false } }
  flush() { if (this.hasAudioTarget) this.audioPosition(); this.sync?.flush() }
  retrySync() { this.sync?.flush() }
  useServerProgress() { window.location.reload() }
  keepLocalProgress() { this.conflictTarget.hidden = true; this.sync.keepLocal() }
  time(seconds) { if (!Number.isFinite(seconds)) return "—"; const value = Math.max(0, Math.floor(seconds)); return `${Math.floor(value / 60)}:${String(value % 60).padStart(2, "0")}` }
}
