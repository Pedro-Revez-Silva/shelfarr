import { expect, test } from "bun:test"
import { ListeningCheckpoints } from "../../app/javascript/consumer_progress_sync.js"
import { ReadAlongError, ReadAlongSession, cueAt, cueReached, describeCoverage, locatorFor, nextTrack, placeFromAudio, placeFromLocator, prepareManifest,
  trackKey } from "../../app/javascript/consumer_read_along.js"
import { assetUrls, bytesOf, editionOf, sizeOf, snapshot, streamedReadAlong } from "../../app/javascript/consumer_offline.js"

const ORIGIN = "https://reader.example"
const ASSET = "a".repeat(64)
const GENERATION = "b".repeat(64)

// Two files: cues 0-2 on the first (with a gap before cue 2), cue 3 on the second.
function manifest(overrides = {}) {
  return {
    version: 1, generation: GENERATION, source: "media_overlay", ebook_asset_id: ASSET, package_path: "OEBPS/content.opf",
    text: [{ href: "OEBPS/one.xhtml" }, { href: "OEBPS/two.xhtml" }],
    audio: [{ kind: "epub_resource", href: "OEBPS/a.mp3", url: "/shelf/read/1/assets/x/read_along/resources/OEBPS/a.mp3", size_bytes: 10 },
      { kind: "epub_resource", href: "OEBPS/b.mp3", url: "/shelf/read/1/assets/x/read_along/resources/OEBPS/b.mp3", size_bytes: 20 }],
    cue_fields: ["text", "fragment", "audio", "begin_ms", "end_ms"],
    cues: [[0, "p1", 0, 0, 1800], [0, "p2", 0, 2000, 3800], [1, "p3", 0, 5000, 6000], [1, "p4", 1, 0, null]],
    coverage: { complete: false, text_sections: 3, aligned_sections: 2 },
    resources: [{ href: "OEBPS/one.xhtml", url: "/shelf/read/1/assets/x/read_along/resources/OEBPS/one.xhtml", size_bytes: 5 }],
    resources_url: "/shelf/read/1/assets/x/read_along/resources/", resources_bytes: 5, ...overrides
  }
}
const prepare = (value = manifest(), options = {}) => prepareManifest(value, { assetId: ASSET, generation: GENERATION, origin: ORIGIN, ...options })

test("a manifest is used only for its exact edition and generation", () => {
  expect(prepare().count).toBe(4)
  expect(() => prepare(manifest(), { generation: "c".repeat(64) })).toThrow(ReadAlongError)
  expect(() => prepare(manifest(), { assetId: "d".repeat(64) })).toThrow("another edition")
  expect(() => prepare(manifest({ version: 2 }))).toThrow("unsupported version")
  expect(() => prepare(manifest({ cue_fields: ["text"] }))).toThrow("unknown layout")
})

test("invalid cues, overlaps, unsafe paths and foreign URLs refuse the whole manifest", () => {
  const cues = manifest().cues
  for (const bad of [
    [[0, "p1", 0, 1800, 1800]], [[0, "p1", 0, 2000, 1000]], [[0, "p1", 0, -5, 10]], [[0, "p1", 0, 0.5, 10]],
    [[2, "p1", 0, 0, 10]], [[0, "p1", 5, 0, 10]], [[0, "", 0, 0, 10]], [[0, "p1", 0, 0, 49 * 3_600_000]],
    [[0, "p1", 0, 0, 3000], [0, "p2", 0, 2000, 3800]], [[0, "p1", 0, 0, null], [0, "p2", 0, 2000, 3800]], []
  ]) expect(() => prepare(manifest({ cues: bad }))).toThrow(ReadAlongError)
  expect(() => prepare(manifest({ text: [{ href: "../one.xhtml" }, { href: "OEBPS/two.xhtml" }] }))).toThrow("unsafe")
  expect(() => prepare(manifest({ audio: [{ url: "https://elsewhere.example/a.mp3" }, manifest().audio[1]] }))).toThrow("another server")
  expect(() => prepare(manifest({ resources_url: "//elsewhere.example/r/" }))).toThrow("another server")
  expect(prepare(manifest({ cues })).count).toBe(4)
})

test("the cue heard is found by time, and gaps highlight nothing", () => {
  const prepared = prepare()
  expect(cueAt(prepared, 0, 0)).toBe(0)
  expect(cueAt(prepared, 0, 1799)).toBe(0)
  expect(cueAt(prepared, 0, 1900)).toBe(-1)
  expect(cueAt(prepared, 0, 2000)).toBe(1)
  expect(cueAt(prepared, 0, 4500)).toBe(-1)
  expect(cueReached(prepared, 0, 4500)).toBe(1)
  expect(cueAt(prepared, 0, 5500)).toBe(2)
  expect(cueAt(prepared, 1, 999_999)).toBe(3)
  expect(cueReached(prepared, 0, -1)).toBe(-1)
  expect(nextTrack(prepared, 0)).toBe(1)
  expect(nextTrack(prepared, 1)).toBe(-1)
})

test("a heard place names the reached element and the exact audio offset, and restores exactly", () => {
  const prepared = prepare()
  expect(locatorFor(prepared, 0, 100)).toEqual({ href: "OEBPS/one.xhtml", type: "application/xhtml+xml",
    locations: { fragments: ["p1"], readAlong: { generation: GENERATION, audio: 0, offset_ms: 100 } } })
  const locator = locatorFor(prepared, 0, 4500, { cfi: "epubcfi(/6/2!/4/2)", totalProgression: 0.25 })
  expect(locator.locations.fragments).toEqual(["p2"])
  expect(placeFromLocator(prepared, locator)).toEqual({ track: 0, ms: 4500, cue: 1, exact: true })
  // Another generation's offset is not trusted; its element still is.
  const stale = { ...locator, locations: { ...locator.locations, readAlong: { generation: "e".repeat(64), audio: 0, offset_ms: 4500 } } }
  expect(placeFromLocator(prepared, stale)).toEqual({ track: 0, ms: 2000, cue: 1, exact: false })
  // An offset that disagrees with the element is not trusted either.
  const moved = { ...locator, href: "OEBPS/two.xhtml", locations: { fragments: ["p3"], readAlong: locator.locations.readAlong } }
  expect(placeFromLocator(prepared, moved)).toEqual({ track: 0, ms: 5000, cue: 2, exact: false })
  expect(placeFromLocator(prepared, { href: "OEBPS/one.xhtml", locations: { cfi: "epubcfi(/6/2)" } })).toBeNull()
  expect(placeFromAudio(prepare(manifest({ audio: [{ ...manifest().audio[0], asset_id: "f".repeat(64) }, manifest().audio[1]] })), "f".repeat(64), 2.5))
    .toEqual({ track: 0, ms: 2500, cue: 1, exact: true })
})

test("coverage is described plainly", () => {
  expect(describeCoverage({ complete: true, text_sections: 4, aligned_sections: 4 })).toBe("Narration covers all 4 sections.")
  expect(describeCoverage({ complete: false, text_sections: 3, aligned_sections: 2 })).toBe("Narration covers 2 of 3 sections; the others show text only.")
  expect(describeCoverage({})).toBe("")
})

class FakeAudio {
  constructor() { this.listeners = {}; this.paused = true; this.ended = false; this.currentTime = 0; this.duration = 16; this.src = null }
  addEventListener(type, handler) { (this.listeners[type] ||= []).push(handler) }
  removeEventListener(type, handler) { this.listeners[type] = (this.listeners[type] || []).filter(item => item !== handler) }
  emit(type) { for (const handler of this.listeners[type] || []) handler() }
  getAttribute(name) { return name === "src" ? this.src : null }
  removeAttribute() { this.src = null }
  load() { queueMicrotask(() => this.emit("loadedmetadata")) }
  async play() { this.paused = false; this.emit("play") }
  pause() { if (!this.paused) { this.paused = true; this.emit("pause") } }
  advance(seconds) { this.currentTime += seconds; this.emit("timeupdate") }
}

function session() {
  let clock = 1_000_000
  const saved = []
  const audio = new FakeAudio()
  const checkpoints = new ListeningCheckpoints({ record: place => saved.push(place), now: () => clock })
  const cues = []
  const value = new ReadAlongSession({ prepared: prepare(), audio, checkpoints, now: () => clock, frame: () => 0,
    onCue: cue => cues.push(cue) })
  return { value, audio, saved, cues, tick: ms => { clock += ms } }
}

test("restoring a place plays and records nothing; a resume rewinds five seconds once", async () => {
  const { value, audio, saved, tick } = session()
  await value.prepare(0, 15_000)
  expect(audio.currentTime).toBe(15)
  expect(audio.paused).toBe(true)
  expect(saved).toEqual([])
  await value.resume()
  expect(audio.currentTime).toBe(10)
  // Pausing and playing again inside the replayed span neither records nor rewinds again.
  tick(1000); audio.advance(1); audio.pause()
  expect(saved).toEqual([])
  await value.resume()
  expect(audio.currentTime).toBe(11)
  tick(1000); audio.advance(1); audio.pause(); await value.resume()
  expect(audio.currentTime).toBe(12)
  expect(saved).toEqual([])
  // Past the original place, listening is recorded again, within five seconds.
  for (let second = 0; second < 6; second++) { tick(1000); audio.advance(1) }
  expect(saved.length).toBe(1)
  expect(saved[0]).toEqual({ asset_id: trackKey(0), position_seconds: 16 })
})

test("failed narration restoration finishes without activity and the same track can be retried", async () => {
  const { value, audio, saved } = session()
  audio.load = () => queueMicrotask(() => audio.emit("error"))
  expect(await value.prepare(0, 3000)).toBe(false)
  expect(value.ready).toBe(false)
  expect(saved).toEqual([])
  audio.load = FakeAudio.prototype.load.bind(audio)
  expect(await value.prepare(0, 3000)).toBe(true)
  expect(audio.currentTime).toBe(3)
  expect(audio.paused).toBe(true)
  expect(saved).toEqual([])
  value.close()
})

test("closing a pending narration restore releases its waiter without playing or saving", async () => {
  const { value, audio, saved } = session()
  audio.load = () => {}
  const pending = value.prepare(0, 3000)
  value.close()
  expect(await pending).toBe(false)
  expect(audio.paused).toBe(true)
  expect(audio.src).toBe(null)
  expect(saved).toEqual([])
})

test("retrying failed narration keeps the requested place and its replay floor", async () => {
  const { value, audio, saved } = session()
  audio.load = () => queueMicrotask(() => audio.emit("error"))
  expect(await value.prepare(0, 15000)).toBe(false)
  audio.load = FakeAudio.prototype.load.bind(audio)
  await value.resume()
  expect(audio.currentTime).toBe(10)
  expect(saved).toEqual([])
  // Failure within the replayed span must not lower the original 15s floor.
  audio.currentTime = 11
  audio.emit("error")
  await value.resume()
  expect(audio.currentTime).toBe(11)
  value.pause()
  expect(saved).toEqual([])
  value.close()
})

test("an audio error immediately saves the last point actually heard", async () => {
  const { value, audio, saved, tick } = session()
  await value.prepare(0, 0)
  await value.playFrom(0)
  tick(1000)
  audio.advance(1)
  const before = saved.length
  audio.currentTime = 1.75
  audio.emit("error")
  expect(saved.length).toBe(before + 1)
  expect(saved.at(-1)).toEqual({ asset_id: trackKey(0), position_seconds: 1.75 })
  value.close()
})

test("playing saves at most every five seconds of activity, and pause saves at once", async () => {
  const { value, audio, saved, tick } = session()
  await value.prepare(0, 0)
  // Starting exactly at the restored place is nothing new to save.
  await value.playFrom(0)
  expect(saved).toEqual([])
  for (let step = 0; step < 20; step++) { tick(500); audio.advance(0.5) }
  // Ten seconds of listening: checkpoints no more than five seconds apart.
  const positions = saved.map(place => place.position_seconds)
  for (let index = 1; index < positions.length; index++) expect(positions[index] - positions[index - 1]).toBeLessThanOrEqual(5)
  expect(10 - positions.at(-1)).toBeLessThanOrEqual(5)
  tick(300); audio.advance(0.3); audio.pause()
  expect(saved.at(-1).position_seconds).toBeCloseTo(10.3, 5)
})

test("the highlight follows cues and clears in gaps, and the next file follows the last", async () => {
  const { value, audio, cues, saved } = session()
  await value.prepare(0, 0)
  await value.playFrom(0)
  audio.currentTime = 1.9; audio.emit("timeupdate")
  audio.currentTime = 2.1; audio.emit("timeupdate")
  audio.currentTime = 4.5; audio.emit("timeupdate")
  expect(cues.filter((cue, index) => cue !== cues[index - 1])).toEqual([0, -1, 1, -1])
  audio.paused = true; audio.ended = true; audio.emit("ended")
  await new Promise(resolve => setTimeout(resolve, 0))
  expect(value.track).toBe(1)
  expect(audio.src).toBe("/shelf/read/1/assets/x/read_along/resources/OEBPS/b.mp3")
  expect(saved.at(-1)).toEqual({ asset_id: trackKey(1), position_seconds: 0 })
})

const readAlongAsset = files => ({ id: ASSET, filename: "a.epub", format: "epub", media_type: "application/epub+zip", size_bytes: 500_000_000,
  position: 0, content_url: "/read/1/assets/a", read_along: { status: "available", source: "media_overlay", generation: GENERATION,
    manifest_url: "/read/1/assets/a/read_along", text_bytes: 1000, audio_bytes: 400_000_000, ...(files ? { files } : {}) } })

test("a read-along download is the manifest and its listed files, never the whole EPUB, and never ready without its list", () => {
  globalThis.location ||= { origin: ORIGIN }
  const pending = readAlongAsset()
  expect(streamedReadAlong(pending)).toBe(true)
  expect(assetUrls(pending)).toEqual([`${location.origin}/read/1/assets/a/read_along`])
  expect(sizeOf(pending)).toBe(400_001_000)
  const files = [{ url: "/read/1/assets/a/read_along/resources/OEBPS/one.xhtml", size_bytes: 1000 }, { url: "/read/1/assets/a/read_along/resources/OEBPS/a.mp3", size_bytes: 400_000_000 }]
  const complete = readAlongAsset(files)
  expect(assetUrls(complete)).toEqual([`${location.origin}/read/1/assets/a/read_along`, ...files.map(file => `${location.origin}${file.url}`)])
  expect(bytesOf({ assets: [complete] })).toBe(400_001_000)
  // A new alignment for the same file is a new edition.
  expect(editionOf({ assets: [complete] })).not.toBe(editionOf({ assets: [{ ...complete, read_along: { ...complete.read_along, generation: "c".repeat(64) } }] }))
  // A summary over the web text limit falls back to the whole EPUB.
  const large = { ...pending, read_along: { ...pending.read_along, text_bytes: 64 * 1024 * 1024 } }
  expect(streamedReadAlong(large)).toBe(false)
  expect(assetUrls(large)).toEqual([`${location.origin}/read/1/assets/a`])
  const kept = snapshot({ id: "1", book_type: "ebook", assets: [{ ...complete, read_along: { ...complete.read_along, secret: "no" } }],
    read_along_audiobook: { id: "2", title: "Heard", progress_url: "/read/2/progress", progress: null } })
  expect(kept.assets[0].read_along).not.toHaveProperty("secret")
  expect(kept.assets[0].read_along.files).toEqual(files)
  expect(kept.read_along_audiobook.id).toBe("2")
})
