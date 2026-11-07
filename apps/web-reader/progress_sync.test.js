import { afterEach, beforeEach, expect, test } from "bun:test"
import ConsumerProgressSync from "../../app/javascript/consumer_progress_sync.js"

let original, sync
beforeEach(() => {
  original = { fetch: globalThis.fetch, window: globalThis.window, document: globalThis.document }
  globalThis.window = { location: { href: "https://reader.example/shelfarr/read/1", origin: "https://reader.example" } }
  globalThis.document = { querySelector: () => ({ content: "csrf" }) }
})
afterEach(() => { sync?.close(); Object.assign(globalThis, original) })
const result = (version, status = 200) => ({ ok: status === 200, status, json: async () => ({ progress: { version } }) })

test("a lost response retries the identical mutation before publishing a newer place", async () => {
  const bodies = []
  let fail = true
  globalThis.fetch = async (_url, options) => {
    bodies.push(JSON.parse(options.body))
    if (fail) { fail = false; throw new Error("response lost") }
    return result(bodies.length)
  }
  sync = new ConsumerProgressSync("/shelfarr/read/1/progress", 2, () => {}, () => {})
  sync.save({ asset_id: "edition", position_seconds: 10 })
  await sync.flush()
  sync.save({ asset_id: "edition", position_seconds: 20 })
  await sync.flush()
  expect(bodies[1]).toEqual(bodies[0])
  await sync.flush()
  expect(bodies[2].position_seconds).toBe(20)
  expect(bodies[2].expected_version).toBe(2)
  expect(bodies[2].client_mutation_id).not.toBe(bodies[0].client_mutation_id)
})

test("cross-device conflict blocks writes until the user explicitly keeps this place", async () => {
  let writes = 0, conflicts = 0
  globalThis.fetch = async () => { writes++; return result(9, 409) }
  sync = new ConsumerProgressSync("/read/1/progress", 1, () => {}, () => { conflicts++ })
  sync.save({ asset_id: "edition", position_seconds: 10 })
  await sync.flush()
  sync.save({ asset_id: "edition", position_seconds: 30 })
  await sync.flush()
  expect(writes).toBe(1)
  expect(conflicts).toBe(1)
  let body
  globalThis.fetch = async (_url, options) => { body = JSON.parse(options.body); return result(10) }
  sync.keepLocal()
  await Promise.resolve()
  expect(body.position_seconds).toBe(30)
  expect(body.expected_version).toBe(9)
})

test("leaving during an in-flight save flushes the final queued place in order", async () => {
  let resolveFirst
  const bodies = []
  globalThis.fetch = async (_url, options) => {
    bodies.push(JSON.parse(options.body))
    if (bodies.length === 1) return new Promise(resolve => { resolveFirst = resolve })
    return result(2)
  }
  sync = new ConsumerProgressSync("/read/1/progress", 0, () => {}, () => {})
  sync.save({ asset_id: "edition", position_seconds: 10 })
  const first = sync.flush()
  sync.save({ asset_id: "edition", position_seconds: 17 })
  sync.close()
  resolveFirst(result(1))
  await first
  await Promise.resolve()
  expect(bodies.map(body => body.position_seconds)).toEqual([10, 17])
  expect(bodies[1].expected_version).toBe(1)
})

test("a progress URL on a different origin is rejected before any request", () => {
  expect(() => new ConsumerProgressSync("https://other.example/read/1/progress", 0, () => {}, () => {})).toThrow("Invalid progress endpoint")
})
