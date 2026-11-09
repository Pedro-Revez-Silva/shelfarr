// Deliberate offline downloads for the browser reader and player.
//
// Media is stored only when the reader chooses Download. Each account on each
// deployment (origin and subpath) has its own Cache Storage cache and its own
// IndexedDB records, so accounts and servers never share downloads. The page
// downloads one file at a time under a Web Lock, so tabs never download the
// same book twice, and streams each response straight into the cache. A file
// counts only once the Cache API has stored all of its bytes and they match
// the edition's size and identity; a publication is ready only when every one
// of its files is. Nothing here touches cookies or credentials: requests use
// the browser's normal same-origin session.
//
// Records (store "downloads", key "<deployment>|<account>|<publication>"):
//   publication  the complete, verified edition that opens offline, or null
//   pending      an edition being downloaded (a first download or an update)
//   done         asset IDs of `pending` already stored and verified
//   error        why `pending` stopped: { kind, message }
// An update keeps the old complete copy usable until the new one is ready.

export const DB_NAME = "shelfarr-offline"
const DB_VERSION = 1
const MEDIA_PREFIX = "shelfarr-offline-media.v1"
export const SHELL_PREFIX = "shelfarr-offline-shell.v1"
export const ACCOUNT_LIMIT_BYTES = 8 * 1000 ** 3
export const RESERVE_BYTES = 64 * 1024 ** 2
const WORKER_READY_TIMEOUT = 30_000
const PROGRESS_INTERVAL = 250
// Errors after which a download can simply carry on later.
const RESUMABLE = new Set(["network", "interrupted", "account"])

export class OfflineError extends Error {
  constructor(kind, message) { super(message || MESSAGES[kind] || MESSAGES.storage); this.kind = kind }
}

export const MESSAGES = {
  network: "The connection was lost. Resume when you're back online.",
  interrupted: "The page closed before the download finished.",
  account: "Another account is signed in on this browser.",
  signin: "Sign in again to download.",
  changed: "This book changed on the server. Open it again to download the new edition.",
  missing: "This book is no longer in the library.",
  space: "There isn't enough storage on this device.",
  verify: "A file didn't arrive complete. Try again.",
  evicted: "The browser removed part of this download. Download it again.",
  storage: "This browser couldn't store the download.",
  worker: "Offline support couldn't start in this browser. Reload and try again.",
  unsupported: "This browser can't keep books for offline use."
}

// Environment ------------------------------------------------------------------

export function support(env = globalThis) {
  if (!env.isSecureContext) return { ok: false, reason: "insecure" }
  const navigator = env.navigator || {}
  if (!("serviceWorker" in navigator) || !env.caches || !env.indexedDB || typeof env.ReadableStream !== "function" || typeof env.TransformStream !== "function") {
    return { ok: false, reason: "unsupported" }
  }
  return { ok: true }
}

export const deploymentOf = (base, origin = globalThis.location.origin) => `${origin}${base || ""}`
export const scopeOf = (deployment, account) => `${deployment}|${account}`
export const recordKey = (scope, id) => `${scope}|${id}`
export const mediaCacheName = scope => `${MEDIA_PREFIX}|${scope}`
export const shellCachePrefix = deployment => `${SHELL_PREFIX}|${deployment}|`
const absolute = path => new URL(path, globalThis.location.origin).href

// The parts of a page's publication this browser keeps for offline use.
export function snapshot(publication) {
  const assets = (publication.assets || []).map(asset => ({ id: asset.id, filename: asset.filename, format: asset.format,
    media_type: asset.media_type, size_bytes: asset.size_bytes, position: asset.position, content_url: asset.content_url }))
  return { id: String(publication.id), title: publication.title || "", author: publication.author || "",
    description: String(publication.description || "").slice(0, 2000), book_type: publication.book_type,
    cover_style: publication.cover_style || "stone", reading_status: publication.reading_status || null,
    progress: publication.progress || null, progress_url: publication.progress_url,
    progress_scope: publication.progress_scope, assets }
}

export const editionOf = publication => (publication?.assets || []).map(asset => asset.id).join(",")
export const bytesOf = publication => (publication?.assets || []).reduce((sum, asset) => sum + (asset.size_bytes || 0), 0)

// Bytes the record's files occupy: its complete edition and any stored part of an update.
export function storedBytes(record) {
  const sizes = new Map()
  for (const asset of record.publication?.assets || []) sizes.set(asset.id, asset.size_bytes || 0)
  for (const asset of record.pending?.assets || []) if (record.done.includes(asset.id)) sizes.set(asset.id, asset.size_bytes || 0)
  return [...sizes.values()].reduce((sum, size) => sum + size, 0)
}

// Bytes an unfinished download still has to fetch.
export function remainingBytes(record) {
  return (record.pending?.assets || []).filter(asset => !record.done.includes(asset.id)).reduce((sum, asset) => sum + (asset.size_bytes || 0), 0)
}

// What the reader sees: downloading, paused, failed, updating or ready.
export function stateOf(record, running = false) {
  if (!record) return { kind: "none" }
  const pending = record.pending
  if (pending) {
    const total = bytesOf(pending)
    const done = pending.assets.filter(asset => record.done.includes(asset.id)).reduce((sum, asset) => sum + asset.size_bytes, 0)
    const update = Boolean(record.publication)
    const error = record.error
    const kind = running ? "downloading" : !error || RESUMABLE.has(error.kind) ? "paused" : "failed"
    return { kind, update, total, done, files: pending.assets.length, filesDone: record.done.length,
      error: running ? null : error || { kind: "interrupted", message: MESSAGES.interrupted } }
  }
  if (record.publication) return { kind: "ready", total: bytesOf(record.publication) }
  return { kind: "none" }
}

export function formatBytes(bytes) {
  if (!Number.isFinite(bytes) || bytes < 0) return "—"
  const units = ["bytes", "KB", "MB", "GB", "TB"]
  let value = bytes, unit = 0
  while (value >= 1000 && unit < units.length - 1) { value /= 1000; unit += 1 }
  if (unit === 0) return `${value} bytes`
  const text = value >= 100 ? String(Math.round(value)) : value.toFixed(1).replace(/\.0$/, "")
  return `${text} ${units[unit]}`
}

// IndexedDB ----------------------------------------------------------------------

let database
function open() {
  database ||= new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION)
    request.onupgradeneeded = () => {
      const db = request.result
      if (!db.objectStoreNames.contains("accounts")) db.createObjectStore("accounts", { keyPath: "deployment" })
      if (!db.objectStoreNames.contains("downloads")) db.createObjectStore("downloads", { keyPath: "key" }).createIndex("deployment", "deployment")
    }
    request.onsuccess = () => {
      const db = request.result
      db.onversionchange = () => { db.close(); database = null }
      resolve(db)
    }
    request.onerror = () => { database = null; reject(request.error) }
    request.onblocked = () => { database = null; reject(new OfflineError("storage")) }
  })
  return database
}

async function transaction(store, mode, work) {
  const db = await open()
  return new Promise((resolve, reject) => {
    const tx = db.transaction(store, mode)
    let result
    Promise.resolve(work(tx.objectStore(store))).then(value => { result = value }, error => { tx.abort(); reject(error) })
    tx.oncomplete = () => resolve(result)
    tx.onerror = () => reject(tx.error)
    tx.onabort = () => reject(tx.error || new OfflineError("storage"))
  })
}
const request = source => new Promise((resolve, reject) => { source.onsuccess = () => resolve(source.result); source.onerror = () => reject(source.error) })

export const getRecord = key => transaction("downloads", "readonly", store => request(store.get(key)))
const putRecord = record => transaction("downloads", "readwrite", store => request(store.put({ ...record, updatedAt: Date.now() })))
const deleteRecord = key => transaction("downloads", "readwrite", store => request(store.delete(key)))
const deploymentRecords = deployment => transaction("downloads", "readonly", store => request(store.index("deployment").getAll(deployment)))
export async function listRecords(scope) {
  const [deployment, account] = splitScope(scope)
  return (await deploymentRecords(deployment)).filter(record => record.account === account)
    .sort((left, right) => (right.completedAt || right.createdAt || 0) - (left.completedAt || left.createdAt || 0))
}
function splitScope(scope) { const index = scope.lastIndexOf("|"); return [scope.slice(0, index), scope.slice(index + 1)] }

async function updateRecord(key, change) {
  return transaction("downloads", "readwrite", async store => {
    const current = await request(store.get(key))
    const next = change(current)
    if (next) await request(store.put({ ...next, updatedAt: Date.now() }))
    else if (current) await request(store.delete(key))
    return next || null
  })
}

// The signed-in account ---------------------------------------------------------
//
// Offline pages can't ask the server who is signed in, so the account that last
// opened the reader here is remembered for its deployment. It is replaced when
// another account opens the reader, cleared when this browser shows the sign-in
// page, and lapses after the server's session lifetime.

export async function confirmAccount({ base, account, maxAgeDays }) {
  const deployment = deploymentOf(base)
  const days = Number.isFinite(maxAgeDays) && maxAgeDays > 0 ? maxAgeDays : 30
  await transaction("accounts", "readwrite", store => request(store.put({ deployment, account: String(account), confirmedAt: Date.now(), maxAgeDays: days })))
  broadcast(deployment, { type: "account" })
}

export async function clearAccount(base) {
  const deployment = deploymentOf(base)
  await transaction("accounts", "readwrite", store => request(store.delete(deployment)))
  broadcast(deployment, { type: "account" })
}

export async function activeAccount(base, now = Date.now()) {
  const record = await transaction("accounts", "readonly", store => request(store.get(deploymentOf(base))))
  if (!record) return null
  return { ...record, expired: now - record.confirmedAt > record.maxAgeDays * 86_400_000 || record.confirmedAt > now + 86_400_000 }
}

// Whether this deployment has ever been set up for downloads in this browser.
export async function hasWorker(base) {
  if (!support().ok) return false
  try { return Boolean(await navigator.serviceWorker.getRegistration(`${base}/read`)) } catch (_) { return false }
}

export async function ensureWorker(base, retried = false) {
  let registration
  try {
    registration = await navigator.serviceWorker.register(`${base}/read-offline-worker.js`, { scope: `${base}/read`, updateViaCache: "none" })
  } catch (_) { throw new OfflineError("worker") }
  const active = registration.active || await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new OfflineError("worker")), WORKER_READY_TIMEOUT)
    const worker = registration.installing || registration.waiting
    if (!worker) { clearTimeout(timer); return reject(new OfflineError("worker")) }
    worker.addEventListener("statechange", () => {
      if (worker.state === "activated") { clearTimeout(timer); resolve(worker) }
      if (worker.state === "redundant") { clearTimeout(timer); reject(new OfflineError("worker")) }
    })
  })
  // The shell must be stored too, or nothing could open offline. If the
  // browser removed it, install the worker afresh once.
  const shells = (await caches.keys()).filter(name => name.startsWith(shellCachePrefix(deploymentOf(base))))
  if (active && shells.length) return registration
  if (!retried) {
    await registration.unregister().catch(() => {})
    return ensureWorker(base, true)
  }
  throw new OfflineError("worker")
}

// Storage ------------------------------------------------------------------------

export async function storageState() {
  const manager = navigator.storage
  let estimate = null, persisted = null
  try { estimate = await manager?.estimate?.() } catch (_) { /* unavailable */ }
  try { persisted = await manager?.persisted?.() } catch (_) { /* unavailable */ }
  return { quota: estimate?.quota ?? null, usage: estimate?.usage ?? null, persisted }
}

// Asked only after a deliberate download. Browsers decide; nothing is promised.
export async function requestPersistence() {
  try { return Boolean(await navigator.storage?.persist?.()) } catch (_) { return false }
}

export function persistenceNote(persisted) {
  return persisted
    ? "This browser has agreed to keep downloads until you remove them or clear this site's data."
    : "Your browser may remove downloads if the device runs low on space or the site goes unused. Shelfarr checks them before opening."
}

// Why `needed` more bytes would not fit this account's limit or the
// browser's quota, or null when they fit.
export function spaceProblem({ records, currentKey, needed, quota, usage, limit = ACCOUNT_LIMIT_BYTES }) {
  const reserved = records.reduce((sum, record) => sum + storedBytes(record) + (record.key === currentKey ? 0 : remainingBytes(record)), 0)
  if (reserved + needed > limit) {
    return `Downloads for your account can use up to ${formatBytes(limit)} in this browser. Remove a download to make room.`
  }
  if (Number.isFinite(quota) && Number.isFinite(usage) && quota - usage < needed + RESERVE_BYTES) {
    return `This needs ${formatBytes(needed)}, but about ${formatBytes(Math.max(0, quota - usage - RESERVE_BYTES))} is free for this browser.`
  }
  return null
}

export async function checkSpace(scope, needed, currentKey) {
  const { quota, usage } = await storageState()
  const problem = spaceProblem({ records: await listRecords(scope), currentKey, needed, quota, usage })
  if (problem) throw new OfflineError("space", problem)
}

// Whether every file of the complete edition is still in the cache.
export async function verify(record) {
  if (!record?.publication) return false
  if (!await caches.has(mediaCacheName(record.scope))) return false
  const cache = await caches.open(mediaCacheName(record.scope))
  const stored = new Set((await cache.keys()).map(entry => entry.url))
  return record.publication.assets.every(asset => stored.has(absolute(asset.content_url)))
}

// After the browser evicted files: keep no false "ready" state.
export async function markEvicted(record) {
  const next = await updateRecord(record.key, current => current && current.publication
    ? { ...current, pending: current.pending || current.publication, publication: null, done: [], error: { kind: "evicted", message: MESSAGES.evicted } }
    : current)
  notify(record.key)
  return next
}

// Cross-tab coordination --------------------------------------------------------

const events = new EventTarget()
const channels = new Map()
const running = new Map()
let progressTimer = null

function channel(deployment) {
  if (typeof BroadcastChannel !== "function") return null
  if (!channels.has(deployment)) {
    const created = new BroadcastChannel(`shelfarr-offline|${deployment}`)
    created.onmessage = event => receive(event.data)
    channels.set(deployment, created)
  }
  return channels.get(deployment)
}
function broadcast(deployment, message) { try { channel(deployment)?.postMessage(message) } catch (_) { /* other tabs refresh on focus */ } }

function receive(message) {
  if (!message || typeof message !== "object") return
  if (message.type === "cancel" && running.has(message.key)) running.get(message.key).stop("cancel")
  if (message.type === "progress") { remoteProgress.set(message.key, message); emit("progress", message) }
  if (message.type === "changed" || message.type === "account") { remoteProgress.delete(message.key); emit("change", message) }
}
const remoteProgress = new Map()

function emit(type, detail) { events.dispatchEvent(new CustomEvent(type, { detail })) }
export function subscribe(deployment, handler) {
  channel(deployment)
  const listener = event => handler(event.type, event.detail)
  events.addEventListener("change", listener)
  events.addEventListener("progress", listener)
  return () => { events.removeEventListener("change", listener); events.removeEventListener("progress", listener) }
}

function notify(key) {
  const deployment = key.split("|")[0]
  emit("change", { key })
  broadcast(deployment, { type: "changed", key })
}

// The bytes in flight for a download in this or another tab.
export function liveProgress(key) {
  const local = running.get(key)
  if (local) return { key, received: local.received, running: true }
  return remoteProgress.get(key) || null
}

async function lockHeld(key) {
  if (running.has(key)) return true
  try {
    const state = await navigator.locks?.query?.()
    return Boolean(state?.held?.some(lock => lock.name === lockName(key)))
  } catch (_) { return false }
}
export const isRunning = key => lockHeld(key)
const lockName = key => `shelfarr-offline|${key}`

async function withLock(key, options, work) {
  if (!navigator.locks?.request) {
    if (options.ifAvailable && running.has(key)) return work(null)
    return work(true)
  }
  return navigator.locks.request(lockName(key), options, work)
}

// Downloading --------------------------------------------------------------------

// Start, resume or update a download for this page's publication.
export async function download(publication) {
  if (!support().ok) throw new OfflineError("unsupported")
  const scopeInfo = publication.progress_scope || {}
  const base = scopeInfo.base || ""
  const deployment = deploymentOf(base)
  const account = String(scopeInfo.account)
  const scope = scopeOf(deployment, account)
  const key = recordKey(scope, publication.id)
  const next = snapshot(publication)
  await ensureWorker(base)
  const active = await activeAccount(base)
  if (!active || active.expired || active.account !== account) throw new OfflineError("account")
  const existing = await getRecord(key)
  const now = Date.now()
  const common = { key, scope, deployment, account, id: next.id, createdAt: existing?.createdAt || now, gone: false, latest: null }
  // The same complete edition only needs its details refreshed.
  if (existing?.publication && editionOf(existing.publication) === editionOf(next) && await verify(existing)) {
    await putRecord({ ...existing, ...common, publication: { ...existing.publication, ...next, progress: newerProgress(existing.publication.progress, next.progress) }, pending: null, done: [], error: null })
    notify(key)
    return key
  }
  const stored = await storedUrls(scope)
  const done = next.assets.filter(asset => stored.has(absolute(asset.content_url))).map(asset => asset.id)
  const needed = next.assets.filter(asset => !done.includes(asset.id)).reduce((sum, asset) => sum + asset.size_bytes, 0)
  await checkSpace(scope, needed, key)
  // An update keeps the previous complete edition readable until it finishes.
  const previous = existing?.publication && editionOf(existing.publication) !== editionOf(next) ? existing.publication : null
  await putRecord({ ...common, publication: previous, pending: next, done, error: null, completedAt: existing?.completedAt || null })
  notify(key)
  run(key)
  return key
}

function newerProgress(left, right) {
  if (!left) return right || null
  if (!right) return left
  return (right.version || 0) > (left.version || 0) ? right : left
}

async function storedUrls(scope) {
  if (!await caches.has(mediaCacheName(scope))) return new Set()
  const cache = await caches.open(mediaCacheName(scope))
  return new Set((await cache.keys()).map(entry => entry.url))
}

// Resume a paused or failed download from the files it still needs.
export async function resume(key) {
  const record = await getRecord(key)
  if (!record?.pending) return
  await updateRecord(key, current => current && { ...current, error: null })
  notify(key)
  run(key)
}

class EditionChanged extends Error {}

function run(key) {
  return withLock(key, { ifAvailable: true }, async lock => {
    if (!lock) return
    const controller = new AbortController()
    const job = { received: 0, reason: null, stop: reason => { job.reason = reason; controller.abort() } }
    running.set(key, job)
    notify(key)
    let restart = false
    let pending = null
    let cache = null
    try {
      let record = await getRecord(key)
      if (!record?.pending) return
      const edition = editionOf(record.pending)
      pending = record.pending
      const current = change => updateRecord(key, stored => {
        if (!stored?.pending || editionOf(stored.pending) !== edition) throw new EditionChanged()
        return change(stored)
      })
      cache = await caches.open(mediaCacheName(record.scope))
      const stored = new Set((await cache.keys()).map(entry => entry.url))
      // IndexedDB may still remember files the browser evicted while paused.
      // Rebuild completion under the download lock before skipping any file.
      record = await current(saved => ({ ...saved, done: saved.pending.assets.filter(asset => stored.has(absolute(asset.content_url))).map(asset => asset.id) }))
      await checkSpace(record.scope, record.pending.assets.filter(asset => !record.done.includes(asset.id)).reduce((sum, asset) => sum + asset.size_bytes, 0), key)
      for (const asset of record.pending.assets) {
        if (record.done.includes(asset.id)) continue
        if (!stored.has(absolute(asset.content_url))) {
          const active = await activeAccount(record.deployment.slice(globalThis.location.origin.length))
          if (!active || active.expired || active.account !== record.account) throw new OfflineError("account")
          await store(cache, asset, controller.signal, bytes => { job.received += bytes; reportProgress(key, job) })
        }
        job.received = 0
        record = await current(saved => ({ ...saved, done: [...new Set([...saved.done, asset.id])] }))
        notify(key)
      }
      if (!await verify({ scope: record.scope, publication: record.pending })) throw new OfflineError("evicted")
      const previous = record.publication
      record = await current(saved => ({ ...saved, publication: saved.pending, pending: null, done: [], error: null, completedAt: Date.now() }))
      // Files only the replaced edition used are no longer needed.
      const kept = new Set(record.publication.assets.map(asset => asset.id))
      for (const asset of previous?.assets || []) if (!kept.has(asset.id)) await cache.delete(absolute(asset.content_url))
    } catch (error) {
      if (error instanceof EditionChanged) {
        restart = true
        // A superseded in-flight response may already have reached the cache.
        // Keep everything used by the current complete/pending editions.
        try {
          const latest = await getRecord(key)
          const kept = new Set([...(latest?.publication?.assets || []), ...(latest?.pending?.assets || [])].map(asset => absolute(asset.content_url)))
          for (const asset of pending?.assets || []) if (!kept.has(absolute(asset.content_url))) await cache?.delete(absolute(asset.content_url))
        } catch (_) { /* Cleanup cannot prevent the selected edition from starting; its runner reports storage failures. */ }
      } else {
        if (job.reason === "cancel" || job.reason === "remove") return
        const failure = error instanceof OfflineError ? error : error?.name === "QuotaExceededError" ? new OfflineError("space")
          : error?.name === "AbortError" || error instanceof TypeError ? new OfflineError("network") : new OfflineError("storage")
        await updateRecord(key, stored => stored?.pending ? { ...stored, error: { kind: failure.kind, message: failure.message } } : stored).catch(() => {})
      }
    } finally {
      running.delete(key)
      clearTimeout(progressTimer)
      progressTimer = null
      notify(key)
    }
    return restart
  }).then(restart => {
    // Web Locks releases the previous lock before resolving this promise.
    // Starting inside its callback could lose an ifAvailable acquisition.
    if (restart) return run(key)
  })
}

function reportProgress(key, job) {
  if (progressTimer) return
  progressTimer = setTimeout(() => {
    progressTimer = null
    const message = { type: "progress", key, received: job.received, running: true }
    emit("progress", message)
    broadcast(key.split("|")[0], message)
  }, PROGRESS_INTERVAL)
}

// Stream one file into the cache and keep it only if it arrived whole.
async function store(cache, asset, signal, onBytes) {
  const url = absolute(asset.content_url)
  const response = await fetch(url, { credentials: "same-origin", redirect: "manual", cache: "no-store", signal })
  if (response.type === "opaqueredirect" || response.status === 401 || response.status === 403) throw new OfflineError("signin")
  if (response.status === 410) throw new OfflineError("changed")
  if (response.status === 404) throw new OfflineError("missing")
  if (response.status >= 500) throw new OfflineError("network")
  if (response.status !== 200 || !response.body) throw new OfflineError("verify")
  const etag = response.headers.get("ETag")
  if (etag && etag !== `"${asset.id}"`) throw new OfflineError("changed")
  const length = response.headers.get("Content-Length")
  if (length !== null && Number(length) !== asset.size_bytes) throw new OfflineError("changed")
  let received = 0
  const counted = response.body.pipeThrough(new TransformStream({
    transform(chunk, stream) { received += chunk.byteLength; onBytes(chunk.byteLength); stream.enqueue(chunk) }
  }), { signal })
  await cache.put(url, new Response(counted, { status: 200, headers: {
    "Content-Type": asset.media_type, "Content-Length": String(asset.size_bytes), "ETag": `"${asset.id}"`, "X-Shelfarr-Asset": asset.id
  } }))
  if (received !== asset.size_bytes) {
    await cache.delete(url)
    throw new OfflineError("verify")
  }
}

// Stop a download and discard what it stored. An update's older copy stays.
export async function cancel(key) {
  running.get(key)?.stop("cancel")
  broadcast(key.split("|")[0], { type: "cancel", key })
  await withLock(key, {}, async () => {
    const record = await getRecord(key)
    if (!record?.pending) return
    const cache = await caches.open(mediaCacheName(record.scope))
    const kept = new Set((record.publication?.assets || []).map(asset => asset.id))
    for (const asset of record.pending.assets) if (!kept.has(asset.id)) await cache.delete(absolute(asset.content_url))
    await updateRecord(key, current => current?.publication ? { ...current, pending: null, done: [], error: null } : null)
  })
  notify(key)
}

export async function remove(key) {
  running.get(key)?.stop("remove")
  broadcast(key.split("|")[0], { type: "cancel", key })
  await withLock(key, {}, async () => {
    const record = await getRecord(key)
    if (!record) return
    const cache = await caches.open(mediaCacheName(record.scope))
    for (const asset of [...(record.publication?.assets || []), ...(record.pending?.assets || [])]) await cache.delete(absolute(asset.content_url))
    await deleteRecord(key)
  })
  notify(key)
}

export async function removeAll(scope) {
  for (const record of await listRecords(scope)) await remove(record.key)
  await caches.delete(mediaCacheName(scope))
}

// Downloads other accounts made on this deployment in this browser: their size
// only, never their titles.
export async function otherAccounts(deployment, account) {
  const records = (await deploymentRecords(deployment)).filter(record => record.account !== String(account))
  return { count: records.length, bytes: records.reduce((sum, record) => sum + storedBytes(record), 0), scopes: [...new Set(records.map(record => record.scope))] }
}

export async function removeOtherAccounts(deployment, account) {
  const { scopes } = await otherAccounts(deployment, account)
  for (const scope of scopes) {
    for (const record of await listRecords(scope)) {
      broadcast(deployment, { type: "cancel", key: record.key })
      await deleteRecord(record.key)
    }
    await caches.delete(mediaCacheName(scope))
  }
  emit("change", {})
  broadcast(deployment, { type: "changed" })
}

// Server facts --------------------------------------------------------------------

// Keep the newest saved place the server confirmed, so an offline visit opens
// there even after this browser's outbox has emptied.
export async function rememberProgress(key, progress, readingStatus) {
  if (!progress || !Number.isInteger(progress.version)) return
  const newer = current => !current || !current.progress || (current.progress.version || 0) < progress.version
  await updateRecord(key, record => {
    if (!record) return record
    const apply = publication => publication && newer(publication)
      ? { ...publication, progress, reading_status: readingStatus || publication.reading_status } : publication
    return { ...record, publication: apply(record.publication), pending: apply(record.pending) }
  })
}

// Compare downloads with the library: a newer edition, a removed title and
// the latest saved places.
export async function refresh(records, url, account) {
  const ids = records.map(record => record.id)
  if (!ids.length) return records
  const response = await fetch(`${url}?ids=${ids.slice(0, 50).join(",")}`, { credentials: "same-origin", headers: { Accept: "application/json" }, cache: "no-store", redirect: "manual" })
  if (!response.ok) return records
  const body = await response.json()
  if (String(body.account) !== String(account)) return records
  const current = new Map(body.publications.map(publication => [String(publication.id), publication]))
  for (const record of records) {
    const latest = current.get(record.id)
    await updateRecord(record.key, stored => {
      if (!stored) return stored
      if (!latest) return { ...stored, gone: body.missing.includes(record.id), latest: null }
      const known = stored.publication || stored.pending
      const changed = editionOf(latest) !== editionOf(known)
      return { ...stored, gone: false, latest: changed && latest.offline?.supported ? snapshot(latest) : null }
    })
    if (latest?.progress) await rememberProgress(record.key, latest.progress, latest.reading_status)
  }
  return Promise.all(records.map(record => getRecord(record.key)))
}
