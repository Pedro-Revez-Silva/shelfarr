// Read-along for the browser reader: follow real narration in the text.
//
// The server's manifest (docs/read-along.md) names cues: one element of one
// text document and one interval of one audio resource. This module checks a
// manifest before anything uses it, finds the cue being heard, and maps
// between cues and saved places. It never estimates timing: between cues,
// nothing is highlighted, and a place is only ever derived from a cue that
// was actually reached.
//
// ReadAlongSession plays the narration through one <audio> element. Audio
// plays straight through each file (what you hear is the file), and moves to
// the next file at its end. Listening checkpoints (the shared
// ListeningCheckpoints rules: at most five seconds between saves, one
// five-second resume rewind, restoring is not activity) are recorded through
// a callback that receives the exact audio place.

export const MANIFEST_VERSION = 1
export const CUE_FIELDS = ["text", "fragment", "audio", "begin_ms", "end_ms"]
export const MAX_CUES = 200_000
export const MAX_AUDIO = 2_000
export const WEB_TEXT_LIMIT = 32 * 1024 * 1024
const MAX_MS = 48 * 3_600_000
const HEX = /^[0-9a-f]{64}$/
const OVERLAP_TOLERANCE_MS = 5

export class ReadAlongError extends Error {
  constructor(kind, message) { super(message); this.kind = kind }
}

const sameOrigin = (value, origin) => {
  if (typeof value !== "string" || !value) return false
  try { return new URL(value, origin).origin === new URL(origin).origin } catch (_) { return false }
}

// A validated, indexed copy of a manifest for this exact EPUB asset and
// generation, or a ReadAlongError explaining why it can't be used.
export function prepareManifest(manifest, { assetId, generation, origin = globalThis.location?.origin } = {}) {
  const fail = message => { throw new ReadAlongError("invalid", message) }
  if (!manifest || typeof manifest !== "object" || manifest.version !== MANIFEST_VERSION) fail("This read-along data is from an unsupported version.")
  if (!HEX.test(manifest.generation || "") || (generation && manifest.generation !== generation)) throw new ReadAlongError("changed", "This book's read-along data changed. Reload to use the current edition.")
  if (assetId && manifest.ebook_asset_id !== assetId) throw new ReadAlongError("changed", "This read-along data belongs to another edition.")
  if (JSON.stringify(manifest.cue_fields) !== JSON.stringify(CUE_FIELDS)) fail("This read-along data has an unknown layout.")
  const texts = Array.isArray(manifest.text) ? manifest.text : []
  const audio = Array.isArray(manifest.audio) ? manifest.audio : []
  const cues = Array.isArray(manifest.cues) ? manifest.cues : []
  if (!texts.length || !audio.length || audio.length > MAX_AUDIO || !cues.length || cues.length > MAX_CUES) fail("This read-along data is empty or too large.")
  for (const text of texts) if (typeof text?.href !== "string" || !text.href || text.href.startsWith("/") || text.href.split("/").includes("..")) fail("This read-along data names an unsafe text document.")
  for (const track of audio) if (!sameOrigin(track?.url, origin)) fail("This read-along data names audio on another server.")
  if (!sameOrigin(manifest.resources_url, origin)) fail("This read-along data names text on another server.")
  const begins = new Float64Array(cues.length), ends = new Float64Array(cues.length)
  const audioOf = new Int32Array(cues.length), textOf = new Int32Array(cues.length)
  const fragments = new Array(cues.length)
  const byFragment = new Map()
  cues.forEach((cue, index) => {
    const [text, fragment, track, begin, end] = Array.isArray(cue) ? cue : []
    if (!Number.isInteger(text) || text < 0 || text >= texts.length || typeof fragment !== "string" || !fragment || fragment.length > 256 ||
      !Number.isInteger(track) || track < 0 || track >= audio.length || !Number.isInteger(begin) || begin < 0 || begin > MAX_MS ||
      !(end === null || (Number.isInteger(end) && end > begin && end <= MAX_MS))) fail("This read-along data has an invalid cue.")
    textOf[index] = text; fragments[index] = fragment; audioOf[index] = track; begins[index] = begin; ends[index] = end === null ? Infinity : end
    const key = `${texts[text].href}#${fragment}`
    if (!byFragment.has(key)) byFragment.set(key, index)
  })
  // Per audio, cue indices sorted by start; intervals may not overlap.
  const byAudio = audio.map(() => [])
  for (let index = 0; index < cues.length; index++) byAudio[audioOf[index]].push(index)
  for (const list of byAudio) {
    list.sort((left, right) => begins[left] - begins[right])
    for (let position = 1; position < list.length; position++) {
      if (begins[list[position]] < ends[list[position - 1]] - OVERLAP_TOLERANCE_MS) fail("This read-along data has overlapping cues.")
    }
  }
  const resourcesBytes = Number(manifest.resources_bytes)
  return {
    generation: manifest.generation, source: manifest.source, assetId: manifest.ebook_asset_id, packagePath: manifest.package_path,
    texts: texts.map(text => text.href), audio, coverage: manifest.coverage || {}, resources: Array.isArray(manifest.resources) ? manifest.resources : [],
    resourcesUrl: manifest.resources_url, resourcesBytes: Number.isFinite(resourcesBytes) ? resourcesBytes : Infinity,
    count: cues.length, begins, ends, audioOf, textOf, fragments, byAudio, byFragment
  }
}

export const hrefOf = (prepared, cue) => prepared.texts[prepared.textOf[cue]]

// The cue whose interval contains `ms` on this audio, or -1 between cues.
export function cueAt(prepared, track, ms) {
  const list = prepared.byAudio[track]
  if (!list?.length || !Number.isFinite(ms)) return -1
  let low = 0, high = list.length - 1, found = -1
  while (low <= high) {
    const middle = (low + high) >> 1
    if (prepared.begins[list[middle]] <= ms) { found = middle; low = middle + 1 } else high = middle - 1
  }
  if (found < 0) return -1
  const cue = list[found]
  return ms < prepared.ends[cue] ? cue : -1
}

// The last cue on this audio that started at or before `ms` (the narration
// most recently reached), or -1 before the first one.
export function cueReached(prepared, track, ms) {
  const list = prepared.byAudio[track]
  if (!list?.length || !Number.isFinite(ms)) return -1
  let low = 0, high = list.length - 1, found = -1
  while (low <= high) {
    const middle = (low + high) >> 1
    if (prepared.begins[list[middle]] <= ms) { found = middle; low = middle + 1 } else high = middle - 1
  }
  return found < 0 ? -1 : list[found]
}

export function cueForFragment(prepared, href, fragment) {
  const cue = prepared.byFragment.get(`${href}#${fragment}`)
  return cue === undefined ? -1 : cue
}

// The saved place for narration heard at `ms` of audio `track`: the reached
// cue's element plus the exact audio offset. Null before any cue.
export function locatorFor(prepared, track, ms, extra = {}) {
  const cue = cueReached(prepared, track, ms)
  if (cue < 0) return null
  const locations = { fragments: [prepared.fragments[cue]], ...extra,
    readAlong: { generation: prepared.generation, audio: track, offset_ms: Math.max(0, Math.round(ms)) } }
  for (const key of Object.keys(locations)) if (locations[key] === undefined) delete locations[key]
  return { href: hrefOf(prepared, cue), type: "application/xhtml+xml", locations }
}

// Where a saved locator puts the narration: its exact audio offset when it
// was saved against this generation, otherwise the start of its element's
// cue. Null when it names neither.
export function placeFromLocator(prepared, locator) {
  if (!locator || typeof locator !== "object") return null
  const point = locator.locations?.readAlong
  if (point && point.generation === prepared.generation && Number.isInteger(point.audio) && prepared.byAudio[point.audio] &&
    Number.isInteger(point.offset_ms) && point.offset_ms >= 0 && point.offset_ms <= MAX_MS) {
    const cue = cueReached(prepared, point.audio, point.offset_ms)
    if (cue >= 0 && hrefOf(prepared, cue) === locator.href) return { track: point.audio, ms: point.offset_ms, cue, exact: true }
  }
  const fragment = Array.isArray(locator.locations?.fragments) ? locator.locations.fragments[0] : null
  const cue = typeof fragment === "string" ? cueForFragment(prepared, locator.href, fragment) : -1
  return cue >= 0 ? { track: prepared.audioOf[cue], ms: prepared.begins[cue], cue, exact: false } : null
}

// Where an audiobook position (imported alignments) lands in the text, or null.
export function placeFromAudio(prepared, assetId, seconds) {
  const track = prepared.audio.findIndex(audio => audio.asset_id === assetId)
  if (track < 0 || !Number.isFinite(seconds)) return null
  const ms = Math.round(seconds * 1000)
  const cue = cueReached(prepared, track, ms)
  return cue >= 0 ? { track, ms, cue, exact: true } : null
}

// The next file in narration order that has cues, after `track`.
export function nextTrack(prepared, track) {
  for (let next = track + 1; next < prepared.audio.length; next++) if (prepared.byAudio[next].length) return next
  return -1
}

// A short description for the controls overlay.
export function describeCoverage(coverage) {
  const total = Number(coverage?.text_sections), aligned = Number(coverage?.aligned_sections)
  if (!Number.isInteger(total) || !Number.isInteger(aligned) || total <= 0) return ""
  if (coverage.complete || aligned >= total) return total === 1 ? "Narration covers the whole text." : `Narration covers all ${total} sections.`
  return `Narration covers ${aligned} of ${total} sections; the others show text only.`
}

export const trackKey = track => `read-along:${track}`

// Plays narration through one audio element and reports the cue heard.
export class ReadAlongSession {
  constructor({ prepared, audio, checkpoints, onCue = () => {}, onState = () => {}, onError = () => {}, onRecord = () => {},
    resolveUrl = url => url, now = () => Date.now(), frame = callback => globalThis.requestAnimationFrame?.(callback) }) {
    this.prepared = prepared
    this.audio = audio
    this.checkpoints = checkpoints
    this.onCue = onCue
    this.onState = onState
    this.onError = onError
    this.onRecord = onRecord
    this.resolveUrl = resolveUrl
    this.now = now
    this.frame = frame
    this.track = -1
    this.cue = -1
    this.ready = false
    this.closed = false
    this.retry = null
    this.listeners = {
      loadedmetadata: () => this.loaded(),
      timeupdate: () => this.tick(),
      play: () => { this.onState("playing"); this.loop() },
      pause: () => this.paused(),
      ended: () => this.ended(),
      error: () => this.failed()
    }
    for (const [type, listener] of Object.entries(this.listeners)) audio.addEventListener(type, listener)
  }

  get playing() { return this.ready && !this.audio.paused && !this.audio.ended }
  get positionMs() { return Math.round((this.audio.currentTime || 0) * 1000) }

  // Show a place without playing or recording it (restoring is not activity).
  prepare(track, ms) {
    if (this.closed || !this.prepared.audio[track]) return Promise.resolve(false)
    if (track !== this.track || !this.ready) return this.load(track, ms, { autoplay: false, restored: true })
    this.audio.currentTime = ms / 1000
    this.checkpoints.restored(this.audio.currentTime, trackKey(track))
    this.report()
    return Promise.resolve(true)
  }

  // A genuine resume: rewinds once (five seconds) and plays.
  async resume() {
    if (this.closed || this.track < 0) return
    if (!this.ready) {
      if (this.pending) { this.playWhenReady = true; return }
      const retry = this.retry || { ms: this.positionMs }
      const loaded = await this.load(this.track, retry.ms, { ...retry, autoplay: false })
      if (loaded === false || this.closed) return false
      return this.resume()
    }
    const from = this.checkpoints.resume(this.audio.currentTime)
    if (from !== this.audio.currentTime) this.audio.currentTime = from
    await this.start()
  }

  // A deliberate start at a cue (for example "play from this page"): saved
  // at once, and no rewind.
  async playFrom(cue) {
    if (this.closed || cue < 0 || cue >= this.prepared.count) return
    const track = this.prepared.audioOf[cue], ms = this.prepared.begins[cue]
    if (track !== this.track || !this.ready) {
      await this.load(track, ms, { autoplay: true, deliberate: true })
      return
    }
    this.audio.currentTime = ms / 1000
    this.checkpoints.deliberate(this.audio.currentTime, trackKey(track), false)
    this.report(true)
    await this.start()
  }

  // Seek within the current file by `seconds` (deliberate).
  skip(seconds) {
    if (!this.ready) return
    const duration = Number.isFinite(this.audio.duration) ? this.audio.duration : Infinity
    this.audio.currentTime = Math.max(0, Math.min(duration, this.audio.currentTime + seconds))
    this.checkpoints.deliberate(this.audio.currentTime, trackKey(this.track), this.audio.paused)
    this.report(true)
  }

  pause() { if (!this.audio.paused) this.audio.pause() }

  toggle() { return this.audio.paused ? this.resume() : this.pause() }

  // Leaving or hiding the page saves the place heard at once.
  settle() { if (this.ready) this.checkpoints.settle(this.audio.currentTime, trackKey(this.track)) }

  close() {
    this.closed = true
    this.pending?.resolve?.(false)
    this.pending = null
    this.retry = null
    for (const [type, listener] of Object.entries(this.listeners)) this.audio.removeEventListener(type, listener)
    this.audio.pause()
    this.audio.removeAttribute("src")
    this.audio.load?.()
  }

  // Internal ---------------------------------------------------------------

  load(track, ms, { autoplay, restored = false, deliberate = false, continued = false }) {
    this.ready = false
    this.retry = null
    this.track = track
    this.pending = { ms, autoplay, restored, deliberate, continued }
    this.playWhenReady = false
    const url = this.resolveUrl(this.prepared.audio[track].url)
    this.audio.src = url
    this.audio.load?.()
    return new Promise(resolve => { this.pending.resolve = resolve })
  }

  loaded() {
    if (this.closed || !this.pending) return
    const { ms, autoplay, restored, deliberate, continued, resolve } = this.pending
    this.pending = null
    const duration = Number.isFinite(this.audio.duration) ? this.audio.duration : Infinity
    this.audio.currentTime = Math.min(ms / 1000, duration)
    const key = trackKey(this.track)
    if (deliberate) this.checkpoints.deliberate(this.audio.currentTime, key, !autoplay)
    else if (continued) this.checkpoints.continued(key, this.audio.currentTime)
    else if (restored) this.checkpoints.restored(this.audio.currentTime, key)
    this.ready = true
    this.report(deliberate || continued)
    this.onState(this.audio.paused ? "paused" : "playing")
    const start = autoplay || this.playWhenReady
    this.playWhenReady = false
    const result = start ? (restored ? this.resume() : this.start()) : Promise.resolve()
    result.finally(() => resolve?.(true))
  }

  failed() {
    if (this.closed || !this.audio.getAttribute("src")) return
    if (this.ready) {
      this.checkpoints.settle(this.audio.currentTime, trackKey(this.track))
      this.onRecord("error")
    }
    const pending = this.pending
    this.retry = pending ? { ms: pending.ms, restored: pending.restored, deliberate: pending.deliberate, continued: pending.continued } : { ms: this.positionMs }
    this.pending = null
    this.playWhenReady = false
    this.ready = false
    pending?.resolve?.(false)
    this.onState("paused")
    this.onError("The narration couldn't be loaded. Check the connection or sign in again.")
  }

  async start() {
    try {
      this.checkpoints.active = true
      await this.audio.play()
    } catch (error) {
      if (error?.name !== "AbortError") this.onError("Playback couldn't start. Check the connection and try Play again.")
    }
  }

  tick() {
    if (this.closed || !this.ready) return
    this.report()
    if (!this.audio.paused) this.checkpoints.tick(this.audio.currentTime, trackKey(this.track))
  }

  // Animation frames keep the highlight close to the words between the
  // browser's (roughly quarter-second) timeupdate events.
  loop() {
    if (this.looping || this.closed) return
    this.looping = true
    const step = () => {
      if (this.closed || !this.playing) { this.looping = false; return }
      this.report()
      this.frame(step)
    }
    if (!this.frame(step)) this.looping = false
  }

  report(force = false) {
    const cue = cueAt(this.prepared, this.track, this.positionMs)
    if (cue === this.cue && !force) return
    this.cue = cue
    this.onCue(cue, { track: this.track, ms: this.positionMs, reached: cueReached(this.prepared, this.track, this.positionMs) })
  }

  paused() {
    if (this.closed) return
    this.onState("paused")
    if (!this.ready || this.audio.ended) return
    this.checkpoints.settle(this.audio.currentTime, trackKey(this.track))
    this.onRecord("pause")
  }

  // The file finished: continue with the next narrated file, or stop.
  ended() {
    if (this.closed) return
    const next = nextTrack(this.prepared, this.track)
    this.checkpoints.settle(this.audio.currentTime, trackKey(this.track))
    if (next < 0) { this.onState("finished"); this.onRecord("finished"); return }
    // Like an audiobook track change, the next file plays from its start.
    this.load(next, 0, { autoplay: true, continued: true })
  }
}
