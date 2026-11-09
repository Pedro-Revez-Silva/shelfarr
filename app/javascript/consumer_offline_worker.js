// Shelfarr offline worker for the browser reader and player.
//
// The server prepends `self.SHELFARR_OFFLINE = { version, shell, assets }`.
// The worker is registered only after a reader chooses Download, with the
// scope `<subpath>/read`. It answers just three kinds of request:
//
//   - media for a downloaded edition, from the signed-in account's cache, with
//     single byte ranges for audio seeking; anything else goes to the network
//   - the shell's own digested styles, scripts and fonts, precached at install
//   - reader pages (/read, /read/downloads, /read/<id>) when the server can't be
//     reached, with the static offline shell
//
// It never stores responses on its own: no pages, sessions, tokens, progress
// or other routes. Downloads are written by the page, not here.
"use strict"

;(() => {
  const CONFIG = self.SHELFARR_OFFLINE || { version: "development", shell: "", assets: [] }
  const ORIGIN = self.location.origin
  const SCOPE = new URL(self.registration ? self.registration.scope : `${ORIGIN}/read`)
  const BASE = SCOPE.pathname.replace(/\/read\/?$/, "")
  const DEPLOYMENT = ORIGIN + BASE
  const SHELL_PREFIX = `shelfarr-offline-shell.v1|${DEPLOYMENT}|`
  const SHELL_CACHE = SHELL_PREFIX + CONFIG.version
  const MEDIA_PREFIX = "shelfarr-offline-media.v1"
  const SHELL_URL = new URL(CONFIG.shell || `${BASE}/read/offline`, ORIGIN).href
  const ASSETS = new Set((CONFIG.assets || []).map(path => new URL(path, ORIGIN).pathname))
  const escape = text => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  const PAGE = new RegExp(`^${escape(BASE)}/read(?:/|/offline|/downloads/?|/[1-9]\\d{0,18}/?)?$`)
  // Downloaded media, and a downloaded comic's reading order.
  const MEDIA = new RegExp(`^${escape(BASE)}/read/[1-9]\\d{0,18}/assets/[0-9a-f]{64}(?:/reading_order)?$`)
  const UNREACHABLE = new Set([502, 503, 504])

  // One single range: "bytes=a-b", "bytes=a-" or "bytes=-n". Null without a
  // range, "invalid" when it can't be satisfied.
  function parseRange(header, size) {
    if (header === null || header === undefined || header === "") return null
    const match = /^bytes=(\d*)-(\d*)$/.exec(String(header).trim())
    if (!match || size <= 0 || (match[1] === "" && match[2] === "")) return "invalid"
    if (match[1] === "") {
      const suffix = Number(match[2])
      return suffix > 0 ? { start: Math.max(0, size - suffix), end: size - 1 } : "invalid"
    }
    const start = Number(match[1])
    const end = match[2] === "" ? size - 1 : Math.min(Number(match[2]), size - 1)
    return start >= size || end < start ? "invalid" : { start, end }
  }

  async function ranged(request, cached) {
    const range = request.headers.get("Range")
    if (!range) return cached
    const blob = await cached.blob()
    const type = cached.headers.get("Content-Type") || "application/octet-stream"
    const etag = cached.headers.get("ETag")
    const ifRange = request.headers.get("If-Range")
    if (ifRange && etag && ifRange !== etag) {
      return new Response(blob, { status: 200, headers: { "Content-Type": type, "Content-Length": String(blob.size), "Accept-Ranges": "bytes", ...(etag ? { ETag: etag } : {}) } })
    }
    const part = parseRange(range, blob.size)
    if (part === "invalid") return new Response(null, { status: 416, headers: { "Content-Range": `bytes */${blob.size}` } })
    const headers = { "Content-Type": type, "Content-Length": String(part.end - part.start + 1), "Content-Range": `bytes ${part.start}-${part.end}/${blob.size}`, "Accept-Ranges": "bytes" }
    if (etag) headers.ETag = etag
    return new Response(blob.slice(part.start, part.end + 1), { status: 206, statusText: "Partial Content", headers })
  }

  // The account the pages last confirmed for this deployment, if still valid.
  function activeAccount() {
    return new Promise(resolve => {
      let request
      try { request = indexedDB.open("shelfarr-offline", 1) } catch (_) { return resolve(null) }
      request.onupgradeneeded = () => {
        const db = request.result
        if (!db.objectStoreNames.contains("accounts")) db.createObjectStore("accounts", { keyPath: "deployment" })
        if (!db.objectStoreNames.contains("downloads")) db.createObjectStore("downloads", { keyPath: "key" }).createIndex("deployment", "deployment")
      }
      request.onerror = () => resolve(null)
      request.onblocked = () => resolve(null)
      request.onsuccess = () => {
        const db = request.result
        try {
          const read = db.transaction("accounts", "readonly").objectStore("accounts").get(DEPLOYMENT)
          read.onsuccess = () => {
            db.close()
            const record = read.result
            const now = Date.now()
            const valid = record && typeof record.account === "string" && record.confirmedAt <= now + 86_400_000 &&
              now - record.confirmedAt <= record.maxAgeDays * 86_400_000
            resolve(valid ? record.account : null)
          }
          read.onerror = () => { db.close(); resolve(null) }
        } catch (_) { db.close(); resolve(null) }
      }
    })
  }

  async function media(request) {
    const account = await activeAccount()
    if (account) {
      const cached = await caches.match(request.url, { cacheName: `${MEDIA_PREFIX}|${DEPLOYMENT}|${account}`, ignoreVary: true })
      if (cached) return ranged(request, cached)
    }
    return fetch(request)
  }

  async function shell() {
    return caches.match(SHELL_URL, { cacheName: SHELL_CACHE, ignoreVary: true })
  }

  async function page(request) {
    try {
      const response = await fetch(request)
      if (UNREACHABLE.has(response.status)) return (await shell()) || response
      return response
    } catch (error) {
      const fallback = await shell()
      if (fallback) return fallback
      throw error
    }
  }

  async function asset(request) {
    return (await caches.match(request.url, { cacheName: SHELL_CACHE, ignoreVary: true })) || fetch(request)
  }

  function wantsPage(request) {
    return request.mode === "navigate" || (request.headers.get("Accept") || "").includes("text/html")
  }

  self.ShelfarrOfflineWorker = { parseRange, PAGE, MEDIA, ASSETS, BASE }

  self.addEventListener("install", event => {
    event.waitUntil((async () => {
      const cache = await caches.open(SHELL_CACHE)
      await cache.addAll([SHELL_URL, ...ASSETS].map(url => new Request(new URL(url, ORIGIN).href, { cache: "reload", credentials: "same-origin" })))
      await self.skipWaiting()
    })())
  })

  self.addEventListener("activate", event => {
    event.waitUntil((async () => {
      for (const name of await caches.keys()) if (name.startsWith(SHELL_PREFIX) && name !== SHELL_CACHE) await caches.delete(name)
      await self.clients.claim()
    })())
  })

  self.addEventListener("fetch", event => {
    const request = event.request
    if (request.method !== "GET") return
    const url = new URL(request.url)
    if (url.origin !== ORIGIN) return
    if (MEDIA.test(url.pathname) && !url.search) return event.respondWith(media(request))
    if (ASSETS.has(url.pathname) && !url.search) return event.respondWith(asset(request))
    if (PAGE.test(url.pathname) && wantsPage(request)) return event.respondWith(page(request))
  })
})()
