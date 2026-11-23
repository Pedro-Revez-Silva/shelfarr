import { expect, test } from "bun:test"
import { readFile } from "node:fs/promises"

const moduleURL = text => `data:text/javascript;base64,${Buffer.from(text).toString("base64")}`

async function controllerWith({ classic, preview }) {
  const source = (await readFile(new URL("../../app/javascript/controllers/consumer_offline_signed_out_controller.js", import.meta.url), "utf8"))
    .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
    .replace('import("consumer_offline")', `import(${JSON.stringify(moduleURL(classic))})`)
    .replace('import("web_preview_offline_release")', `import(${JSON.stringify(moduleURL(preview))})`)
  const { default: SignedOut } = await import(moduleURL(source))
  return SignedOut
}

test("the sign-in page forgets both the web reader's and the preview reader's offline account for this deployment", async () => {
  globalThis.calls = []
  const SignedOut = await controllerWith({
    classic: "export const hasWorker = async base => (globalThis.calls.push(['hasWorker', base, Date.now()]), await new Promise(done => setTimeout(done, 20)), true); export const clearAccount = async base => globalThis.calls.push(['clearAccount', base])",
    preview: "export const releasePreviewAccount = async (base, askedAt) => globalThis.calls.push(['releasePreviewAccount', base, askedAt])"
  })
  const controller = new SignedOut()
  controller.baseValue = "/shelf"
  const before = Date.now()
  await controller.connect()
  const [[, , classicStarted], clear, [name, base, askedAt]] = globalThis.calls
  expect([clear, name, base]).toEqual([["clearAccount", "/shelf"], "releasePreviewAccount", "/shelf"])
  expect(askedAt).toBeGreaterThanOrEqual(before)
  expect(askedAt).toBeLessThanOrEqual(classicStarted)
})

test("a failure in the web reader's offline module still releases the preview account, and a preview failure stays quiet", async () => {
  globalThis.calls = []
  const SignedOut = await controllerWith({
    classic: "export const hasWorker = async () => { throw new Error('broken') }",
    preview: "export const releasePreviewAccount = async base => { globalThis.calls.push(['releasePreviewAccount', base]); throw new Error('blocked') }"
  })
  const controller = new SignedOut()
  controller.baseValue = ""
  await controller.connect()
  expect(globalThis.calls).toEqual([["releasePreviewAccount", ""]])
})
