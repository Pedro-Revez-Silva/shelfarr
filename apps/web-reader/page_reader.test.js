import { expect, test } from "bun:test"
import { deflateRawSync, crc32 as zlibCrc32 } from "node:zlib"
import { ComicPages, LIMITS, PageError, checkImage, crc32, entryNameBytes, imageInfo, inflateRaw, localDataStart, pageLocator,
  resourceFactory, restoredPage, validateReadingOrder } from "../../app/javascript/consumer_page_reader.js"
import { assetUrls, snapshot } from "../../app/javascript/consumer_offline.js"

const encoder = new TextEncoder()

function png(width, height) {
  const bytes = new Uint8Array(33)
  bytes.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52])
  const view = new DataView(bytes.buffer)
  view.setUint32(16, width)
  view.setUint32(20, height)
  return bytes
}

// A minimal ZIP (local records only matter here) and its reading order.
function comic(pages, { tamper } = {}) {
  const parts = []
  const items = []
  let offset = 0
  pages.forEach((data, index) => {
    const name = encoder.encode(`pages/${String(index + 1).padStart(3, "0")} é.png`)
    const compressed = new Uint8Array(deflateRawSync(data))
    const header = new Uint8Array(30)
    const view = new DataView(header.buffer)
    view.setUint32(0, 0x04034b50, true)
    view.setUint16(4, 20, true)
    view.setUint16(6, 0x0800, true)
    view.setUint16(8, 8, true)
    view.setUint32(14, zlibCrc32(data), true)
    view.setUint32(18, compressed.length, true)
    view.setUint32(22, data.length, true)
    view.setUint16(26, name.length, true)
    view.setUint16(28, 0, true)
    items.push({ position: index + 1, href: [...name].map(byte => /[A-Za-z0-9\-._~/]/.test(String.fromCharCode(byte)) ? String.fromCharCode(byte) : `%${byte.toString(16).toUpperCase().padStart(2, "0")}`).join(""),
      media_type: "image/png", size_bytes: data.length, compressed_size: compressed.length, compression_method: 8,
      local_header_offset: offset, crc32: zlibCrc32(data).toString(16).padStart(8, "0") })
    parts.push(header, name, compressed)
    offset += 30 + name.length + compressed.length
  })
  const bytes = new Uint8Array(offset)
  let cursor = 0
  for (const part of parts) { bytes.set(part, cursor); cursor += part.length }
  tamper?.(bytes, items)
  const asset = { id: "a".repeat(64), size_bytes: bytes.length, page_count: items.length, content_url: "/read/1/assets/" + "a".repeat(64) }
  return { bytes, items, asset }
}

// Serves single byte ranges like the server and the offline worker.
function rangeServer(bytes, { etag = `"${"a".repeat(64)}"`, status } = {}) {
  const calls = []
  const fetcher = async (url, options) => {
    calls.push(options.headers.Range)
    if (status) return new Response("", { status })
    const [, start, end] = /^bytes=(\d+)-(\d+)$/.exec(options.headers.Range)
    const first = Number(start), last = Math.min(Number(end), bytes.length - 1)
    return new Response(bytes.slice(first, last + 1), { status: 206, headers: { ETag: etag, "Content-Range": `bytes ${first}-${last}/${bytes.length}` } })
  }
  return { fetcher, calls }
}

test("CRC-32 matches zlib", () => {
  const data = encoder.encode("The quick brown fox jumps over the lazy dog")
  expect(crc32(data)).toBe(zlibCrc32(data).toString(16).padStart(8, "0"))
  expect(crc32(new Uint8Array())).toBe("00000000")
})

test("reading orders are checked against the asset before any page is read", () => {
  const { items, asset } = comic([png(10, 10), png(10, 10)])
  const order = { asset_id: asset.id, format: "cbz", items }
  expect(validateReadingOrder(order, asset)).toHaveLength(2)
  const broken = [
    { ...order, asset_id: "b".repeat(64) }, { ...order, format: "pdf" }, { ...order, items: [] },
    { ...order, items: [items[1], items[0]] }, { ...order, items: [{ ...items[0], compression_method: 12 }, items[1]] },
    { ...order, items: [{ ...items[0], media_type: "image/svg+xml" }, items[1]] },
    { ...order, items: [{ ...items[0], size_bytes: LIMITS.pageBytes + 1 }, items[1]] },
    { ...order, items: [{ ...items[0], local_header_offset: asset.size_bytes }, items[1]] },
    { ...order, items: [{ ...items[0], crc32: "XYZ" }, items[1]] }
  ]
  for (const value of broken) expect(() => validateReadingOrder(value, asset)).toThrow(PageError)
  expect(() => validateReadingOrder(order, { ...asset, page_count: 3 })).toThrow(PageError)
})

test("hrefs decode to the exact ZIP entry bytes", () => {
  expect([...entryNameBytes("a%20b/%C3%A9.png")]).toEqual([...encoder.encode("a b/é.png")])
  expect(() => entryNameBytes("bad%zz")).toThrow(PageError)
  expect(() => entryNameBytes("space here")).toThrow(PageError)
})

test("a page is range-read, inflated within its size and verified", async () => {
  const pages = [png(120, 160), png(80, 60), png(30, 40)]
  const { bytes, items, asset } = comic(pages)
  const { fetcher, calls } = rangeServer(bytes)
  const reader = new ComicPages({ url: asset.content_url, asset, items, fetch: fetcher })
  expect([...(await reader.bytes(1))]).toEqual([...pages[1]])
  const page = await reader.page(2)
  expect(page.width).toBe(30)
  expect(page.height).toBe(40)
  expect(page.blob.type).toBe("image/png")
  expect(calls.every(range => /^bytes=\d+-\d+$/.test(range))).toBe(true)
  // Never more than one page's worth of the archive per request.
  for (const range of calls) {
    const [, start, end] = /^bytes=(\d+)-(\d+)$/.exec(range).map(Number)
    expect(end - start).toBeLessThan(30 + 64 + LIMITS.localHeaderSlack + 200)
  }
})

test("tampered pages, headers, ranges and editions are refused", async () => {
  const pages = [png(10, 10), png(10, 10)]
  const crc = comic(pages, { tamper: (bytes, items) => { items[0].crc32 = "00000000" } })
  await expect(new ComicPages({ ...crc, url: "x", fetch: rangeServer(crc.bytes).fetcher }).bytes(0)).rejects.toThrow(/checksum/)
  const renamed = comic(pages, { tamper: bytes => { bytes[30] = "q".charCodeAt(0) } })
  await expect(new ComicPages({ ...renamed, url: "x", fetch: rangeServer(renamed.bytes).fetcher }).bytes(0)).rejects.toThrow(/header/)
  const method = comic(pages, { tamper: bytes => { bytes[8] = 0 } })
  await expect(new ComicPages({ ...method, url: "x", fetch: rangeServer(method.bytes).fetcher }).bytes(0)).rejects.toThrow(/header/)
  const larger = comic(pages, { tamper: (bytes, items) => { items[0].size_bytes -= 1 } })
  await expect(new ComicPages({ ...larger, url: "x", fetch: rangeServer(larger.bytes).fetcher }).bytes(0)).rejects.toThrow(PageError)
  const good = comic(pages)
  await expect(new ComicPages({ ...good, url: "x", fetch: rangeServer(good.bytes, { etag: '"other"' }).fetcher }).bytes(0)).rejects.toThrow(/changed/)
  await expect(new ComicPages({ ...good, url: "x", fetch: rangeServer(good.bytes, { status: 410 }).fetcher }).bytes(0)).rejects.toThrow(/changed/)
  await expect(new ComicPages({ ...good, url: "x", fetch: rangeServer(good.bytes, { status: 200 }).fetcher }).bytes(0)).rejects.toThrow(PageError)
  const wrongRange = async () => new Response(good.bytes.slice(0, 10), { status: 206, headers: { "Content-Range": `bytes 0-9/${good.bytes.length}` } })
  await expect(new ComicPages({ ...good, url: "x", fetch: wrongRange }).bytes(1)).rejects.toThrow(/incomplete/)
})

test("inflation stops at the announced size", async () => {
  const data = new Uint8Array(4096).fill(7)
  const compressed = new Uint8Array(deflateRawSync(data))
  expect((await inflateRaw(compressed, 4096)).length).toBe(4096)
  await expect(inflateRaw(compressed, 1024)).rejects.toThrow(PageError)
  await expect(inflateRaw(compressed, 8192)).rejects.toThrow(PageError)
  await expect(inflateRaw(new Uint8Array([1, 2, 3, 4]), 10)).rejects.toThrow(PageError)
})

test("image headers are read and dimensions bounded before decoding", () => {
  expect(imageInfo(png(300, 400))).toEqual({ type: "image/png", width: 300, height: 400 })
  const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 4, 0, 0, 0xff, 0xc0, 0, 11, 8, 0x01, 0x90, 0x01, 0x2c, 3, 0, 0, 0])
  expect(imageInfo(jpeg)).toEqual({ type: "image/jpeg", width: 300, height: 400 })
  const webp = new Uint8Array(30)
  webp.set(encoder.encode("RIFF"), 0); webp.set(encoder.encode("WEBPVP8X"), 8)
  webp.set([0x2b, 0x01, 0x00, 0x8f, 0x01, 0x00], 24)
  expect(imageInfo(webp)).toEqual({ type: "image/webp", width: 300, height: 400 })
  expect(() => checkImage(png(LIMITS.imageSide + 1, 10))).toThrow(/too large/)
  expect(() => checkImage(png(10_000, 10_000))).toThrow(/too large/)
  expect(() => checkImage(png(0, 10))).toThrow(PageError)
  expect(() => checkImage(encoder.encode("<svg xmlns='http://www.w3.org/2000/svg'/>"))).toThrow(/JPEG, PNG or WebP/)
})

test("page locators follow the shared contract", () => {
  expect(pageLocator("pdf", 3, 10)).toEqual({ href: "document.pdf", type: "application/pdf", locations: { position: 3, totalProgression: 0.2, fragments: ["page=3"] } })
  const item = { href: "pages/002.png", media_type: "image/png" }
  expect(pageLocator("cbz", 2, 4, item)).toEqual({ href: "pages/002.png", type: "image/png", locations: { position: 2, totalProgression: 0.25 } })
})

test("restoring never invents a place and never applies a text position to pages", () => {
  const items = [{ href: "a.png" }, { href: "b.png" }, { href: "c.png" }]
  expect(restoredPage("pdf", { locations: { position: 4 } }, 10)).toEqual({ position: 4, exact: true })
  expect(restoredPage("pdf", { locations: { position: 40 } }, 10)).toEqual({ position: 10, exact: false })
  expect(restoredPage("pdf", { locations: { cfi: "epubcfi(/6/2)", position: 4 } }, 10)).toEqual({ position: 1, exact: false })
  expect(restoredPage("pdf", null, 10)).toEqual({ position: 1, exact: false })
  expect(restoredPage("cbz", { href: "b.png", locations: { position: 2 } }, 3, items)).toEqual({ position: 2, exact: true })
  expect(restoredPage("cbz", { href: "c.png", locations: { position: 2 } }, 3, items)).toEqual({ position: 3, exact: false })
  expect(restoredPage("cbz", { href: "z.png", locations: { position: 9 } }, 3, items)).toEqual({ position: 3, exact: false })
})

test("PDF resources resolve only to listed same-origin assets", async () => {
  globalThis.location ||= { href: "https://reader.example/shelf/read/1", origin: "https://reader.example" }
  const requested = []
  const fetcher = async url => { requested.push(url); return new Response(new Uint8Array([1, 2, 3])) }
  const Factory = resourceFactory({ files: { cMapUrl: { "UniJIS-UCS2-H.bcmap": "/shelf/assets/pdfjs/cmaps/UniJIS-UCS2-H-abc.bcmap" },
    standardFontDataUrl: { "LiberationSans-Regular.ttf": "https://elsewhere.example/font.ttf" } } }, fetcher)
  const factory = new Factory()
  expect([...(await factory.fetch({ kind: "cMapUrl", filename: "UniJIS-UCS2-H.bcmap" }))]).toEqual([1, 2, 3])
  expect(requested).toEqual(["https://reader.example/shelf/assets/pdfjs/cmaps/UniJIS-UCS2-H-abc.bcmap"])
  await expect(factory.fetch({ kind: "cMapUrl", filename: "../../secret" })).rejects.toThrow()
  await expect(factory.fetch({ kind: "standardFontDataUrl", filename: "LiberationSans-Regular.ttf" })).rejects.toThrow(/same-origin/)
})

test("a comic download needs its bytes and its reading order", () => {
  globalThis.location ||= { href: "https://reader.example/shelf/read/1", origin: "https://reader.example" }
  const saved = snapshot({ id: 1, book_type: "ebook", content_kind: "graphic", assets: [
    { id: "a".repeat(64), format: "cbz", content_url: "/shelf/read/1/assets/aaa", reading_order_url: "/shelf/read/1/assets/aaa/reading_order", page_count: 12, size_bytes: 9 },
    { id: "b".repeat(64), format: "pdf", content_url: "/shelf/read/1/assets/bbb", size_bytes: 9 }] })
  expect(saved.content_kind).toBe("graphic")
  expect(saved.assets[0].page_count).toBe(12)
  expect(assetUrls(saved.assets[0])).toEqual([`${location.origin}/shelf/read/1/assets/aaa`, `${location.origin}/shelf/read/1/assets/aaa/reading_order`])
  expect(assetUrls(saved.assets[1])).toEqual([`${location.origin}/shelf/read/1/assets/bbb`])
  expect("reading_order_url" in saved.assets[1]).toBe(false)
})
