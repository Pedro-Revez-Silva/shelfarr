import { expect, test } from "bun:test"
import { ACCOUNT_LIMIT_BYTES, RESERVE_BYTES, bytesOf, editionOf, formatBytes, mediaCacheName, recordKey, remainingBytes, scopeOf,
  snapshot, spaceProblem, stateOf, storedBytes, support } from "../../app/javascript/consumer_offline.js"

// The worker is a classic script; load it once with a minimal worker global.
const listeners = {}
globalThis.self = { location: { origin: "https://reader.example", href: "https://reader.example/shelf/read-offline-worker.js" },
  registration: { scope: "https://reader.example/shelf/read" }, addEventListener: (name, handler) => { listeners[name] = handler },
  SHELFARR_OFFLINE: { version: "v1", shell: "/shelf/read/offline", assets: ["/shelf/assets/consumer-abc.css"] } }
await import("../../app/javascript/consumer_offline_worker.js")
const worker = globalThis.self.ShelfarrOfflineWorker

const asset = (id, size) => ({ id: id.repeat(64), filename: `${id}.mp3`, format: "mp3", media_type: "audio/mpeg", size_bytes: size, position: 0, content_url: `/read/1/assets/${id.repeat(64)}` })
const publication = (...assets) => ({ id: "1", title: "A story", book_type: "audiobook", assets })

test("offline support needs a secure context and the storage APIs", () => {
  const capable = { isSecureContext: true, navigator: { serviceWorker: {} }, caches: {}, indexedDB: {}, ReadableStream, TransformStream }
  expect(support(capable)).toEqual({ ok: true })
  expect(support({ ...capable, isSecureContext: false })).toEqual({ ok: false, reason: "insecure" })
  expect(support({ ...capable, caches: undefined })).toEqual({ ok: false, reason: "unsupported" })
  expect(support({ ...capable, navigator: {} })).toEqual({ ok: false, reason: "unsupported" })
})

test("downloads are keyed by deployment, account and publication", () => {
  const one = scopeOf("https://reader.example/shelf", "1")
  const two = scopeOf("https://reader.example/shelf", "2")
  const root = scopeOf("https://reader.example", "1")
  expect(new Set([mediaCacheName(one), mediaCacheName(two), mediaCacheName(root)]).size).toBe(3)
  expect(recordKey(one, "7")).toBe("https://reader.example/shelf|1|7")
})

test("a snapshot keeps only what the reader needs offline", () => {
  const kept = snapshot({ ...publication(asset("a", 10)), description: "x".repeat(5000), progress_scope: { account: "1", base: "" }, cover_url: "https://example.invalid/cover.jpg", secret: "no" })
  expect(kept.description.length).toBe(2000)
  expect(kept).not.toHaveProperty("secret")
  expect(kept).not.toHaveProperty("cover_url")
  expect(kept.assets[0]).toEqual(asset("a", 10))
})

test("states are ready only when every file of an edition is stored", () => {
  const first = publication(asset("a", 100), asset("b", 300))
  expect(stateOf(null)).toEqual({ kind: "none" })
  expect(stateOf({ publication: null, pending: first, done: [], error: null }, true)).toMatchObject({ kind: "downloading", done: 0, total: 400, update: false })
  const interrupted = stateOf({ publication: null, pending: first, done: [first.assets[0].id], error: null }, false)
  expect(interrupted).toMatchObject({ kind: "paused", done: 100, total: 400, filesDone: 1, files: 2 })
  expect(interrupted.error.kind).toBe("interrupted")
  expect(stateOf({ publication: null, pending: first, done: [], error: { kind: "network" } }).kind).toBe("paused")
  expect(stateOf({ publication: null, pending: first, done: [], error: { kind: "changed" } }).kind).toBe("failed")
  expect(stateOf({ publication: null, pending: first, done: [], error: { kind: "evicted" } }).kind).toBe("failed")
  expect(stateOf({ publication: first, pending: null, done: [] })).toEqual({ kind: "ready", total: 400 })
  const update = stateOf({ publication: first, pending: publication(asset("a", 100), asset("c", 50)), done: [], error: null }, true)
  expect(update).toMatchObject({ kind: "downloading", update: true, total: 150 })
})

test("stored bytes count shared files once and only finished parts of an update", () => {
  const first = publication(asset("a", 100), asset("b", 300))
  const next = publication(asset("a", 100), asset("c", 50))
  expect(storedBytes({ publication: first, pending: next, done: [] })).toBe(400)
  expect(storedBytes({ publication: first, pending: next, done: [asset("a", 0).id, asset("c", 0).id] })).toBe(450)
  expect(remainingBytes({ publication: first, pending: next, done: [asset("a", 0).id] })).toBe(50)
  expect(bytesOf(first)).toBe(400)
  expect(editionOf(first)).not.toBe(editionOf(next))
})

test("downloads stay within the account limit and the browser's quota", () => {
  const big = { key: "k1", publication: publication(asset("a", ACCOUNT_LIMIT_BYTES - 1000)), pending: null, done: [] }
  expect(spaceProblem({ records: [big], currentKey: "k2", needed: 999, quota: null, usage: null })).toBeNull()
  expect(spaceProblem({ records: [big], currentKey: "k2", needed: 1001, quota: null, usage: null })).toContain("up to 8 GB")
  // An unfinished download elsewhere reserves what it still needs.
  const waiting = { key: "k3", publication: null, pending: publication(asset("b", 2000)), done: [] }
  expect(spaceProblem({ records: [big, waiting], currentKey: "k2", needed: 1, quota: null, usage: null })).toContain("Remove a download")
  // Resuming the same download doesn't count its own remainder twice.
  expect(spaceProblem({ records: [waiting], currentKey: "k3", needed: 2000, quota: null, usage: null })).toBeNull()
  expect(spaceProblem({ records: [], currentKey: "k", needed: 10, quota: RESERVE_BYTES + 9, usage: 0 })).toContain("free for this browser")
  expect(spaceProblem({ records: [], currentKey: "k", needed: 10, quota: RESERVE_BYTES + 10, usage: 0 })).toBeNull()
})

test("sizes read naturally", () => {
  expect(formatBytes(512)).toBe("512 bytes")
  expect(formatBytes(32_513)).toBe("32.5 KB")
  expect(formatBytes(8_000_000_000)).toBe("8 GB")
  expect(formatBytes(123_400_000)).toBe("123 MB")
})

test("the worker serves single byte ranges like the server", () => {
  expect(worker.parseRange(null, 100)).toBeNull()
  expect(worker.parseRange("bytes=0-9", 100)).toEqual({ start: 0, end: 9 })
  expect(worker.parseRange("bytes=90-", 100)).toEqual({ start: 90, end: 99 })
  expect(worker.parseRange("bytes=-10", 100)).toEqual({ start: 90, end: 99 })
  expect(worker.parseRange("bytes=95-500", 100)).toEqual({ start: 95, end: 99 })
  for (const invalid of ["bytes=100-", "bytes=-0", "bytes=-", "bytes=5-2", "bytes=0-1,4-5", "items=0-1"]) expect(worker.parseRange(invalid, 100)).toBe("invalid")
  expect(worker.parseRange("bytes=0-", 0)).toBe("invalid")
})

test("the worker answers only reader pages, downloaded media and its precached assets under the subpath", () => {
  expect(worker.BASE).toBe("/shelf")
  for (const path of ["/shelf/read", "/shelf/read/", "/shelf/read/12", "/shelf/read/downloads", "/shelf/read/offline"]) expect(worker.PAGE.test(path)).toBe(true)
  for (const path of ["/read", "/shelf/read/12/progress", "/shelf/read/offline/account", "/shelf/read/0", "/shelf/session/new", "/shelf/consumer/connect", "/shelf/read-offline-worker.js"]) expect(worker.PAGE.test(path)).toBe(false)
  expect(worker.MEDIA.test(`/shelf/read/12/assets/${"a".repeat(64)}`)).toBe(true)
  for (const path of [`/read/12/assets/${"a".repeat(64)}`, `/shelf/api/consumer/v1/library/12/assets/${"a".repeat(64)}`, `/shelf/read/12/assets/${"a".repeat(64)}/transfer`]) expect(worker.MEDIA.test(path)).toBe(false)
  expect([...worker.ASSETS]).toEqual(["/shelf/assets/consumer-abc.css"])
})

test("the worker leaves writes, other origins and unlisted routes to the network", () => {
  const answered = []
  const fetch = (url, init = {}) => listeners.fetch({
    request: { url: `https://reader.example${url}`, method: init.method || "GET", mode: init.mode || "cors", headers: new Headers(init.headers || {}) },
    respondWith: response => answered.push([url, response])
  })
  fetch("/shelf/read/1/progress", { method: "PUT" })
  fetch("/shelf/read/offline/account", { headers: { Accept: "application/json" } })
  fetch("/shelf/consumer/connect", { mode: "navigate" })
  fetch("/shelf/session/new", { mode: "navigate" })
  fetch("/shelf/api/consumer/v1/auth/token", { method: "POST" })
  fetch("/shelf/assets/application-123.js")
  listeners.fetch({ request: { url: "https://elsewhere.example/shelf/read", method: "GET", mode: "navigate", headers: new Headers() }, respondWith: () => answered.push("other") })
  expect(answered).toEqual([])
})
