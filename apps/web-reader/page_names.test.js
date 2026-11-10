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

// The reader shows frame x 1000-1700 (a frame scrolled 1000px left of a
// 700px-wide reading area). `text` is what EPUB.js named the page with.
function reader({ text, pictures }) {
  const nodes = pictures.map(([name, left]) => ({ name, getBoundingClientRect: () => rect(left) }))
  const contents = { sectionIndex: 1, window: { frameElement: { getBoundingClientRect: () => ({ left: -1000 }) } },
    document: { querySelectorAll: () => nodes }, cfiFromNode: node => `epubcfi(/6/4!/4/${node.name})` }
  const subject = new Reader()
  Object.assign(subject, {
    viewportTarget: { getBoundingClientRect: () => ({ left: 0, right: 700 }) },
    rendition: { getContents: () => [contents], getRange: () => text && { toString: () => text.words, getBoundingClientRect: () => rect(text.left, 40) } }
  })
  return subject
}

const location = { start: { cfi: START, index: 1 } }

test("a page EPUB.js names by text on it keeps that name", () => {
  expect(reader({ text: { words: "Call", left: 1100 }, pictures: [["2/4", 1050]] }).pageCfi(location)).toBe(START)
})

test("a page of pictures is named by its first picture, not the section's start", () => {
  // EPUB.js found no text and named the body; the page shows picture 4.
  expect(reader({ text: { words: "\n  ", left: 0 }, pictures: [["2/4", 30], ["8/4", 1030], ["10/4", 1766]] }).pageCfi(location)).toBe("epubcfi(/6/4!/4/8/4)")
  // EPUB.js named text from another page.
  expect(reader({ text: { words: "Later", left: 2200 }, pictures: [["8/4", 1030]] }).pageCfi(location)).toBe("epubcfi(/6/4!/4/8/4)")
  expect(reader({ text: null, pictures: [["8/4", 1030]] }).pageCfi(location)).toBe("epubcfi(/6/4!/4/8/4)")
})

test("a page with neither text nor a picture keeps EPUB.js's name", () => {
  expect(reader({ text: { words: "\n", left: 0 }, pictures: [["2/4", 30]] }).pageCfi(location)).toBe(START)
  const unlaid = Object.assign(new Reader(), { rendition: { getContents: () => [] } })
  expect(unlaid.pageCfi(location)).toBe(START)
})
