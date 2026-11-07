import { afterEach, beforeEach, expect, test } from "bun:test"
import ConsumerProgressSync, { ListeningCheckpoints, parseObservedAt } from "../../app/javascript/consumer_progress_sync.js"

class MemoryStorage {
  constructor() { this.items = new Map(); this.failing = false }
  getItem(key) { return this.items.has(key) ? this.items.get(key) : null }
  setItem(key, value) { if (this.failing) throw new Error("QuotaExceededError"); this.items.set(key, String(value)) }
  removeItem(key) { if (this.failing) throw new Error("SecurityError"); this.items.delete(key) }
  get keys() { return [...this.items.keys()] }
}

const ASSET = "a".repeat(64)
const T = minutes => new Date(Date.UTC(2026, 10, 7, 9, minutes)).toISOString()
let original, storage, clock, syncs, bodies, responses, listeners
const json = (status, payload) => ({ ok: status >= 200 && status < 300, status, type: "basic", json: async () => payload })
const saved = (version, extra = {}) => json(200, { progress: { asset_id: ASSET, version, observed_at: null, ...extra } })
const conflict = progress => json(409, { error: "progress_conflict", progress })
const lost = () => { throw new TypeError("Failed to fetch") }

beforeEach(() => {
  original = { fetch: globalThis.fetch, window: globalThis.window, document: globalThis.document }
  listeners = {}
  globalThis.window = {
    location: { href: "https://reader.example/shelfarr/read/1", origin: "https://reader.example" },
    addEventListener: (name, handler) => { listeners[name] = handler },
    removeEventListener: name => { delete listeners[name] }
  }
  globalThis.document = { querySelector: () => ({ content: "csrf" }) }
  storage = new MemoryStorage()
  clock = Date.parse(T(0))
  syncs = []
  bodies = []
  responses = []
  globalThis.fetch = async (_url, options) => {
    bodies.push(JSON.parse(options.body))
    const next = responses.shift()
    if (!next) throw new Error("unexpected request")
    return typeof next === "function" ? next(JSON.parse(options.body)) : next
  }
})
afterEach(() => { syncs.forEach(sync => sync.finishClose()); Object.assign(globalThis, original) })

function open(options = {}) {
  const sync = new ConsumerProgressSync({ url: "/shelfarr/read/1/progress", account: "7", base: "/shelfarr", publication: "1", version: 0,
    assets: [ASSET], storage, now: () => clock, syncDelay: 60_000, retryDelays: [60_000], ...options })
  syncs.push(sync)
  return sync
}
const at = (seconds, minutes) => { clock = Date.parse(T(minutes)); return { asset_id: ASSET, position_seconds: seconds } }

test("a checkpoint is stored before any request and survives closing the page offline", async () => {
  const first = open()
  expect(first.record(at(42, 1))).toBe(true)
  expect(storage.keys).toHaveLength(1)
  expect(storage.keys[0]).toContain(encodeURIComponent("https://reader.example/shelfarr"))
  responses.push(lost)
  await first.flush()
  await first.close()
  expect(bodies).toHaveLength(1)

  // Reopen: the same immutable request is retried, then the outbox empties.
  const reopened = open({ version: 0 })
  expect(reopened.restorePlace(null)).toMatchObject({ source: "local", progress: { position_seconds: 42 }, observedAt: T(1) })
  responses.push(saved(1, { observed_at: T(1) }))
  await reopened.flush()
  expect(bodies[1]).toEqual(bodies[0])
  expect(bodies[1]).toMatchObject({ position_seconds: 42, observed_at: T(1), expected_version: 0 })
  expect(bodies[1].resolve_conflict).toBeUndefined()
  expect(storage.keys).toHaveLength(0)
})

test("a lost response retries the identical mutation before publishing a newer place", async () => {
  const sync = open()
  sync.record(at(10, 1))
  responses.push(lost)
  await sync.flush()
  sync.record(at(20, 2))
  responses.push(saved(1), saved(2))
  await sync.flush()
  await sync.flush()
  expect(bodies[1]).toEqual(bodies[0])
  expect(bodies[2]).toMatchObject({ position_seconds: 20, observed_at: T(2), expected_version: 1 })
  expect(bodies[2].client_mutation_id).not.toBe(bodies[0].client_mutation_id)
})

test("reconnecting sends waiting progress without a reload", async () => {
  const sync = open()
  sync.record(at(5, 1))
  responses.push(lost)
  await sync.flush()
  responses.push(saved(1))
  listeners.online()
  await sync.inflight
  expect(bodies.map(body => body.client_mutation_id)).toEqual([bodies[0].client_mutation_id, bodies[0].client_mutation_id])
  expect(sync.waiting).toBe(false)
})

test("newer local activity rebases with a new UUID and keeps its original time", async () => {
  const sync = open()
  sync.record(at(120, 30))
  responses.push(conflict({ asset_id: ASSET, position_seconds: 900, version: 4, observed_at: T(10) }), saved(5))
  await sync.flush()
  await sync.inflight
  expect(bodies).toHaveLength(2)
  expect(bodies[1]).toMatchObject({ position_seconds: 120, observed_at: T(30), expected_version: 4 })
  expect(bodies[1].client_mutation_id).not.toBe(bodies[0].client_mutation_id)
  expect(bodies[1].resolve_conflict).toBeUndefined()
})

test("older local activity from an offline device adopts the later remote place instead of retrying", async () => {
  const remotes = []
  const sync = open({ onRemote: remote => remotes.push(remote) })
  sync.record(at(900, 5))
  responses.push(lost)
  await sync.flush()
  await sync.close()
  // Reload after the other device saved a later, earlier-in-the-book place.
  const remote = { asset_id: ASSET, position_seconds: 60, version: 3, observed_at: T(20), client_mutation_id: "x" }
  const reopened = open({ version: 3, onRemote: remote => remotes.push(remote) })
  expect(reopened.restorePlace(remote)).toMatchObject({ source: "server", progress: remote })
  responses.push(conflict(remote))
  await reopened.flush()
  expect(remotes).toEqual([remote])
  expect(bodies).toHaveLength(2)
  expect(storage.keys).toHaveLength(0)
  reopened.record(at(61, 21))
  responses.push(saved(4))
  await reopened.flush()
  expect(bodies[2]).toMatchObject({ position_seconds: 61, expected_version: 3 })
})

test("places queued behind the rejected write are compared, not just the write itself", async () => {
  const sync = open()
  sync.record(at(100, 1))
  let release
  responses.push(() => new Promise(resolve => { release = resolve }))
  const sending = sync.flush()
  sync.record(at(130, 25))
  release(conflict({ asset_id: ASSET, position_seconds: 50, version: 2, observed_at: T(10) }))
  responses.push(saved(3))
  await sending
  await sync.inflight
  expect(bodies[1]).toMatchObject({ position_seconds: 130, observed_at: T(25), expected_version: 2 })
})

test("equal or unknown activity times wait for a persisted explicit choice", async () => {
  let conflicts = 0
  const sync = open({ onConflict: () => { conflicts++ } })
  sync.record(at(30, 9))
  responses.push(conflict({ asset_id: ASSET, position_seconds: 31, version: 2, observed_at: T(9) }))
  await sync.flush()
  expect(conflicts).toBe(1)
  sync.record(at(35, 11))
  await sync.flush()
  expect(bodies).toHaveLength(1)

  // A reload keeps the question open and the local place.
  const reopened = open({ version: 2 })
  expect(reopened.blocked).toBe(true)
  expect(reopened.restorePlace({ asset_id: ASSET, position_seconds: 31, version: 2, observed_at: T(9) }).progress.position_seconds).toBe(35)
  clock = Date.parse(T(40))
  responses.push(body => {
    const stored = JSON.parse(storage.getItem(storage.keys[0]))
    expect(stored.pending.body).toEqual(body)
    return saved(3)
  })
  await reopened.keepLocal()
  expect(bodies[1]).toMatchObject({ position_seconds: 35, observed_at: T(40), resolve_conflict: true, expected_version: 2 })
  expect(storage.keys).toHaveLength(0)
})

test("a legacy server without activity times keeps the manual conflict choice", async () => {
  let conflicts = 0
  const sync = open({ onConflict: () => { conflicts++ } })
  sync.record(at(10, 1))
  responses.push(json(409, { error: "progress_conflict", progress: { asset_id: ASSET, position_seconds: 3, version: 9 } }))
  await sync.flush()
  expect(conflicts).toBe(1)
  expect(sync.useRemote()).toMatchObject({ version: 9 })
  expect(storage.keys).toHaveLength(0)
})

test("a remote place on an edition this page cannot map needs a choice", async () => {
  let conflicts = 0
  const sync = open({ onConflict: () => { conflicts++ } })
  sync.record(at(10, 30))
  responses.push(conflict({ asset_id: "b".repeat(64), position_seconds: 3, version: 2, observed_at: T(1) }))
  await sync.flush()
  expect(conflicts).toBe(1)
})

test("a rejected write keeps the local place without retrying until there is a new one", async () => {
  const statuses = []
  const sync = open({ onStatus: kind => statuses.push(kind) })
  sync.record(at(10, 1))
  responses.push(json(422, { error: "invalid_progress", message: "This asset is no longer available; refresh the publication" }))
  await sync.flush()
  await sync.flush()
  expect(bodies).toHaveLength(1)
  expect(statuses).toContain("rejected")
  expect(open().restorePlace(null).progress.position_seconds).toBe(10)
  sync.record(at(12, 2))
  responses.push(saved(1))
  await sync.flush()
  expect(bodies[1]).toMatchObject({ position_seconds: 12, observed_at: T(2) })
})

test("an expired session is reported and the write is kept for later", async () => {
  const statuses = []
  const sync = open({ onStatus: kind => statuses.push(kind) })
  sync.record(at(10, 1))
  responses.push({ ok: false, status: 0, type: "opaqueredirect", json: async () => { throw new Error("opaque") } })
  await sync.flush()
  expect(statuses.at(-1)).toBe("signin")
  expect(sync.waiting).toBe(true)
})

test("accounts, servers and publications never share an outbox", async () => {
  open().record(at(10, 1))
  expect(open({ account: "8" }).restorePlace(null)).toBeNull()
  expect(open({ publication: "2" }).restorePlace(null)).toBeNull()
  expect(open({ base: "" }).restorePlace(null)).toBeNull()
  // A record copied under another key is ignored.
  const copy = open({ account: "9" })
  storage.setItem(copy.key, storage.getItem(storage.keys[0]))
  expect(copy.restorePlace(null)).toBeNull()
})

test("a browser that refuses storage still syncs this visit and says so", async () => {
  storage.failing = true
  const statuses = []
  const sync = open({ onStatus: kind => statuses.push(kind) })
  expect(sync.durable).toBe(false)
  expect(sync.record(at(10, 1))).toBe(false)
  expect(statuses).toEqual(["storage"])
  responses.push(saved(1))
  await sync.flush()
  expect(bodies).toHaveLength(1)
})

test("leaving during an in-flight save flushes the final queued place in order", async () => {
  let release
  const sync = open()
  sync.record(at(10, 1))
  responses.push(() => new Promise(resolve => { release = resolve }), saved(2))
  const first = sync.flush()
  sync.record(at(17, 2))
  const closing = sync.close()
  release(saved(1))
  await first
  await closing
  await new Promise(resolve => setTimeout(resolve, 0))
  expect(bodies.map(body => body.position_seconds)).toEqual([10, 17])
  expect(bodies[1].expected_version).toBe(1)
})

test("a progress URL on a different origin is rejected before any request", () => {
  expect(() => open({ url: "https://other.example/read/1/progress" })).toThrow("Invalid progress endpoint")
})

test("activity times must name a zone", () => {
  expect(parseObservedAt("2026-11-07T09:00:00.000Z")).toBe(Date.parse("2026-11-07T09:00:00Z"))
  expect(parseObservedAt("2026-11-07T09:00:00")).toBeNull()
  expect(parseObservedAt(null)).toBeNull()
})

test("listening checkpoints are at most five seconds apart and leave restoration alone", () => {
  let now = 0
  const places = []
  const checkpoints = new ListeningCheckpoints({ record: place => places.push(place.position_seconds), now: () => now })
  checkpoints.restored(100, ASSET)
  expect(checkpoints.tick(100, ASSET)).toBe(false)
  expect(checkpoints.settle(100, ASSET)).toBe(false)
  checkpoints.deliberate(30, ASSET, false)
  for (let second = 1; second <= 12; second++) { now = second * 1000; checkpoints.tick(30 + second, ASSET) }
  expect(places).toEqual([30, 34, 38, 42])
  now = 12_500
  checkpoints.settle(42.6, ASSET)
  checkpoints.settle(42.6, ASSET)
  expect(places).toEqual([30, 34, 38, 42, 42.6])
})

test("a genuine resume rewinds five seconds and keeps the saved place until playback passes it", () => {
  let now = 0
  const places = []
  const checkpoints = new ListeningCheckpoints({ record: place => places.push(place.position_seconds), now: () => now })
  checkpoints.restored(100, ASSET)
  expect(checkpoints.resume(100)).toBe(95)
  now = 6000
  expect(checkpoints.tick(98, ASSET)).toBe(false)
  expect(checkpoints.settle(98, ASSET)).toBe(false)
  expect(checkpoints.resume(98)).toBe(93)
  now = 12000
  checkpoints.tick(101, ASSET)
  expect(places).toEqual([101])
  expect(checkpoints.resume(3)).toBe(0)
})

test("deliberate seeks, track choices and natural transitions do not rewind", () => {
  const places = []
  const checkpoints = new ListeningCheckpoints({ record: place => places.push([place.asset_id, place.position_seconds]) })
  checkpoints.restored(50, ASSET)
  checkpoints.deliberate(20, ASSET, true)
  expect(checkpoints.resume(20)).toBe(20)
  checkpoints.continued("next")
  expect(places).toEqual([[ASSET, 20], ["next", 0]])
  checkpoints.deliberate(0, "other", true)
  expect(checkpoints.resume(0)).toBe(0)
  expect(checkpoints.resume(40)).toBe(35)
})

// A miniature server with the documented rules, shared by two browsers.
function server() {
  const state = { current: null }
  state.handle = body => {
    const { current } = state
    const place = { asset_id: body.asset_id, position_seconds: body.position_seconds, observed_at: body.observed_at ?? null }
    if (current?.client_mutation_id === body.client_mutation_id) return JSON.stringify({ ...place, version: current.version, client_mutation_id: current.client_mutation_id }) === JSON.stringify(current) ? json(200, { progress: current }) : conflict(current)
    if ((current?.version || 0) !== body.expected_version) return conflict(current)
    const stored = parseObservedAt(current?.observed_at), observed = parseObservedAt(place.observed_at)
    if (!body.resolve_conflict && stored !== null && observed !== null && (observed < stored || (observed === stored && current.position_seconds !== place.position_seconds))) return conflict(current)
    state.current = { ...place, version: (current?.version || 0) + 1, client_mutation_id: body.client_mutation_id }
    return json(200, { progress: state.current })
  }
  return state
}

for (const order of [["phone", "tablet"], ["tablet", "phone"]]) {
  test(`two offline browsers converge on the later activity when the ${order[0]} uploads first`, async () => {
    const remote = server()
    globalThis.fetch = async (_url, options) => remote.handle(JSON.parse(options.body))
    const devices = { phone: open({ storage: new MemoryStorage() }), tablet: open({ storage: new MemoryStorage() }) }
    devices.phone.record(at(900, 5))     // listened further, earlier
    devices.tablet.record(at(120, 20))   // sought back, later
    for (const name of order) { await devices[name].flush(); await devices[name].inflight }
    expect(remote.current).toMatchObject({ position_seconds: 120, observed_at: T(20) })
    expect(devices.phone.waiting || devices.tablet.waiting).toBe(false)
    expect(devices.phone.blocked || devices.tablet.blocked).toBe(false)
  })
}

test("reaching the same place later still advances the activity time so an in-between place cannot win", async () => {
  const remote = server()
  globalThis.fetch = async (_url, options) => remote.handle(JSON.parse(options.body))
  const b = open({ storage: new MemoryStorage() }), a = open({ storage: new MemoryStorage() }), c = open({ storage: new MemoryStorage() })
  b.record(at(120, 1))
  a.record(at(120, 3))
  c.record(at(30, 2))
  await b.flush()
  await a.flush(); await a.inflight
  expect(remote.current).toMatchObject({ position_seconds: 120, observed_at: T(3) })
  expect(a.waiting || a.blocked).toBe(false)
  await c.flush(); await c.inflight
  expect(remote.current).toMatchObject({ position_seconds: 120, observed_at: T(3) })
  expect(c.waiting || c.blocked).toBe(false)
})

test("the same place observed earlier than the server copy is adopted with the server time", async () => {
  const remotes = []
  const sync = open({ onRemote: remote => remotes.push(remote) })
  sync.record(at(120, 1))
  responses.push(conflict({ asset_id: ASSET, position_seconds: 120, version: 2, observed_at: T(3) }))
  await sync.flush()
  expect(bodies).toHaveLength(1)
  expect(remotes[0].observed_at).toBe(T(3))
  expect(sync.waiting).toBe(false)
})
