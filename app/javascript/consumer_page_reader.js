// Fixed-layout reading in the browser: PDF pages and CBZ comic pages.
//
// PDFs render with the self-hosted PDF.js engine: no scripting, forms, XFA or
// annotation layer, and its worker, fonts, CMaps and WebAssembly come only from
// Shelfarr's digested assets. Pages are canvases with a selectable text layer.
//
// CBZ pages are read one at a time with byte ranges, following the server's
// reading order for this exact file generation. Each page's local ZIP header is
// checked against that order, the data is inflated within its announced size,
// its length and CRC-32 are verified, and its image dimensions are read from
// the header and bounded before the browser decodes it. Nothing extracts the
// whole archive. Range reads work offline through the reader's service worker.
//
// The page reader reports page changes with `activity: true` only when the
// reader turns or chooses a page. Opening, restoring, zooming, resizing and
// re-rendering are never reading activity.

export const LIMITS = Object.freeze({
  pages: 100_000,
  pageBytes: 32 * 1024 * 1024,
  // Enough for ordinary DEFLATE overhead, without accepting arbitrarily many
  // empty blocks for a tiny decoded image.
  compressedPageBytes: 32 * 1024 * 1024 + 64 * 1024,
  imageSide: 16_384,
  imagePixels: 40_000_000,
  canvasPixels: 16_000_000,
  zoomMin: 1,
  zoomMax: 4,
  localHeaderSlack: 512
})

export const IMAGE_TYPES = Object.freeze(["image/jpeg", "image/png", "image/webp"])

export class PageError extends Error {
  constructor(message, kind = "page") { super(message); this.kind = kind }
}

// ZIP and images ---------------------------------------------------------------

const CRC_TABLE = (() => {
  const table = new Uint32Array(256)
  for (let n = 0; n < 256; n += 1) {
    let c = n
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
    table[n] = c >>> 0
  }
  return table
})()

export function crc32(bytes) {
  let crc = 0xffffffff
  for (let index = 0; index < bytes.length; index += 1) crc = CRC_TABLE[(crc ^ bytes[index]) & 0xff] ^ (crc >>> 8)
  return ((crc ^ 0xffffffff) >>> 0).toString(16).padStart(8, "0")
}

const isCount = (value, max = Number.MAX_SAFE_INTEGER) => Number.isSafeInteger(value) && value >= 0 && value <= max

// The server's page order for one CBZ generation, checked before any page is read.
export function validateReadingOrder(order, asset) {
  const items = order?.items
  if (!order || order.asset_id !== asset.id || order.format !== "cbz" || !Array.isArray(items) || !items.length || items.length > LIMITS.pages) {
    throw new PageError("This comic's page list doesn't match the file. Refresh and try again.", "order")
  }
  if (Number.isInteger(asset.page_count) && asset.page_count !== items.length) throw new PageError("This comic's page list doesn't match the file. Refresh and try again.", "order")
  items.forEach((item, index) => {
    const ok = item && item.position === index + 1 && typeof item.href === "string" && item.href.length > 0 && item.href.length <= 4096 &&
      IMAGE_TYPES.includes(item.media_type) && (item.compression_method === 0 || item.compression_method === 8) &&
      isCount(item.size_bytes, LIMITS.pageBytes) && item.size_bytes > 0 && isCount(item.compressed_size, LIMITS.compressedPageBytes) && item.compressed_size > 0 &&
      (item.compression_method === 8 || item.compressed_size === item.size_bytes) &&
      isCount(item.local_header_offset) && item.local_header_offset + 30 + item.compressed_size <= asset.size_bytes &&
      /^[0-9a-f]{8}$/.test(item.crc32 || "")
    if (!ok) throw new PageError("This comic's page list is damaged.", "order")
  })
  return items
}

// The ZIP entry name for an href (percent-encoded UTF-8 bytes).
export function entryNameBytes(href) {
  const bytes = []
  for (let index = 0; index < href.length; index += 1) {
    const char = href[index]
    if (char === "%") {
      const hex = href.slice(index + 1, index + 3)
      if (!/^[0-9A-Fa-f]{2}$/.test(hex)) throw new PageError("This comic's page list is damaged.", "order")
      bytes.push(parseInt(hex, 16))
      index += 2
    } else {
      const code = char.charCodeAt(0)
      if (code > 0x7e || code < 0x21) throw new PageError("This comic's page list is damaged.", "order")
      bytes.push(code)
    }
  }
  return Uint8Array.from(bytes)
}

// Where an entry's data starts inside `bytes` (which begin at its local
// header), after checking the header describes this same entry.
export function localDataStart(bytes, item, name) {
  if (bytes.length < 30) throw new PageError("This page is incomplete.", "verify")
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  const flags = view.getUint16(6, true)
  const method = view.getUint16(8, true)
  const nameLength = view.getUint16(26, true)
  const extraLength = view.getUint16(28, true)
  if (view.getUint32(0, true) !== 0x04034b50 || method !== item.compression_method || nameLength !== name.length || (flags & 0x0041) !== 0) {
    throw new PageError("This page's header doesn't match the comic's page list.", "verify")
  }
  if (bytes.length < 30 + nameLength) return { start: 30 + nameLength + extraLength }
  for (let index = 0; index < nameLength; index += 1) {
    if (bytes[30 + index] !== name[index]) throw new PageError("This page's header doesn't match the comic's page list.", "verify")
  }
  return { start: 30 + nameLength + extraLength }
}

// Inflate raw deflate data into at most `size` bytes.
export async function inflateRaw(data, size) {
  const stream = new Blob([data]).stream().pipeThrough(new DecompressionStream("deflate-raw"))
  const reader = stream.getReader()
  const out = new Uint8Array(size)
  let length = 0
  try {
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      if (length + value.length > size) throw new PageError("This page is larger than the comic says.", "verify")
      out.set(value, length)
      length += value.length
    }
  } catch (error) {
    reader.cancel().catch(() => {})
    throw error instanceof PageError ? error : new PageError("This page is damaged.", "verify")
  }
  if (length !== size) throw new PageError("This page is incomplete.", "verify")
  return out
}

// Image type and dimensions from the file header, before anything decodes it.
export function imageInfo(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  const ascii = (offset, length) => String.fromCharCode(...bytes.subarray(offset, offset + length))
  if (bytes.length >= 24 && view.getUint32(0) === 0x89504e47 && ascii(12, 4) === "IHDR") {
    return { type: "image/png", width: view.getUint32(16), height: view.getUint32(20) }
  }
  if (bytes.length >= 4 && bytes[0] === 0xff && bytes[1] === 0xd8) {
    let offset = 2
    for (let markers = 0; offset + 9 < bytes.length && markers < 4096; markers += 1) {
      if (bytes[offset] !== 0xff) return null
      const marker = bytes[offset + 1]
      if (marker === 0xff) { offset += 1; continue }
      if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) { offset += 2; continue }
      const length = view.getUint16(offset + 2)
      if (length < 2) return null
      if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker)) {
        return { type: "image/jpeg", width: view.getUint16(offset + 7), height: view.getUint16(offset + 5) }
      }
      if (marker === 0xda || marker === 0xd9) return null
      offset += 2 + length
    }
    return null
  }
  if (bytes.length >= 30 && ascii(0, 4) === "RIFF" && ascii(8, 4) === "WEBP") {
    const chunk = ascii(12, 4)
    if (chunk === "VP8 " && bytes[23] === 0x9d && bytes[24] === 0x01 && bytes[25] === 0x2a) {
      return { type: "image/webp", width: view.getUint16(26, true) & 0x3fff, height: view.getUint16(28, true) & 0x3fff }
    }
    if (chunk === "VP8L" && bytes[20] === 0x2f) {
      const bits = view.getUint32(21, true)
      return { type: "image/webp", width: (bits & 0x3fff) + 1, height: ((bits >>> 14) & 0x3fff) + 1 }
    }
    if (chunk === "VP8X") {
      const u24 = offset => bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16)
      return { type: "image/webp", width: u24(24) + 1, height: u24(27) + 1 }
    }
  }
  return null
}

export function checkImage(bytes) {
  const info = imageInfo(bytes)
  if (!info || !IMAGE_TYPES.includes(info.type)) throw new PageError("This page isn't a JPEG, PNG or WebP image.", "image")
  if (!info.width || !info.height || info.width > LIMITS.imageSide || info.height > LIMITS.imageSide || info.width * info.height > LIMITS.imagePixels) {
    throw new PageError("This page image is too large to show safely.", "image")
  }
  return info
}

// Range-reads one page at a time from a CBZ asset and returns verified images.
export class ComicPages {
  constructor({ url, asset, items, fetch: fetcher = globalThis.fetch.bind(globalThis), keep = 3 }) {
    this.url = url
    this.asset = asset
    this.items = items
    this.fetch = fetcher
    this.keep = keep
    this.cache = new Map()
  }

  get count() { return this.items.length }

  async range(start, end, signal) {
    const last = Math.min(end, this.asset.size_bytes - 1)
    const expected = last - start + 1
    if (!isCount(start) || !isCount(last) || expected <= 0 || expected > LIMITS.compressedPageBytes + 30 + 4096 + 65535) {
      throw new PageError("This page's compressed data exceeds the safe download limit.", "verify")
    }
    const response = await this.fetch(this.url, { credentials: "same-origin", redirect: "error", signal, cache: "no-store",
      headers: { Range: `bytes=${start}-${last}`, "If-Range": `"${this.asset.id}"` } })
    if (response.status === 410) throw new PageError("This comic changed on the server. Refresh to open the new edition.", "changed")
    if (response.status === 401 || response.status === 403) throw new PageError("Sign in again to keep reading.", "signin")
    const etag = response.headers.get("ETag")
    if (etag && etag !== `"${this.asset.id}"`) throw new PageError("This comic changed on the server. Refresh to open the new edition.", "changed")
    if (response.status !== 206) throw new PageError("This page couldn't be loaded. Check your connection and try again.", "network")
    const match = /^bytes (\d+)-(\d+)\/(\d+)$/.exec(response.headers.get("Content-Range") || "")
    if (!match || Number(match[1]) !== start || Number(match[2]) !== last || Number(match[3]) !== this.asset.size_bytes) {
      throw new PageError("This page arrived incomplete.", "verify")
    }
    const reader = response.body?.getReader()
    if (!reader) throw new PageError("This page arrived incomplete.", "verify")
    const bytes = new Uint8Array(expected)
    let length = 0
    try {
      for (;;) {
        const { done, value } = await reader.read()
        if (done) break
        if (value.byteLength > expected - length) {
          reader.cancel().catch(() => {})
          throw new PageError("This page arrived larger than requested.", "verify")
        }
        bytes.set(value, length)
        length += value.byteLength
      }
    } finally {
      reader.releaseLock()
    }
    if (length !== expected) throw new PageError("This page arrived incomplete.", "verify")
    return bytes
  }

  async bytes(index, signal) {
    const item = this.items[index]
    if (!item) throw new PageError("This page isn't in the comic.", "order")
    if (!isCount(item.compressed_size, LIMITS.compressedPageBytes) || item.compressed_size === 0) {
      throw new PageError("This page's compressed data exceeds the safe download limit.", "verify")
    }
    const name = entryNameBytes(item.href)
    const offset = item.local_header_offset
    let chunk = await this.range(offset, offset + 30 + name.length + LIMITS.localHeaderSlack + item.compressed_size - 1, signal)
    const { start } = localDataStart(chunk, item, name)
    if (start + item.compressed_size > chunk.length) {
      const rest = await this.range(offset + chunk.length, offset + start + item.compressed_size - 1, signal)
      const joined = new Uint8Array(chunk.length + rest.length)
      joined.set(chunk)
      joined.set(rest, chunk.length)
      chunk = joined
      localDataStart(chunk, item, name)
    }
    const data = chunk.subarray(start, start + item.compressed_size)
    if (data.length !== item.compressed_size) throw new PageError("This page arrived incomplete.", "verify")
    const page = item.compression_method === 8 ? await inflateRaw(data, item.size_bytes) : data
    if (page.length !== item.size_bytes || crc32(page) !== item.crc32) throw new PageError("This page is damaged: its checksum doesn't match.", "verify")
    return page
  }

  // A verified image Blob for page `index`, with its decoded size.
  async page(index, signal) {
    if (this.cache.has(index)) {
      const hit = this.cache.get(index)
      this.cache.delete(index)
      this.cache.set(index, hit)
      return hit
    }
    const loading = this.bytes(index, signal).then(bytes => {
      const info = checkImage(bytes)
      return { blob: new Blob([bytes], { type: info.type }), width: info.width, height: info.height }
    })
    this.cache.set(index, loading)
    loading.catch(() => this.cache.delete(index))
    while (this.cache.size > this.keep) this.cache.delete(this.cache.keys().next().value)
    return loading
  }
}

// PDF.js ---------------------------------------------------------------------------

// PDF.js asks for its fonts, CMaps and WebAssembly by name. Shelfarr serves
// them as digested assets, so names map to exact same-origin URLs from the
// page's resource list; anything not on that list is refused.
export function resourceFactory(resources, fetcher = globalThis.fetch.bind(globalThis)) {
  return class ShelfarrPdfResources {
    async fetch({ kind, filename }) {
      const path = resources?.files?.[kind]?.[filename]
      if (typeof path !== "string") throw new Error(`Unavailable PDF resource: ${kind}`)
      const url = new URL(path, globalThis.location.href)
      if (url.origin !== globalThis.location.origin) throw new Error("PDF resources must be same-origin")
      const response = await fetcher(url.href, { credentials: "same-origin", redirect: "error" })
      if (!response.ok) throw new Error(`PDF resource unavailable: ${response.status}`)
      return new Uint8Array(await response.arrayBuffer())
    }
  }
}

export function pdfOptions(url, resources) {
  return {
    url,
    withCredentials: false,
    rangeChunkSize: 256 * 1024,
    disableAutoFetch: true,
    disableStream: true,
    enableXfa: false,
    useSystemFonts: false,
    useWorkerFetch: false,
    useWasm: true,
    stopAtErrors: false,
    maxImageSize: LIMITS.imagePixels,
    canvasMaxAreaInBytes: LIMITS.canvasPixels * 4,
    cMapPacked: true,
    BinaryDataFactory: resourceFactory(resources),
    verbosity: 0
  }
}

class PdfSource {
  constructor(engine, document) {
    this.engine = engine
    this.document = document
    this.count = document.numPages
  }

  static async open(url, resources, signal) {
    const engine = await import("consumer_pdf_engine")
    const worker = new URL(resources?.worker || "", globalThis.location.href)
    if (!resources?.worker || worker.origin !== globalThis.location.origin) throw new PageError("The PDF renderer isn't available.", "engine")
    engine.GlobalWorkerOptions.workerSrc = worker.href
    const task = engine.getDocument(pdfOptions(url, resources))
    task.onPassword = () => { task.destroy() }
    signal?.addEventListener("abort", () => task.destroy(), { once: true })
    try {
      const document = await task.promise
      if (!document.numPages || document.numPages > LIMITS.pages) throw new PageError("This PDF has no pages Shelfarr can show.", "pdf")
      return new PdfSource(engine, document)
    } catch (error) {
      if (error instanceof PageError) throw error
      if (error?.name === "PasswordException") throw new PageError("This PDF is password-protected. The web reader can't open it.", "pdf")
      if (error?.name === "InvalidPDFException") throw new PageError("This PDF is damaged or isn't a PDF.", "pdf")
      if (error?.name === "ResponseException" || error?.name === "UnexpectedResponseException") throw new PageError("This PDF couldn't be loaded. Check your connection or sign in again.", "network")
      throw new PageError("This PDF couldn't be opened.", "pdf")
    }
  }

  async size(position) {
    const page = await this.document.getPage(position)
    const viewport = page.getViewport({ scale: 1 })
    return { width: viewport.width, height: viewport.height, page }
  }

  // Draw page `position` into `element` at `scale` CSS pixels per PDF point.
  async render(position, element, scale, signal) {
    const page = await this.document.getPage(position)
    const viewport = page.getViewport({ scale })
    const ratio = Math.max(1, Math.min(globalThis.devicePixelRatio || 1, 3))
    const pixels = Math.min(ratio, Math.sqrt(LIMITS.canvasPixels / Math.max(1, viewport.width * viewport.height)))
    const canvas = document.createElement("canvas")
    canvas.width = Math.max(1, Math.floor(viewport.width * pixels))
    canvas.height = Math.max(1, Math.floor(viewport.height * pixels))
    canvas.style.width = `${viewport.width}px`
    canvas.style.height = `${viewport.height}px`
    canvas.setAttribute("aria-hidden", "true")
    const text = document.createElement("div")
    text.className = "textLayer"
    element.style.setProperty("--scale-factor", String(scale))
    element.style.setProperty("--user-unit", "1")
    element.style.setProperty("--total-scale-factor", String(scale))
    element.style.width = `${viewport.width}px`
    element.style.height = `${viewport.height}px`
    // Annotation appearances are drawn as part of the page; no form fields,
    // links or scripts become interactive.
    const task = page.render({ canvas, viewport,
      transform: pixels === 1 ? null : [pixels, 0, 0, pixels, 0, 0], annotationMode: this.engine.AnnotationMode.ENABLE })
    const cancel = () => task.cancel()
    signal?.addEventListener("abort", cancel, { once: true })
    try {
      await task.promise
    } finally {
      signal?.removeEventListener("abort", cancel)
    }
    const layer = new this.engine.TextLayer({ textContentSource: page.streamTextContent(), container: text, viewport })
    element.replaceChildren(canvas, text)
    await layer.render().catch(() => {})
    return { width: viewport.width, height: viewport.height }
  }

  destroy() { this.document?.destroy?.() }
}

class ComicSource {
  constructor(pages) {
    this.pages = pages
    this.count = pages.count
  }

  static async open(asset, orderURL, signal) {
    const response = await fetch(orderURL, { credentials: "same-origin", redirect: "error", signal, headers: { Accept: "application/json" } })
    if (response.status === 410) throw new PageError("This comic changed or can't be read safely. Refresh the publication.", "changed")
    if (!response.ok) throw new PageError("This comic couldn't be opened. Check your connection or sign in again.", "network")
    const items = validateReadingOrder(await response.json(), asset)
    return new ComicSource(new ComicPages({ url: asset.content_url, asset, items }))
  }

  item(position) { return this.pages.items[position - 1] }

  async size(position) {
    const page = await this.pages.page(position - 1)
    return { width: page.width, height: page.height }
  }

  async render(position, element, scale, signal) {
    const page = await this.pages.page(position - 1, signal)
    const image = new Image()
    const url = URL.createObjectURL(page.blob)
    image.alt = `Page ${position} of ${this.count}`
    image.decoding = "async"
    image.draggable = false
    image.width = Math.round(page.width * scale)
    image.height = Math.round(page.height * scale)
    image.src = url
    try {
      await image.decode()
    } catch (_) {
      URL.revokeObjectURL(url)
      throw new PageError("This page image couldn't be shown.", "image")
    }
    element.style.width = `${image.width}px`
    element.style.height = `${image.height}px`
    element.replaceChildren(image)
    // The element holds the decoded image; the URL is no longer needed.
    URL.revokeObjectURL(url)
    return { width: image.width, height: image.height }
  }

  // Load the next page in the background so turning feels immediate.
  prefetch(position) { if (position >= 1 && position <= this.count) this.pages.page(position - 1).catch(() => {}) }

  destroy() { this.pages.cache.clear() }
}

// The paged reader -------------------------------------------------------------

// Locator for a page. PDF: document.pdf with page=N. CBZ: item N of the order.
export function pageLocator(format, position, count, item) {
  const totalProgression = count > 0 ? Math.min(1, Math.max(0, (position - 1) / count)) : 0
  if (format === "pdf") {
    return { href: "document.pdf", type: "application/pdf", locations: { position, totalProgression, fragments: [`page=${position}`] } }
  }
  return { href: item.href, type: item.media_type, locations: { position, totalProgression } }
}

// Where a saved place opens, without inventing one. Returns the display page
// and whether the saved place could be honoured exactly.
export function restoredPage(format, locator, count, items = []) {
  const position = locator?.locations?.position
  if (!locator || locator.locations?.cfi !== undefined) return { position: 1, exact: false }
  if (format === "cbz") {
    if (Number.isInteger(position) && items[position - 1]?.href === locator.href) return { position, exact: true }
    const index = items.findIndex(item => item.href === locator.href)
    if (index >= 0) return { position: index + 1, exact: false }
  } else if (Number.isInteger(position) && position >= 1 && position <= count) return { position, exact: true }
  if (Number.isInteger(position) && position >= 1) return { position: Math.min(position, count), exact: false }
  return { position: 1, exact: false }
}

export class PageReader {
  // element: the container; asset: the publication asset; onChange(position,
  // count, { activity }) reports every displayed page; onTap(zone) handles
  // taps ("previous", "next" or "middle"); onError(message).
  constructor({ element, asset, format, resources, orderURL, onChange, onTap, onError, label }) {
    this.element = element
    this.asset = asset
    this.format = format
    this.resources = resources
    this.orderURL = orderURL
    this.onChange = onChange
    this.onTap = onTap
    this.onError = onError
    this.label = label || "Page"
    this.zoom = 1
    this.position = 0
    this.displayedPosition = 0
    this.active = true
    this.abort = new AbortController()
    this.pointers = new Map()
  }

  get count() { return this.source?.count || 0 }
  get zoomed() { return this.zoom > 1.001 }

  async open(url) {
    this.element.replaceChildren()
    this.stage = document.createElement("div")
    this.stage.className = "consumer-pages__stage"
    this.page = document.createElement("div")
    this.page.className = `consumer-page consumer-page--${this.format}`
    this.page.setAttribute("role", "img")
    this.stage.append(this.page)
    this.element.append(this.stage)
    this.listen()
    this.source = this.format === "pdf" ? await PdfSource.open(url, this.resources, this.abort.signal)
      : await ComicSource.open({ ...this.asset, content_url: url }, this.orderURL, this.abort.signal)
    return this.count
  }

  items() { return this.source?.pages?.items || [] }

  locator(position) { return pageLocator(this.format, position, this.count, this.source.item?.(position)) }

  // Show a page. Only `activity: true` (the reader's own move) is reported as
  // reading activity, and only when the page actually changes.
  async show(position, { activity = false } = {}) {
    if (!this.source || !this.active) return
    const target = Math.max(1, Math.min(this.count, Math.round(position)))
    const changed = target !== this.position
    const moved = target !== this.displayedPosition
    this.position = target
    if (changed && !this.preserveZoom) this.zoom = 1
    const shown = await this.draw()
    if (!this.active || this.position !== target) return
    if (shown) this.displayedPosition = target
    this.onChange?.(target, this.count, { activity: activity && moved && shown === true, shown: shown === true })
    if (this.format === "cbz") this.source.prefetch(target + 1)
  }

  next() { if (this.position < this.count) return this.show(this.position + 1, { activity: true }) }
  previous() { if (this.position > 1) return this.show(this.position - 1, { activity: true }) }
  go(position) { return this.show(position, { activity: true }) }

  // Fit the whole page in the visible area, times the zoom.
  async draw() {
    const position = this.position
    this.drawing?.abort()
    const controller = new AbortController()
    this.drawing = controller
    const signal = controller.signal
    try {
      const { width, height } = await this.source.size(position)
      if (signal.aborted || !this.active) return
      // Fit within the stage's content box (inside its safe-area padding).
      const style = getComputedStyle(this.stage)
      const available = {
        width: this.stage.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight),
        height: this.stage.clientHeight - parseFloat(style.paddingTop) - parseFloat(style.paddingBottom)
      }
      const fit = Math.min(Math.max(1, available.width) / width, Math.max(1, available.height) / height)
      const scale = fit * this.zoom
      const holder = document.createElement("div")
      await this.source.render(position, holder, scale, signal)
      if (signal.aborted || !this.active) return
      this.page.style.width = holder.style.width
      this.page.style.height = holder.style.height
      for (const name of ["--scale-factor", "--user-unit", "--total-scale-factor"]) this.page.style.setProperty(name, holder.style.getPropertyValue(name))
      this.page.replaceChildren(...holder.childNodes)
      this.page.style.transform = ""
      this.page.setAttribute("aria-label", `${this.label} ${position} of ${this.count}`)
      this.element.classList.toggle("is-zoomed", this.zoomed)
      this.element.dataset.page = String(position)
      this.element.dataset.zoom = this.zoom.toFixed(2)
      return true
    } catch (error) {
      if (signal.aborted || !this.active || error?.name === "RenderingCancelledException" || error?.name === "AbortError") return false
      // Never leave the previous page on screen for this one.
      const message = error instanceof PageError ? error.message : "This page couldn't be shown."
      const notice = document.createElement("p")
      notice.className = "consumer-page__unavailable"
      notice.textContent = `Page ${position} couldn't be shown.`
      this.page.style.width = this.page.style.height = ""
      this.page.style.transform = ""
      this.page.replaceChildren(notice)
      this.page.setAttribute("aria-label", `${this.label} ${position} of ${this.count}: unavailable`)
      this.element.dataset.page = String(position)
      this.onError?.(message)
      return false
    }
  }

  setZoom(value, origin) {
    const zoom = Math.max(LIMITS.zoomMin, Math.min(LIMITS.zoomMax, Math.round(value * 100) / 100))
    if (Math.abs(zoom - this.zoom) < 0.01) return Promise.resolve()
    const stage = this.stage
    const point = origin || { x: stage.clientWidth / 2, y: stage.clientHeight / 2 }
    const ratio = zoom / this.zoom
    const left = (stage.scrollLeft + point.x) * ratio - point.x
    const top = (stage.scrollTop + point.y) * ratio - point.y
    this.zoom = zoom
    return this.draw().then(() => { stage.scrollLeft = Math.max(0, left); stage.scrollTop = Math.max(0, top) })
  }

  zoomIn() { return this.setZoom(this.zoom * 1.5) }
  zoomOut() { return this.setZoom(this.zoom / 1.5) }
  fit() { return this.setZoom(1) }

  // A window or orientation change refits the page; it is not activity.
  resized() {
    clearTimeout(this.resizeTimer)
    this.resizeTimer = setTimeout(() => { if (this.active && this.position) this.draw() }, 120)
  }

  listen() {
    this.observer = typeof ResizeObserver === "function" ? new ResizeObserver(() => this.resized()) : null
    this.observer?.observe(this.element)
    const stage = this.stage
    // Taps: sides turn pages, the middle shows controls; selecting text does neither.
    stage.addEventListener("click", event => {
      if (this.swiped || this.pinched) { this.swiped = this.pinched = false; return }
      const selection = globalThis.getSelection?.()
      if (selection && !selection.isCollapsed && String(selection).trim()) return
      const bounds = stage.getBoundingClientRect()
      const zone = (event.clientX - bounds.left) / Math.max(1, bounds.width)
      this.onTap?.(zone < 0.3 ? "previous" : zone > 0.7 ? "next" : "middle")
    })
    // Swipes turn pages at fit; zoomed pages pan instead. Two fingers pinch.
    stage.addEventListener("pointerdown", event => {
      this.pointers.set(event.pointerId, { x: event.clientX, y: event.clientY, startX: event.clientX, startY: event.clientY })
      if (this.pointers.size === 2) {
        const [a, b] = [...this.pointers.values()]
        this.pinch = { distance: Math.hypot(a.x - b.x, a.y - b.y), zoom: this.zoom, x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 }
      }
    })
    stage.addEventListener("pointermove", event => {
      const pointer = this.pointers.get(event.pointerId)
      if (!pointer) return
      pointer.x = event.clientX
      pointer.y = event.clientY
      if (this.pinch && this.pointers.size === 2) {
        const [a, b] = [...this.pointers.values()]
        const ratio = Math.hypot(a.x - b.x, a.y - b.y) / Math.max(1, this.pinch.distance)
        const zoom = Math.max(LIMITS.zoomMin, Math.min(LIMITS.zoomMax, this.pinch.zoom * ratio))
        this.page.style.transformOrigin = "center"
        this.page.style.transform = `scale(${zoom / this.zoom})`
        this.pinch.next = zoom
      }
    })
    const end = event => {
      const pointer = this.pointers.get(event.pointerId)
      this.pointers.delete(event.pointerId)
      if (this.pinch) {
        if (this.pointers.size === 0) {
          const { next, x, y } = this.pinch
          this.pinch = null
          this.pinched = true
          setTimeout(() => { this.pinched = false }, 400)
          const bounds = stage.getBoundingClientRect()
          if (next) this.setZoom(next, { x: x - bounds.left, y: y - bounds.top })
          else this.page.style.transform = ""
        }
        return
      }
      if (!pointer || event.type === "pointercancel" || this.zoomed) return
      const dx = event.clientX - pointer.startX, dy = event.clientY - pointer.startY
      if (Math.abs(dx) < 48 || Math.abs(dx) < Math.abs(dy) * 1.5 || String(globalThis.getSelection?.() || "").trim()) return
      this.swiped = true
      setTimeout(() => { this.swiped = false }, 400)
      this.onTap?.(dx < 0 ? "next" : "previous")
    }
    stage.addEventListener("pointerup", end)
    stage.addEventListener("pointercancel", end)
  }

  destroy() {
    this.active = false
    this.abort.abort()
    this.drawing?.abort()
    clearTimeout(this.resizeTimer)
    this.observer?.disconnect()
    this.source?.destroy?.()
    this.element.replaceChildren()
  }
}
