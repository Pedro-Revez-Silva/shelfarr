import { expect, test } from "bun:test"
import { readFile } from "node:fs/promises"

// The production controller's key handling. Only Stimulus construction and
// the importmap alias are replaced; the DOM is a minimal stand-in.
const progressURL = new URL("../../app/javascript/consumer_progress_sync.js", import.meta.url)
const source = (await readFile(new URL("../../app/javascript/controllers/consumer_reader_controller.js", import.meta.url), "utf8"))
  .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
  .replace('from "consumer_progress_sync"', `from ${JSON.stringify(progressURL.href)}`)
const { default: Reader } = await import(`data:text/javascript;base64,${Buffer.from(source + "\n//# sourceURL=consumer-reader-keys-under-test.js\n").toString("base64")}`)

function node(tag, { editable = false, inside = [] } = {}) {
  return { tagName: tag, isContentEditable: editable, closest: selector => selector.split(",").map(part => part.trim()).some(part => [tag, ...inside].includes(part)) ? {} : null }
}

function key(target, key, modifiers = {}) {
  return { target, key, altKey: false, ctrlKey: false, metaKey: false, isComposing: false, defaultPrevented: false, ...modifiers,
    preventDefault() { this.defaultPrevented = true } }
}

function withReader(check) {
  const original = globalThis.document
  const body = node("body"), html = node("html"), inside = node("div"), outside = node("div")
  globalThis.document = { body, documentElement: html }
  const reader = new Reader(), moves = []
  Object.assign(reader, { hasControlsTarget: true, controlsTarget: { hidden: true }, element: { contains: target => target === inside },
    nextPage: () => moves.push("next"), previousPage: () => moves.push("previous"), showControls: () => moves.push("controls"), hideControls: () => moves.push("hide") })
  try { check({ reader, moves, body, html, inside, outside }) } finally { globalThis.document = original }
}

test("page keys reach the reader while the page body has focus, as on a freshly opened page", () => withReader(({ reader, moves, body, html, inside }) => {
  for (const name of ["ArrowRight", "PageDown"]) {
    const event = key(body, name)
    reader.documentKey(event)
    expect(event.defaultPrevented).toBe(true)
  }
  reader.documentKey(key(html, "ArrowLeft"))
  reader.documentKey(key(inside, "PageUp"))
  expect(moves).toEqual(["next", "next", "previous", "previous"])
}))

test("keys aimed at the rest of the page are not reading keys", () => withReader(({ reader, moves, outside }) => {
  const event = key(outside, "ArrowRight")
  reader.documentKey(event)
  expect(moves).toEqual([])
  expect(event.defaultPrevented).toBe(false)
}))

test("browser and system shortcuts, composition and already handled keys are left alone", () => withReader(({ reader, moves, body }) => {
  const events = [key(body, "ArrowLeft", { altKey: true }), key(body, "ArrowRight", { ctrlKey: true }), key(body, "PageDown", { metaKey: true }),
    key(body, "Escape", { ctrlKey: true }), key(body, "ArrowRight", { isComposing: true }), key(body, "ArrowRight", { defaultPrevented: true })]
  for (const event of events) reader.documentKey(event)
  expect(moves).toEqual([])
  expect(events.slice(0, 5).every(event => !event.defaultPrevented)).toBe(true)
  // Shift is part of typing "+" and is not a shortcut by itself.
  reader.documentKey(key(body, "ArrowRight", { shiftKey: true }))
  expect(moves).toEqual(["next"])
}))

test("menus, fields and editable text keep their own keys; Escape still closes the controls", () => withReader(({ reader, moves }) => {
  for (const target of [node("select"), node("input"), node("textarea"), node("span", { editable: true })]) {
    reader.readerKey(key(target, "ArrowRight"))
    reader.readerKey(key(target, "PageUp"))
  }
  expect(moves).toEqual([])
  reader.readerKey(key(node("select"), "Escape"))
  expect(moves).toEqual(["controls"])
}))
