import { expect, test } from "bun:test"
import { readFile } from "node:fs/promises"

// The production controller's page naming. Only Stimulus construction and the
// importmap alias are replaced; page geometry is given, as a browser would.
const progressURL = new URL("../../app/javascript/consumer_progress_sync.js", import.meta.url)
const source = (await readFile(new URL("../../app/javascript/controllers/consumer_reader_controller.js", import.meta.url), "utf8"))
  .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
  .replace('from "consumer_progress_sync"', `from ${JSON.stringify(progressURL.href)}`)
const { default: Reader } = await import(`data:text/javascript;base64,${Buffer.from(source + "\n//# sourceURL=consumer-reader-page-names-under-test.js\n").toString("base64")}`)

const rect = (left, width = 300) => ({ left, right: left + width, width, height: 500 })
const START = "epubcfi(/6/4!/4/1:0)"
globalThis.Node ||= { TEXT_NODE: 3, ELEMENT_NODE: 1 }

// What EPUB.js's getRange returns for the point CFI naming a page: a
// collapsed range with no text of its own, starting in a text node (or, when
// it found no text, in an element such as the body). The browser draws the
// node's first non-blank character after the point at `left`; blank text has
// no character to draw.
function point({ content, offset = 0, left, element = false }) {
  const node = element ? { nodeType: 1, textContent: content } : { nodeType: 3, textContent: content, ownerDocument: {
    createRange: () => {
      const measured = { setStart(_, at) { measured.at = at }, setEnd() {}, getClientRects: () => /\S/.test(content[measured.at] || "") ? [rect(left, 9)] : [] }
      return measured
    } } }
  return { collapsed: true, startContainer: node, startOffset: offset, toString: () => "", getBoundingClientRect: () => rect(left, 0) }
}

// The reader shows frame x 1000-1700 (a frame scrolled 1000px left of a
// 700px-wide reading area). `named` is EPUB.js's range for the page's name.
function reader({ named, pictures }) {
  const nodes = pictures.map(([name, left]) => ({ name, getBoundingClientRect: () => rect(left) }))
  const contents = { sectionIndex: 1, window: { frameElement: { getBoundingClientRect: () => ({ left: -1000 }) } },
    document: { querySelectorAll: () => nodes }, cfiFromNode: node => `epubcfi(/6/4!/4/${node.name})` }
  const subject = new Reader()
  Object.assign(subject, {
    viewportTarget: { getBoundingClientRect: () => ({ left: 0, right: 700 }) },
    rendition: { getContents: () => [contents], getRange: () => named }
  })
  return subject
}

const location = { start: { cfi: START, index: 1 } }
const PICTURE = "epubcfi(/6/4!/4/8/4)"

test("a page named by text drawn on it keeps that name, even with a picture beside the text", () => {
  expect(reader({ named: point({ content: "A beginning", left: 1100 }), pictures: [["8/4", 1433]] }).pageCfi(location)).toBe(START)
  // A point just before the word, in the same node, still names that word.
  expect(reader({ named: point({ content: "\n  Call me", left: 1040 }), pictures: [["8/4", 1030]] }).pageCfi(location)).toBe(START)
  expect(reader({ named: point({ content: "Call me", offset: 5, left: 1650 }), pictures: [["8/4", 1030]] }).pageCfi(location)).toBe(START)
})

test("a page of pictures is named by its first picture, not the section's start", () => {
  // EPUB.js found no text and named the body; the page shows picture 4.
  expect(reader({ named: point({ content: "\n  \n", element: true, left: 0 }), pictures: [["2/4", 30], ["8/4", 1030], ["10/4", 1766]] }).pageCfi(location)).toBe(PICTURE)
  // A point in the blank text between pictures.
  expect(reader({ named: point({ content: "\n", left: 0 }), pictures: [["8/4", 1030]] }).pageCfi(location)).toBe(PICTURE)
  // EPUB.js named text drawn on another page, before or after this one.
  expect(reader({ named: point({ content: "Later", left: 2200 }), pictures: [["8/4", 1030]] }).pageCfi(location)).toBe(PICTURE)
  expect(reader({ named: point({ content: "Earlier", left: 400 }), pictures: [["8/4", 1030]] }).pageCfi(location)).toBe(PICTURE)
  expect(reader({ named: null, pictures: [["8/4", 1030]] }).pageCfi(location)).toBe(PICTURE)
})

test("a page with neither text nor a picture keeps EPUB.js's name", () => {
  expect(reader({ named: point({ content: "\n", left: 0 }), pictures: [["2/4", 30]] }).pageCfi(location)).toBe(START)
  const unlaid = Object.assign(new Reader(), { rendition: { getContents: () => [] } })
  expect(unlaid.pageCfi(location)).toBe(START)
})
