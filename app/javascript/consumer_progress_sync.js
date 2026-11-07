// Durable progress outbox for the browser reader and player.
//
// Each checkpoint is persisted in this browser, under a key bound to the
// account, origin, deployment subpath and publication, before any network
// work. A write leaves as an immutable request: an uncertain retry repeats the
// same place, observed_at, mutation UUID and resolution flag. After a definite
// conflict, the later observation wins automatically when both activity times
// are known; equal, unknown or unmappable cases wait for an explicit choice.
// Rejected writes keep the local place. A reload, reconnect or new tab resumes
// whatever is still waiting.

const STORAGE_PREFIX = "shelfarr.progress.v1"
const RETRY_DELAYS = [2000, 5000, 15000, 30000, 60000]
const MAX_AUTOMATIC_REBASES = 5
const PLACE_KEYS = ["asset_id", "locator", "position_seconds"]

export function parseObservedAt(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(value)) return null
  const time = Date.parse(value)
  return Number.isFinite(time) ? time : null
}

function placeOf(source) {
  const place = {}
  for (const key of PLACE_KEYS) if (source[key] !== undefined && source[key] !== null) place[key] = source[key]
  return place
}

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical)
  if (value && typeof value === "object") return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]))
  return value
}

export function samePlace(left, right) {
  return JSON.stringify(canonical(placeOf(left))) === JSON.stringify(canonical(placeOf(right)))
}

export default class ConsumerProgressSync {
  constructor({ url, account, base = "", publication, version = 0, assets = [], storage, now = () => Date.now(),
    onStatus = () => {}, onConflict = () => {}, onRemote = () => {}, syncDelay = 5000, retryDelays = RETRY_DELAYS }) {
    const endpoint = new URL(url, window.location.href)
    if (endpoint.origin !== window.location.origin) throw new Error("Invalid progress endpoint")
    if (!account || !publication) throw new Error("Progress needs an account and publication")
    this.url = endpoint.href
    this.key = [STORAGE_PREFIX, window.location.origin + base, account, publication].map(encodeURIComponent).join("|")
    this.identity = { account: String(account), origin: window.location.origin, base, publication: String(publication) }
    this.serverVersion = version || 0
    this.assets = new Set(assets)
    this.now = now
    this.onStatus = onStatus
    this.onConflict = onConflict
    this.onRemote = onRemote
    this.syncDelay = syncDelay
    this.retryDelays = retryDelays
    this.failures = 0
    this.rebases = 0
    try { this.storage = storage === undefined ? window.localStorage : storage } catch (_) { this.storage = null }
    this.memory = null
    try {
      this.storage?.setItem(`${this.key}|probe`, "1")
      this.storage?.removeItem(`${this.key}|probe`)
    } catch (_) { this.storageFailed = true }
    if (!this.storage) this.storageFailed = true
    this.onlineHandler = () => this.flush()
    window.addEventListener?.("online", this.onlineHandler)
  }

  // The place to show when opening: a waiting local checkpoint unless the
  // server holds a later observation of the same edition.
  restorePlace(server) {
    const record = this.load()
    const local = this.newestLocal(record)
    if (!local || !this.assets.has(local.place.asset_id)) return server ? { source: "server", progress: server } : null
    const pendingId = record.pending?.body.client_mutation_id
    if (!server || server.version <= record.base || (pendingId && server.client_mutation_id === pendingId)) return { source: "local", progress: local.place, observedAt: local.observedAt }
    const remoteTime = parseObservedAt(server.observed_at)
    const localTime = parseObservedAt(local.observedAt)
    if (remoteTime !== null && localTime !== null && remoteTime > localTime) return { source: "server", progress: server }
    return { source: "local", progress: local.place, observedAt: local.observedAt }
  }

  // False when this browser refuses to keep the outbox across a reload.
  get durable() { return !this.storageFailed }
  get blocked() { return Boolean(this.load().conflict) }
  get conflict() { return this.load().conflict }
  get waiting() { const record = this.load(); return Boolean(record.latest || (record.pending && record.pending.state !== "rejected")) }

  // Persist a genuine new observation. Network work happens later.
  record(place, observedAt = new Date(this.now()).toISOString()) {
    if (this.closed) return false
    const record = this.load()
    if (record.pending?.state === "rejected") record.pending = null
    record.latest = { place: placeOf(place), observedAt }
    const stored = this.persist(record)
    if (record.conflict) this.status("conflict")
    else {
      this.status(stored ? "local" : "storage")
      this.schedule(this.syncDelay)
    }
    return stored
  }

  flush() {
    if (this.closed) return Promise.resolve()
    if (this.inflight) { this.again = true; return this.inflight }
    clearTimeout(this.timer)
    this.timer = null
    this.inflight = this.send().finally(() => {
      this.inflight = null
      if (this.closing && !this.again) this.finishClose()
      else if (this.again) { this.again = false; this.flush() }
    })
    return this.inflight
  }

  retry() {
    const record = this.load()
    if (record.pending?.state === "rejected") { record.pending.state = "sending"; this.persist(record) }
    this.failures = 0
    return this.flush()
  }

  // Explicit "keep this device": a new choice with its own time and intent,
  // persisted before it is sent.
  keepLocal() {
    const record = this.load()
    const local = this.newestLocal(record)
    if (!record.conflict || !local) return Promise.resolve()
    record.pending = { state: "sending", body: { ...local.place, observed_at: new Date(this.now()).toISOString(),
      resolve_conflict: true, expected_version: record.conflict.remote?.version || 0, client_mutation_id: crypto.randomUUID() } }
    record.base = record.conflict.remote?.version || 0
    record.latest = null
    record.conflict = null
    this.rebases = 0
    this.persist(record)
    return this.flush()
  }

  // Explicit "use the other device's place": local writes are discarded.
  useRemote() {
    const record = this.load()
    const remote = record.conflict?.remote || null
    this.persist({ base: remote?.version || 0, pending: null, latest: null, conflict: null })
    return remote
  }

  close() {
    clearTimeout(this.timer)
    this.timer = null
    this.closing = true
    window.removeEventListener?.("online", this.onlineHandler)
    if (this.inflight) return this.inflight
    const record = this.load()
    // One last keepalive attempt, unless this visit is already known offline;
    // anything unsent stays in the outbox for the next visit.
    if (!record.conflict && !this.failures && (record.latest || record.pending?.state === "sending")) return this.flush().then(() => this.finishClose())
    this.finishClose()
    return Promise.resolve()
  }

  finishClose() { this.closed = true; clearTimeout(this.timer); this.timer = null }

  // Internal ------------------------------------------------------------------

  newestLocal(record) {
    if (record.latest) return record.latest
    if (record.pending) return { place: placeOf(record.pending.body), observedAt: record.pending.body.observed_at }
    return null
  }

  schedule(delay) {
    if (this.closed || this.timer) return
    this.timer = setTimeout(() => { this.timer = null; this.flush() }, delay)
  }

  async send() {
    let record = this.load()
    if (record.conflict) return this.status("conflict")
    if (!record.pending || record.pending.state === "rejected") {
      if (!record.latest) return record.pending ? this.status("rejected", record.pending.error) : undefined
      record.pending = { state: "sending", body: { ...record.latest.place, observed_at: record.latest.observedAt,
        expected_version: record.base, client_mutation_id: crypto.randomUUID() } }
      record.latest = null
      this.persist(record)
    }
    const body = record.pending.body
    this.status("syncing")
    let response, result = null
    try {
      response = await fetch(this.url, {
        method: "PUT", credentials: "same-origin", redirect: "manual", keepalive: true,
        headers: { "Content-Type": "application/json", "Accept": "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "" },
        body: JSON.stringify(body)
      })
      try { result = await response.json() } catch (_) { result = null }
    } catch (_) {
      return this.uncertain("offline")
    }
    record = this.load()
    // Another tab may have finished or replaced this write meanwhile.
    if (!record.pending || record.pending.body.client_mutation_id !== body.client_mutation_id) return
    if (response.type === "opaqueredirect" || response.status === 401) return this.notApplied(record, "signin")
    if (response.ok && result?.progress) return this.accepted(record, result.progress)
    if (response.status === 409 && result?.error === "progress_conflict") return this.reconcile(record, result.progress || null)
    if ((response.status === 422 && result?.error === "invalid_progress") || response.status === 404) {
      record.pending.state = "rejected"
      record.pending.error = typeof result?.message === "string" ? result.message : null
      this.persist(record)
      return this.status("rejected", record.pending.error)
    }
    return this.uncertain(response.status === 403 || response.status === 422 ? "reload" : "offline")
  }

  accepted(record, progress) {
    this.failures = 0
    this.rebases = 0
    this.serverVersion = progress.version
    record.base = progress.version
    record.pending = null
    this.persist(record)
    if (record.latest) { this.status("local"); this.again = true } else this.status("saved")
  }

  notApplied(record, kind) {
    record.pending.state = "sending"
    this.persist(record)
    this.status(kind)
  }

  uncertain(kind) {
    const delay = this.retryDelays[Math.min(this.failures, this.retryDelays.length - 1)]
    this.failures += 1
    this.status(kind)
    if (!this.closing) this.schedule(delay)
  }

  reconcile(record, remote) {
    this.failures = 0
    const local = this.newestLocal(record)
    const localTime = parseObservedAt(local.observedAt)
    const remoteTime = remote ? parseObservedAt(remote.observed_at) : null
    const mappable = !remote || this.assets.has(remote.asset_id)
    const rebase = version => {
      this.rebases += 1
      record.pending = { state: "sending", body: { ...local.place, observed_at: local.observedAt, expected_version: version, client_mutation_id: crypto.randomUUID() } }
      record.base = version
      record.latest = null
      this.persist(record)
      this.again = true
    }
    if (this.rebases < MAX_AUTOMATIC_REBASES && mappable && localTime !== null) {
      if (!remote) return rebase(0)
      if (remoteTime !== null && localTime > remoteTime) return rebase(remote.version)
      if (remoteTime !== null && (remoteTime > localTime || samePlace(local.place, remote))) {
        this.rebases = 0
        this.serverVersion = remote.version
        this.persist({ base: remote.version, pending: null, latest: null, conflict: null })
        this.status("saved")
        return this.onRemote(remote)
      }
    }
    this.rebases = 0
    record.conflict = { remote }
    this.persist(record)
    this.status("conflict")
    this.onConflict(remote)
  }

  load() {
    // Storage is the source of truth so tabs share one outbox. This visit's
    // copy is used only while the browser refuses to store it.
    let record = this.memory
    if (this.storage && !this.storageFailed) {
      try {
        const raw = this.storage.getItem(this.key)
        const parsed = raw ? JSON.parse(raw) : null
        const identity = parsed?.identity
        record = identity && identity.account === this.identity.account && identity.publication === this.identity.publication &&
          identity.origin === this.identity.origin && identity.base === this.identity.base ? parsed : null
      } catch (_) { /* unreadable: keep this visit's copy */ }
    }
    record = record ? structuredClone(record) : {}
    record.base = Number.isInteger(record.base) ? Math.max(record.base, 0) : this.serverVersion
    record.pending ||= null
    record.latest ||= null
    record.conflict ||= null
    return record
  }

  persist(record) {
    const empty = !record.pending && !record.latest && !record.conflict
    const value = { identity: this.identity, base: record.base, pending: record.pending, latest: record.latest, conflict: record.conflict, savedAt: new Date(this.now()).toISOString() }
    this.memory = empty ? null : structuredClone(value)
    if (!this.storage) { this.storageFailed = true; return false }
    try {
      if (empty) this.storage.removeItem(this.key)
      else this.storage.setItem(this.key, JSON.stringify(value))
      this.storageFailed = false
      return true
    } catch (_) {
      this.storageFailed = true
      return false
    }
  }

  status(kind, detail = null) {
    if (this.storageFailed && kind !== "conflict") kind = kind === "saved" ? "saved" : "storage"
    this.onStatus(kind, detail)
  }
}

// Listening checkpoints: playback saves at most every five seconds, and pause,
// seek, track change and leaving save at once. A genuine resume rewinds five
// seconds within the track, and the rewound span is not recorded until
// playback passes the original place again, so the saved place is preserved.
export class ListeningCheckpoints {
  static INTERVAL = 5000
  static REWIND = 5

  constructor({ record, now = () => Date.now() }) {
    this.record = record
    this.now = now
    this.last = null
    this.lastAt = -Infinity
    this.floor = null
    this.skipRewind = false
    this.active = false
  }

  // Restoring a saved or local place is not new activity.
  restored(position, assetId) {
    this.last = { asset_id: assetId, position_seconds: position }
    this.floor = null
  }

  // Returns the position to start from for a genuine resume.
  resume(position) {
    this.active = true
    if (this.skipRewind) { this.skipRewind = false; return position }
    const rewound = Math.max(0, position - ListeningCheckpoints.REWIND)
    this.floor = rewound < position ? position : null
    return rewound
  }

  // Seeking or choosing a track is deliberate: it is saved, and the next play
  // starts exactly there.
  deliberate(position, assetId, paused) {
    this.floor = null
    if (paused) this.skipRewind = true
    this.active = true
    this.save(position, assetId)
  }

  // A natural transition to the next track keeps playing without a rewind.
  continued(assetId) {
    this.floor = null
    this.active = true
    this.save(0, assetId)
  }

  tick(position, assetId) {
    if (!this.active || this.now() - this.lastAt < ListeningCheckpoints.INTERVAL - 1000) return false
    return this.save(position, assetId)
  }

  // Pause, leaving, or hiding the page.
  settle(position, assetId) {
    if (!this.active) return false
    return this.save(position, assetId)
  }

  save(position, assetId) {
    if (this.floor !== null) {
      if (position < this.floor) return false
      this.floor = null
    }
    const place = { asset_id: assetId, position_seconds: Math.max(0, position) }
    if (this.last && this.last.asset_id === place.asset_id && Math.abs(this.last.position_seconds - place.position_seconds) < 0.5) return false
    this.last = place
    this.lastAt = this.now()
    this.record(place)
    return true
  }
}
