"use strict"

;(() => {
  const CONFIG = self.SHELFARR_GO_OFFLINE
  const DEFAULT_LIBRARY = "/preview/library"
  const PREFIX = CONFIG.cache || (CONFIG.library === DEFAULT_LIBRARY ? "shelfarr-go-preview-offline.v1|" : `shelfarr-go-preview-offline.v1@${CONFIG.library}|`)
  const CACHE = PREFIX + CONFIG.version
  const ORIGIN = self.location.origin
  const ASSETS = new Map(CONFIG.assets.map(asset => [asset.path, asset.sha256]))
  const UNREACHABLE = new Set([502, 503, 504])
  const READS = CONFIG.reads || { prefix: CONFIG.library, suffix: "/read" }
  const literal = text => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  const READER = new RegExp(`^${literal(READS.prefix)}/[1-9][0-9]{0,18}${literal(READS.suffix)}$`)

  function shellFor(pathname) {
    if (pathname === CONFIG.downloads) return CONFIG.shells.downloads
    if (READER.test(pathname)) return CONFIG.shells.reader
    return null
  }

  async function digest(buffer) {
    const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", buffer))
    return Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("")
  }

  async function precache() {
    const cache = await caches.open(CACHE)
    for (const [path, expected] of ASSETS) {
      const response = await fetch(new Request(new URL(path, ORIGIN).href, { cache: "reload", credentials: "omit", redirect: "error" }))
      if (response.status !== 200 || response.type !== "basic") throw new Error(`${path} answered ${response.status}`)
      const body = await response.arrayBuffer()
      if (await digest(body) !== expected) throw new Error(`${path} is not the listed file`)
      await cache.put(new URL(path, ORIGIN).href, new Response(body, { status: 200, headers: { "Content-Type": response.headers.get("Content-Type") || "application/octet-stream", "X-Content-Type-Options": "nosniff" } }))
    }
  }

  async function navigate(request, shell) {
    const response = await fetch(request).catch(() => null)
    if (response && !UNREACHABLE.has(response.status)) return response
    return new Response(shell.body, { status: 200, headers: shell.headers })
  }

  async function asset(request) {
    return (await caches.match(request.url, { cacheName: CACHE })) || fetch(request)
  }

  self.addEventListener("install", event => {
    event.waitUntil(precache().catch(async error => {
      await caches.delete(CACHE)
      throw error
    }))
  })

  self.addEventListener("activate", event => {
    event.waitUntil((async () => {
      for (const name of await caches.keys()) if (name.startsWith(PREFIX) && name !== CACHE) await caches.delete(name)
    })())
  })

  self.addEventListener("fetch", event => {
    const request = event.request
    if (request.method !== "GET") return
    const url = new URL(request.url)
    if (url.origin !== ORIGIN) return
    if (request.mode === "navigate") {
      const shell = shellFor(url.pathname)
      if (shell) event.respondWith(navigate(request, shell))
      return
    }
    if (ASSETS.has(url.pathname) && !url.search) event.respondWith(asset(request))
  })
})()
