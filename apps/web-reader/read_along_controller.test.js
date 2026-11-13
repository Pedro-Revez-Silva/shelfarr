import { expect, test } from "bun:test"
import { readFile } from "node:fs/promises"
import ConsumerProgressSync, { ListeningCheckpoints } from "../../app/javascript/consumer_progress_sync.js"
import { CUE_FIELDS, locatorFor, prepareManifest, ReadAlongSession } from "../../app/javascript/consumer_read_along.js"
import * as ReadAlong from "../../app/javascript/consumer_read_along.js"

// Keep the production controller methods. Only Stimulus construction and the
// importmap alias are replaced; media, DOM and network are external boundaries.
const progressURL = new URL("../../app/javascript/consumer_progress_sync.js", import.meta.url)
const source = (await readFile(new URL("../../app/javascript/controllers/consumer_reader_controller.js", import.meta.url), "utf8"))
  .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
  .replace('from "consumer_progress_sync"', `from ${JSON.stringify(progressURL.href)}`)
const { default: Reader } = await import(`data:text/javascript;base64,${Buffer.from(source + "\n//# sourceURL=consumer-reader-controller-under-test.js\n").toString("base64")}`)
const ASSET = "a".repeat(64), GENERATION = "b".repeat(64), AUDIO = "c".repeat(64)

class Storage {
  data = new Map()
  get length() { return this.data.size }
  key(index) { return [...this.data.keys()][index] ?? null }
  getItem(key) { return this.data.get(key) ?? null }
  setItem(key, value) { this.data.set(key, value) }
  removeItem(key) { this.data.delete(key) }
}

class Audio {
  listeners = {}; paused = true; ended = false; currentTime = 0; duration = 180
  addEventListener(type, listener) { (this.listeners[type] ||= []).push(listener) }
  removeEventListener(type, listener) { this.listeners[type] = (this.listeners[type] || []).filter(item => item !== listener) }
  emit(type) { for (const listener of this.listeners[type] || []) listener() }
  load() { queueMicrotask(() => this.emit("loadedmetadata")) }
  async play() { this.paused = false; this.emit("play") }
  pause() { if (!this.paused) { this.paused = true; this.emit("pause") } }
  getAttribute() { return this.src }
  removeAttribute() { this.src = null }
}

async function withAcceptedPlace(check) {
  const originals = new Map(["window", "document", "fetch"].map(key => [key, globalThis[key]]))
  globalThis.window = { location: { href: "https://reader.example/read/1", origin: "https://reader.example" }, addEventListener() {}, removeEventListener() {} }
  globalThis.document = { querySelector() { return null } }
  const prepared = prepareManifest({ version: 1, source: "imported", generation: GENERATION, ebook_asset_id: ASSET, cue_fields: CUE_FIELDS,
    text: [{ href: "OEBPS/text.xhtml" }], audio: [{ url: "/tone.mp3", asset_id: AUDIO }], resources_url: "/resources/",
    cues: [[0, "one", 0, 0, 60000], [0, "two", 0, 60000, 180000]] },
  { assetId: ASSET, generation: GENERATION, origin: window.location.origin })
  const reader = new Reader(), storage = new Storage(), audio = new Audio(), errors = [], confirmed = []
  Object.assign(reader, { active: true, readerReady: true, publication: { id: "1", book_type: "ebook", assets: [{ id: ASSET }] }, assetIndex: 0,
    hasRemoteTarget: true, remoteTarget: { hidden: true }, showSyncStatus() {}, showError: message => errors.push(message),
    elementFor() { return null }, book: { spine: { get() { return { index: 0 } }, length: 1 } }, bookTarget: href => href,
    showLocator: async () => {} })
  reader.sync = new ConsumerProgressSync({ url: "/read/1/progress", account: "fixture", publication: "1", assets: [ASSET], storage,
    syncDelay: 3600000, onRemote: remote => reader.remoteArrived(remote), onServerProgress: progress => confirmed.push(progress) })
  const pairedSync = new ConsumerProgressSync({ url: "/read/2/progress", account: "fixture", publication: "2", assets: [AUDIO], storage, syncDelay: 3600000 })
  const checkpoints = new ListeningCheckpoints({ record: place => reader.recordHeard(place) })
  const session = new ReadAlongSession({ prepared, audio, checkpoints, frame: () => 0 })
  reader.readAlong = { module: ReadAlong,
    prepared, session, checkpoints, assetId: ASSET, pairedSync, readSinceHeard: false }
  try {
    await session.prepare(0, 0)
    await session.playFrom(0)
    audio.currentTime = 30
    audio.emit("timeupdate")
    const remote = { asset_id: ASSET, locator: locatorFor(prepared, 0, 90000), version: 2,
      observed_at: new Date(Date.now() + 1000).toISOString(), client_mutation_id: crypto.randomUUID() }
    globalThis.fetch = async () => ({ ok: false, status: 409, json: async () => ({ error: "progress_conflict", progress: remote }) })
    await reader.sync.flush()
    expect(reader.sessionMoved).toBe(true)
    expect(reader.remotePending).toEqual(remote)
    expect(reader.remoteTarget.hidden).toBe(true)
    session.pause()
    await check({ reader, session, audio, remote, errors, confirmed })
  } finally {
    session.close()
    reader.sync.failures = pairedSync.failures = 1
    await reader.sync.close()
    await pairedSync.close()
    for (const [key, value] of originals) value === undefined ? delete globalThis[key] : globalThis[key] = value
  }
}

test("narration resume waits for an accepted remote place, even after local listening and a second Play", async () => {
  await withAcceptedPlace(async ({ reader, audio, session, remote, confirmed }) => {
    let release
    reader.showLocator = () => new Promise(resolve => { release = resolve })
    const first = reader.readAlongToggle()
    await reader.readAlongToggle()
    expect(audio.paused).toBe(true)
    expect(audio.currentTime).toBe(30)
    release()
    await first
    expect(audio.currentTime).toBe(85)
    expect(audio.paused).toBe(false)
    expect(reader.remotePending).toBe(null)
    expect(reader.sync.waiting).toBe(false)
    expect(confirmed.at(-1)).toEqual(remote)
    expect(reader.readAlong.offer).toBeUndefined()
    audio.currentTime = 86
    session.settle()
    expect(reader.sync.waiting).toBe(false)
    expect(confirmed.at(-1)).toEqual(remote)
  })
})

test("failed remote text restoration keeps the place and stays paused until a successful retry", async () => {
  await withAcceptedPlace(async ({ reader, audio, remote, errors, confirmed }) => {
    reader.showLocator = async () => { throw new Error("fixture text failure") }
    await reader.readAlongToggle()
    expect(audio.paused).toBe(true)
    expect(reader.remotePending).toEqual(remote)
    expect(reader.remoteTarget.hidden).toBe(false)
    expect(errors).toEqual(["Couldn't open the other device's place."])
    reader.showLocator = async () => {}
    await reader.readAlongToggle()
    expect(audio.currentTime).toBe(85)
    expect(audio.paused).toBe(false)
    expect(reader.sync.waiting).toBe(false)
    expect(confirmed.at(-1)).toEqual(remote)
  })
})

test("ending a visit during remote restoration never resumes its old narration", async () => {
  await withAcceptedPlace(async ({ reader, audio, remote, confirmed }) => {
    let release
    reader.showLocator = () => new Promise(resolve => { release = resolve })
    const playing = reader.readAlongToggle()
    reader.active = false
    expect(audio.paused).toBe(true)
    release()
    await playing
    expect(audio.paused).toBe(true)
    expect(reader.sync.waiting).toBe(false)
    expect(confirmed.at(-1)).toEqual(remote)
  })
})

// Layout changes while narration plays. The layout engine is an external
// boundary, modelled on EPUB.js 0.3.93: its displays run one at a time and
// report each move as an automatic relocation, and a window resize clears
// every view (and its document) before it emits "resized", then queues its
// own display of its last location. The heard cue (the second paragraph) was
// already in view, so following never turned a page or moved the anchor.
async function withLayout(state, check) {
  const originals = new Map(["window", "document"].map(key => [key, globalThis[key]]))
  globalThis.window = { location: { href: "https://reader.example/read/1", origin: "https://reader.example" }, addEventListener() {}, removeEventListener() {} }
  globalThis.document = { querySelector() { return null } }
  const prepared = prepareManifest({ version: 1, source: "imported", generation: GENERATION, ebook_asset_id: ASSET, cue_fields: CUE_FIELDS,
    text: [{ href: "OEBPS/text.xhtml" }], audio: [{ url: "/tone.mp3", asset_id: AUDIO }], resources_url: "/resources/",
    cues: [[0, "one", 0, 0, 60000], [0, "two", 0, 60000, 180000]] },
  { assetId: ASSET, generation: GENERATION, origin: window.location.origin })
  const PAGE = "epubcfi(/6/2!/4/2/1:0)", HEARD = "epubcfi(/6/2!/4/6/1:0)"
  const displays = [], writes = [], sizes = []
  const reader = new Reader()
  const element = { classList: { add() {}, remove() {} }, ownerDocument: { createRange: () => ({ selectNodeContents() {}, collapse() {} }) } }
  const contents = { cfiFromRange: () => HEARD }
  let shown = PAGE, cleared = false, queue = Promise.resolve()
  const relocated = () => reader.ebookPosition({ start: { cfi: shown, href: "OEBPS/text.xhtml", index: 0, displayed: { page: 1, total: 3 } } })
  const rendition = {
    display: target => (queue = queue.then(async () => {
      await new Promise(resolve => setTimeout(resolve, 0))
      cleared = false
      displays.push(target)
      shown = target
      relocated()
    })),
    views: () => ({ all: () => [] }),
    // No laid-out frames: pages are named by EPUB.js's own text place.
    getContents: () => [],
    currentLocation: () => ({ start: { cfi: shown } }),
    get location() { return { start: { cfi: shown } } },
    themes: { fontSize: size => sizes.push(size) },
    reportLocation: async () => relocated(),
    resize() { cleared = true; reader.reflowed(); rendition.display(rendition.location.start.cfi) }
  }
  Object.assign(reader, { active: true, readerReady: true, readerReflow: Promise.resolve(), readingAnchor: PAGE, lastEbookCfi: PAGE, fontSize: 105,
    userMoved: false, assetIndex: 0, publication: { id: "1", book_type: "ebook", assets: [{ id: ASSET }] }, rendition,
    book: { spine: { length: 1 } }, locationTarget: {}, chaptersTarget: { options: [] }, showError: message => { throw new Error(message) },
    sync: { record: (place, observedAt) => writes.push({ place, observedAt }) },
    elementFor: (href, fragment) => !cleared && href === "OEBPS/text.xhtml" && fragment === "two" ? element : null,
    contentsFor: href => !cleared && href === "OEBPS/text.xhtml" ? contents : null,
    // Geometry is the browser's; the system tests measure it. The heard cue
    // is in view before the layout change.
    elementVisible: () => true })
  reader.readAlong = { module: ReadAlong, prepared, follow: true, suspended: false, readSinceHeard: false, followChain: Promise.resolve(),
    session: { playing: true, cue: 1 }, ...state }
  try {
    // The cue starts sounding: highlighted, and already in view.
    reader.readAlongCue(reader.readAlong.session.cue, { reached: 1 })
    await reader.readerReflow
    expect(displays).toEqual([])
    await check({ reader, rendition, displays, writes, sizes, PAGE, HEARD })
  } finally {
    for (const [key, value] of originals) value === undefined ? delete globalThis[key] : globalThis[key] = value
  }
}

test("a window or orientation change while following shows the cue being heard, silently", async () => {
  await withLayout({}, async ({ reader, rendition, displays, writes, PAGE, HEARD }) => {
    rendition.resize()
    await reader.readerReflow
    // EPUB.js shows its own location first; the reader then shows the cue heard.
    expect(displays).toEqual([PAGE, HEARD, HEARD])
    expect(reader.readingAnchor).toBe(HEARD)
    expect(reader.readAlong.suspended).toBe(false)
    expect(writes).toEqual([])
    // Later layout changes keep the place heard, even once narration pauses.
    reader.readAlong.session.playing = false
    rendition.resize()
    await reader.readerReflow
    expect(displays.slice(3)).toEqual([HEARD, HEARD, HEARD])
    expect(writes).toEqual([])
  })
})

test("a text size change while following shows the cue being heard, silently", async () => {
  await withLayout({}, async ({ reader, displays, writes, sizes, HEARD }) => {
    reader.resizeText(10)
    await reader.readerReflow
    expect(sizes).toEqual(["115%"])
    expect(displays).toEqual([HEARD])
    expect(reader.readingAnchor).toBe(HEARD)
    expect(writes).toEqual([])
  })
})

for (const [name, state] of [
  ["Follow is off", { follow: false }],
  ["the reader is browsing away from the narration", { suspended: true }],
  ["narration is paused", { session: { playing: false, cue: 1 } }],
  ["narration is between cues", { session: { playing: true, cue: -1 } }]
]) {
  test(`layout changes keep the reading anchor when ${name}`, async () => {
    await withLayout(state, async ({ reader, rendition, displays, writes, sizes, PAGE }) => {
      const suspended = reader.readAlong.suspended
      rendition.resize()
      reader.resizeText(10)
      await reader.readerReflow
      expect(sizes).toEqual(["115%"])
      expect(displays).toEqual([PAGE, PAGE, PAGE, PAGE])
      expect(reader.readingAnchor).toBe(PAGE)
      expect(reader.readAlong.suspended).toBe(suspended)
      expect(reader.readAlong.follow).toBe(state.follow ?? true)
      expect(writes).toEqual([])
    })
  })
}
