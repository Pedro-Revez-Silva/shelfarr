// Durable progress outbox for the browser reader and player.
//
// Every checkpoint is stored in this browser before any network work, under
// keys bound to the account, origin, deployment subpath and publication. Tabs
// share the outbox without a lock: localStorage only makes single operations
// atomic, so nothing here reads, changes and rewrites a shared value. Each
// observation, request, server fact, conflict or rejection is its own
// immutable entry, written once under a new key. State is folded from all
// entries, and an entry is removed only after a durable entry that supersedes
// it exists, so a place another tab stores at any moment always survives.
//
// A write leaves as an immutable request: an uncertain retry repeats the same
// place, observed_at, mutation UUID and resolution flag, also after a reload.
// After a definite conflict the later observation wins automatically when both
// activity times are plausible; equal, unknown, implausible or unmappable cases
// wait for an explicit choice. Rejected writes keep the local place.

const STORAGE_PREFIX = "shelfarr.progress.v1"
const PROBE_KEY = "shelfarr.progress.probe"
const RETRY_DELAYS = [2000, 5000, 15000, 30000, 60000]
const MAX_AUTOMATIC_REBASES = 5
const PLACE_KEYS = ["asset_id", "locator", "position_seconds"]
// Matches the server and native apps: earlier times come from a clock that was
// never set, and later ones are more than five minutes ahead of this device.
const EARLIEST_ACTIVITY = Date.UTC(2000, 0, 1)
const FUTURE_TOLERANCE = 5 * 60_000

// Local HTTP browsers expose getRandomValues but not randomUUID. Keep journal
// and mutation IDs cryptographically random there too (UUID version 4).
function newUUID() {
  if (typeof crypto.randomUUID === "function") return crypto.randomUUID()
  const bytes = crypto.getRandomValues(new Uint8Array(16))
  bytes[6] = (bytes[6] & 0x0f) | 0x40
  bytes[8] = (bytes[8] & 0x3f) | 0x80
  const hex = Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("")
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
}

export function parseObservedAt(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(value)) return null
  const time = Date.parse(value)
  return Number.isFinite(time) ? time : null
}

// An activity time that may order places on this device, or null.
export function plausibleObservedAt(value, now) {
  const time = parseObservedAt(value)
  return time !== null && time >= EARLIEST_ACTIVITY && time <= now + FUTURE_TOLERANCE ? time : null
}

function placeOf(source) {
  const place = {}
  if (!source || typeof source !== "object") return place
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

function fingerprint(text) {
  let hash = 0x811c9dc5
  for (let index = 0; index < text.length; index++) { hash ^= text.charCodeAt(index); hash = Math.imul(hash, 0x01000193) >>> 0 }
  return hash.toString(36)
}

const isObject = value => Boolean(value) && typeof value === "object" && !Array.isArray(value)
const timeOf = entry => entry.t === "o" ? entry.observedAt : entry.body.observed_at
const placeOfEntry = entry => entry.t === "o" ? placeOf(entry.place) : placeOf(entry.body)
const byId = (left, right) => left.id < right.id ? -1 : left.id > right.id ? 1 : 0
function follows(left, right) {
  return predecessors(left).includes(right.id)
}
const predecessors = entry => {
  const ids = entry.t === "o" ? entry.after : entry.from
  return Array.isArray(ids) ? ids : []
}
function byTime(left, right, now) {
  const a = plausibleObservedAt(timeOf(left), now), b = plausibleObservedAt(timeOf(right), now)
  if (a !== null && b !== null) return a === b ? byId(left, right) : a < b ? -1 : 1
  // A clock correction must not make an observation reached after a known
  // checkpoint disappear behind it. Keep that local succession independently
  // of the wall clock; uncertain remote chronology still requires a choice.
  if (follows(left, right)) return 1
  if (follows(right, left)) return -1
  return byId(left, right)
}
const localOf = entry => entry.t === "o"
  ? { place: placeOf(entry.place), observedAt: entry.observedAt, base: entry.base }
  : { place: placeOf(entry.body), observedAt: entry.body.observed_at, base: Number.isInteger(entry.body.expected_version) ? entry.body.expected_version : 0 }

// Entry kinds, each written once under `<scope>|<kind>.<time>.<uuid>`:
//   o  an observation: { place, observedAt, base, after }, after naming the
//      local entries already known when it was reached, base being the server
//      version this browser had incorporated when the place was observed
//   q  an immutable request: { body, from }, from naming the entries it
//      supersedes (older places, an earlier request it rebases, a conflict it
//      resolves by choice)
//   f  a server fact: { version, mutation, observedAt, place, own, drops }, an
//      accepted request (own) or an adopted server place, dropping the entries
//      it settles
//   c  a conflict waiting for a choice: { remote }
//   r  a rejection of a request: { request, error }
class Outbox {
  constructor(entries, now) {
    this.entries = entries
    this.now = now
    const all = [...entries.values()]
    this.facts = all.filter(entry => entry.t === "f").sort(byId)
    const dropped = new Set(this.facts.flatMap(fact => fact.drops))
    const places = all.filter(entry => (entry.t === "o" || entry.t === "q") && !dropped.has(entry.id) &&
      !this.facts.some(fact => this.covers(fact, entry))).sort((a, b) => byTime(a, b, now))
    this.obs = places.filter(entry => entry.t === "o")
    this.requests = places.filter(entry => entry.t === "q")
    const requestIds = new Set(this.requests.map(request => request.id))
    this.rejections = all.filter(entry => entry.t === "r" && !dropped.has(entry.id) && requestIds.has(entry.request)).sort(byId)
    // A conflict is settled by a choice, or once this browser holds a later version.
    this.conflicts = all.filter(entry => entry.t === "c" && !dropped.has(entry.id) &&
      !this.facts.some(fact => fact.version > (entry.remote?.version || 0))).sort(byId)
    this.liveIds = new Set([...places, ...this.rejections, ...this.conflicts].map(entry => entry.id))
    const superseded = new Set(this.requests.flatMap(request => request.from))
    const rejected = new Set(this.rejections.map(rejection => rejection.request))
    this.conflict = this.conflicts.filter(entry => !superseded.has(entry.id)).at(-1) || null
    this.pending = this.requests.filter(request => !superseded.has(request.id) && !rejected.has(request.id)).at(-1) || null
    this.rejection = this.rejections.at(-1) || null
    const newestObservation = this.obs.at(-1), newestRequest = this.requests.at(-1)
    this.unsent = newestObservation && (!newestRequest ||
      byTime(newestObservation, newestRequest, now) > 0)
      ? newestObservation : null
    this.newestLocal = places.length ? localOf(places.at(-1)) : null
    this.maxFact = this.facts.reduce((max, fact) => !max || fact.version > max.version || (fact.version === max.version && fact.id > max.id) ? fact : max, null)
    this.maxVersion = this.maxFact?.version || 0
  }

  plausible(value) { return plausibleObservedAt(value, this.now) }

  // Even this browser's wall clock can change between observations.
  times(fact, value) {
    const read = value => this.plausible(value)
    return [read(value), read(fact.observedAt)]
  }

  covers(fact, entry) {
    if (predecessors(entry).some(id => fact.drops.includes(id))) return false
    const [local, settled] = this.times(fact, timeOf(entry))
    if (local === null || settled === null) return false
    return local < settled || (local === settled && samePlace(placeOfEntry(entry), fact.place))
  }

  // The server version a request for this local place may expect.
  baseFor(local) {
    let base = Number.isInteger(local.base) ? local.base : 0
    for (const fact of this.facts) {
      const [observed, settled] = this.times(fact, local.observedAt)
      if (observed !== null && settled !== null && (fact.own === true ? observed >= settled : observed > settled)) base = Math.max(base, fact.version)
    }
    return base
  }

  // Whether this server mutation is one this browser sent or already adopted.
  incorporated(mutation) {
    if (typeof mutation !== "string") return false
    return [...this.entries.values()].some(entry => (entry.t === "q" && entry.body.client_mutation_id === mutation) || (entry.t === "f" && entry.mutation === mutation))
  }

  // The local activity time of one of this browser's own mutations, or null.
  ownTime(mutation) {
    if (typeof mutation !== "string") return null
    for (const entry of this.entries.values()) {
      if (entry.t === "q" && entry.body.client_mutation_id === mutation) return entry.body.observed_at ?? null
      if (entry.t === "f" && entry.own === true && entry.mutation === mutation) return entry.observedAt ?? null
    }
    return null
  }

  get placeIds() { return [...this.obs, ...this.requests, ...this.conflicts].map(entry => entry.id) }
}

export default class ConsumerProgressSync {
  constructor({ url, account, base = "", publication, version = 0, assets = [], storage, now = () => Date.now(),
    onStatus = () => {}, onConflict = () => {}, onRemote = () => {}, onServerProgress = () => {}, syncDelay = 5000, retryDelays = RETRY_DELAYS }) {
    const endpoint = new URL(url, window.location.href)
    if (endpoint.origin !== window.location.origin) throw new Error("Invalid progress endpoint")
    if (!account || !publication) throw new Error("Progress needs an account and publication")
    this.url = endpoint.href
    // The version-1 single-record key: still read once to migrate it.
    this.key = [STORAGE_PREFIX, window.location.origin + base, account, publication].map(encodeURIComponent).join("|")
    this.prefix = `${this.key}|`
    this.identity = { account: String(account), origin: window.location.origin, base, publication: String(publication) }
    this.serverVersion = Number.isInteger(version) && version > 0 ? version : 0
    this.assets = new Set(assets)
    this.now = now
    this.onStatus = onStatus
    this.onConflict = onConflict
    this.onRemote = onRemote
    // Every saved place the server confirms, for copies kept outside the outbox.
    this.onServerProgress = onServerProgress
    this.syncDelay = syncDelay
    this.retryDelays = retryDelays
    this.failures = 0
    this.rebases = 0
    // Entries this visit could not store yet; they are retried on every write.
    this.unsaved = new Map()
    try { this.storage = storage === undefined ? window.localStorage : storage } catch (_) { this.storage = null }
    try {
      if (typeof this.storage?.key !== "function") throw new Error("Storage cannot list its keys")
      this.storage.setItem(PROBE_KEY, "1")
      this.storage.removeItem(PROBE_KEY)
      this.storageFailed = false
    } catch (_) { this.storageFailed = true }
    if (typeof this.storage?.key !== "function") this.storage = null
    if (!this.storage) this.storageFailed = true
    this.onlineHandler = () => this.flush()
    window.addEventListener?.("online", this.onlineHandler)
  }

  // The place to show when opening: a waiting local checkpoint unless the
  // server holds a plausibly later observation of the same edition.
  restorePlace(server) {
    const box = this.read()
    const local = box.newestLocal
    if (!local || !this.assets.has(local.place.asset_id)) return server ? { source: "server", progress: server } : null
    const kept = { source: "local", progress: local.place, observedAt: local.observedAt }
    if (!server || server.version <= box.baseFor(local) || box.incorporated(server.client_mutation_id)) return kept
    const remoteTime = box.plausible(server.observed_at), localTime = box.plausible(local.observedAt)
    return remoteTime !== null && localTime !== null && remoteTime > localTime ? { source: "server", progress: server } : kept
  }

  // False when this browser refuses to keep the outbox across a reload.
  get durable() { return !this.storageFailed }
  get blocked() { return Boolean(this.read().conflict) }
  get conflict() { const conflict = this.read().conflict; return conflict ? { remote: conflict.remote } : null }
  get waiting() { const box = this.read(); return Boolean(box.unsent || box.pending) }

  // Persist a genuine new observation as its own entry. Network work happens later.
  record(place, observedAt) {
    if (this.closed) return false
    const box = this.read()
    observedAt ??= this.stamp(box)
    const { stored } = this.write("o", { place: placeOf(place), observedAt, after: box.placeIds, base: Math.max(this.serverVersion, box.maxVersion) })
    // A later place makes this browser's older waiting places redundant, but
    // only a stored one may replace a stored one.
    const time = parseObservedAt(observedAt)
    if (time !== null) for (const older of box.obs) {
      if ((parseObservedAt(older.observedAt) ?? Infinity) < time && (stored || this.unsaved.has(older.id))) this.remove(older.id)
    }
    if (box.conflict) this.status("conflict")
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

  // Send a rejected request again, unchanged.
  retry() {
    for (const rejection of this.read().rejections) this.remove(rejection.id)
    this.failures = 0
    return this.flush()
  }

  // Explicit "keep this device": a new choice with its own time and intent,
  // persisted before it is sent.
  keepLocal() {
    const box = this.read()
    const local = box.newestLocal
    if (!box.conflict || !local) return Promise.resolve()
    this.write("q", { choice: true, from: box.placeIds, body: { ...local.place, observed_at: new Date(this.now()).toISOString(),
      resolve_conflict: true, expected_version: box.conflict.remote?.version || 0, client_mutation_id: newUUID() } })
    this.rebases = 0
    return this.flush()
  }

  // Explicit "use the other device's place": the local places it answered are dropped.
  useRemote() {
    const box = this.read()
    const remote = box.conflict?.remote || null
    this.adopt(box, remote, false, remote?.observed_at ?? null)
    this.collect()
    return remote
  }

  close() {
    clearTimeout(this.timer)
    this.timer = null
    this.closing = true
    window.removeEventListener?.("online", this.onlineHandler)
    if (this.inflight) return this.inflight
    const box = this.read()
    // One last keepalive attempt, unless this visit is already known offline;
    // anything unsent stays in the outbox for the next visit.
    if (!box.conflict && !this.failures && (box.unsent || box.pending)) return this.flush().then(() => this.finishClose())
    this.finishClose()
    return Promise.resolve()
  }

  finishClose() { this.closed = true; clearTimeout(this.timer); this.timer = null }

  // Internal ------------------------------------------------------------------

  // Activity on one browser happens in order: a clock that stepped back a
  // little must not make the newer place look older.
  stamp(box) {
    const now = this.now()
    const previous = box.newestLocal ? parseObservedAt(box.newestLocal.observedAt) : null
    return new Date(previous !== null && previous >= now && previous <= now + FUTURE_TOLERANCE ? previous + 1 : now).toISOString()
  }

  schedule(delay) {
    if (this.closed || this.timer) return
    this.timer = setTimeout(() => { this.timer = null; this.flush() }, delay)
  }

  async send() {
    let box = this.read()
    if (box.conflict) return this.status("conflict")
    let request = box.pending
    if (!request) {
      const next = box.unsent
      if (!next) return box.rejection ? this.status("rejected", box.rejection.error) : undefined
      const local = localOf(next)
      request = this.write("q", { from: box.placeIds, body: { ...local.place, observed_at: local.observedAt,
        expected_version: box.baseFor(local), client_mutation_id: newUUID() } }).entry
    }
    const body = request.body
    this.status("syncing")
    let response, result = null
    try {
      response = await fetch(this.url, {
        method: "PUT", credentials: "same-origin", redirect: "manual", keepalive: true,
        headers: { "Content-Type": "application/json", "Accept": "application/json", "X-Shelfarr-Account": this.identity.account, "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "" },
        body: JSON.stringify(body)
      })
      try { result = await response.json() } catch (_) { result = null }
    } catch (_) {
      return this.uncertain("offline")
    }
    box = this.read()
    // Another tab may have finished or replaced this write meanwhile.
    if (box.pending?.id !== request.id) {
      if (box.pending || box.unsent) this.again = true
      else if (!box.conflict) this.status("saved")
      return
    }
    if (response.type === "opaqueredirect" || response.status === 401) return this.status("signin")
    if (response.ok && Number.isInteger(result?.progress?.version)) return this.accepted(request, result.progress)
    if (response.status === 409 && result?.error === "progress_conflict" && (!result.progress || Number.isInteger(result.progress.version))) return this.reconcile(box, result.progress || null)
    if ((response.status === 422 && result?.error === "invalid_progress") || response.status === 404) {
      // The local place and its activity time stay as they were.
      const error = typeof result?.message === "string" ? result.message : null
      this.write("r", { request: request.id, error })
      return this.status("rejected", error)
    }
    return this.uncertain(response.status === 403 || response.status === 422 ? "reload" : "offline")
  }

  accepted(request, progress) {
    this.failures = 0
    this.rebases = 0
    this.serverVersion = Math.max(this.serverVersion, progress.version)
    this.write("f", { version: progress.version, mutation: request.body.client_mutation_id, observedAt: request.body.observed_at ?? null,
      place: placeOf(request.body), own: true, drops: [request.id, ...request.from] })
    this.settled()
    this.reportServer(progress)
  }

  reportServer(progress) {
    try { if (progress) this.onServerProgress(progress) } catch (_) { /* observers never affect sync */ }
  }

  uncertain(kind) {
    const delay = this.retryDelays[Math.min(this.failures, this.retryDelays.length - 1)]
    this.failures += 1
    this.status(kind)
    if (!this.closing) this.schedule(delay)
  }

  // A definite conflict: compare the server copy with the newest local place,
  // including places other tabs queued behind this request.
  reconcile(box, remote) {
    this.failures = 0
    const local = box.newestLocal
    const ownTime = remote ? box.ownTime(remote.client_mutation_id) : null
    const own = ownTime !== null
    const localTime = box.plausible(local.observedAt)
    const remoteTime = !remote ? null : box.plausible(own ? ownTime : remote.observed_at)
    const mappable = !remote || this.assets.has(remote.asset_id)
    if (this.rebases < MAX_AUTOMATIC_REBASES && mappable && localTime !== null) {
      if (!remote || (remoteTime !== null && localTime > remoteTime)) {
        this.rebases += 1
        this.write("q", { from: box.placeIds, body: { ...local.place, observed_at: local.observedAt,
          expected_version: remote?.version || 0, client_mutation_id: newUUID() } })
        this.again = true
        return
      }
      if (remoteTime !== null && (remoteTime > localTime || samePlace(local.place, remote))) {
        this.rebases = 0
        this.adopt(box, remote, own, own ? ownTime : (remote.observed_at ?? null))
        this.settled()
        if (!own) this.onRemote(remote)
        return
      }
    }
    this.rebases = 0
    this.write("c", { remote })
    this.status("conflict")
    this.onConflict(remote)
  }

  adopt(box, remote, own, observedAt) {
    const version = remote?.version || 0
    this.serverVersion = Math.max(this.serverVersion, version)
    this.write("f", { version, mutation: remote?.client_mutation_id ?? null, observedAt, place: placeOf(remote), own, drops: box.placeIds })
    this.reportServer(remote)
  }

  settled() {
    this.collect()
    const box = this.read()
    if (box.pending || box.unsent) { this.status("local"); this.again = true } else this.status("saved")
  }

  // Remove entries a durable fact already settles, then facts nothing needs.
  collect() {
    const box = this.read()
    for (const entry of box.entries.values()) if (entry.t !== "f" && !box.liveIds.has(entry.id)) this.remove(entry.id)
    const after = this.read()
    const others = [...after.entries.values()].some(entry => entry.t !== "f")
    for (const fact of after.facts) {
      if (fact === after.maxFact && others) continue
      if (fact.drops.some(id => this.present(id))) continue
      this.remove(fact.id)
    }
  }

  read() {
    const entries = new Map()
    if (this.storage) {
      try {
        this.migrate()
        const keys = []
        for (let index = 0, length = this.storage.length; index < length; index++) {
          const key = this.storage.key(index)
          if (typeof key === "string" && key.startsWith(this.prefix)) keys.push(key)
        }
        for (const key of keys) {
          const entry = this.decode(key.slice(this.prefix.length), this.storage.getItem(key))
          if (entry) entries.set(entry.id, entry)
        }
      } catch (_) { this.storageFailed = true }
    }
    for (const [id, entry] of this.unsaved) entries.set(id, structuredClone(entry))
    return new Outbox(entries, this.now())
  }

  decode(id, raw) {
    if (typeof raw !== "string") return null
    let entry
    try { entry = JSON.parse(raw) } catch (_) { return null }
    if (!isObject(entry) || !this.sameIdentity(entry.identity) || entry.t !== id.split(".")[0]) return null
    entry.id = id
    const valid = {
      o: () => isObject(entry.place) && typeof entry.observedAt === "string" && Number.isInteger(entry.base),
      q: () => isObject(entry.body) && typeof entry.body.client_mutation_id === "string" && Array.isArray(entry.from),
      f: () => Number.isInteger(entry.version) && Array.isArray(entry.drops),
      c: () => entry.remote === null || isObject(entry.remote),
      r: () => typeof entry.request === "string"
    }[entry.t]
    return valid?.() ? entry : null
  }

  sameIdentity(identity) {
    return isObject(identity) && identity.account === this.identity.account && identity.publication === this.identity.publication &&
      identity.origin === this.identity.origin && identity.base === this.identity.base
  }

  // Version 1 kept the whole outbox in one record. Its contents become entries
  // with ids derived from the record, so tabs migrating at once write the same
  // entries; the record is removed only after they are stored.
  migrate() {
    const raw = this.storage.getItem(this.key)
    if (!raw) return
    let legacy
    try { legacy = JSON.parse(raw) } catch (_) { return }
    if (!isObject(legacy) || !this.sameIdentity(legacy.identity)) return
    const tag = `legacy-${fingerprint(raw)}`
    const base = Number.isInteger(legacy.base) && legacy.base > 0 ? legacy.base : 0
    const ids = []
    const put = (id, fields) => { ids.push(id); this.put(id, fields) }
    const pending = legacy.pending
    if (isObject(pending?.body) && typeof pending.body.client_mutation_id === "string") {
      put(`q.${tag}`, { t: "q", from: [], body: pending.body })
      if (pending.state === "rejected") put(`r.${tag}`, { t: "r", request: `q.${tag}`, error: typeof pending.error === "string" ? pending.error : null })
    }
    if (isObject(legacy.latest?.place) && typeof legacy.latest.observedAt === "string") {
      put(`o.${tag}`, { t: "o", place: placeOf(legacy.latest.place), observedAt: legacy.latest.observedAt, base })
    }
    if (isObject(legacy.conflict)) put(`c.${tag}`, { t: "c", remote: isObject(legacy.conflict.remote) ? legacy.conflict.remote : null })
    if (ids.some(id => this.unsaved.has(id))) return
    if (this.storage.getItem(this.key) === raw) this.storage.removeItem(this.key)
  }

  write(kind, fields) {
    const id = `${kind}.${Math.max(0, Math.floor(this.now())).toString(36).padStart(9, "0")}.${newUUID()}`
    return this.put(id, { t: kind, ...fields })
  }

  // Store a new entry under its own key; it is never rewritten.
  put(id, fields) {
    const entry = { ...fields, id, identity: this.identity, savedAt: new Date(this.now()).toISOString() }
    this.unsaved.set(id, entry)
    if (this.storage) {
      for (const [waiting, value] of this.unsaved) {
        try { this.storage.setItem(this.prefix + waiting, JSON.stringify(value)); this.unsaved.delete(waiting) } catch (_) { break }
      }
    }
    this.storageFailed = !this.storage || this.unsaved.size > 0
    return { id, stored: !this.unsaved.has(id), entry: structuredClone(entry) }
  }

  remove(id) {
    this.unsaved.delete(id)
    try { this.storage?.removeItem(this.prefix + id) } catch (_) { /* a settled entry stays hidden by its fact */ }
  }

  present(id) {
    if (this.unsaved.has(id)) return true
    if (!this.storage) return false
    try { return this.storage.getItem(this.prefix + id) !== null } catch (_) { return true }
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
    // Still replaying the same saved span: a quick pause/play continues it.
    if (this.floor !== null && position <= this.floor) return position
    const rewound = Math.max(0, position - ListeningCheckpoints.REWIND)
    // Pausing again during pre-roll must not lower the original saved floor.
    this.floor = rewound < position ? Math.max(this.floor ?? position, position) : this.floor
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
  continued(assetId, position = 0) {
    this.floor = null
    this.active = true
    this.save(position, assetId)
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
