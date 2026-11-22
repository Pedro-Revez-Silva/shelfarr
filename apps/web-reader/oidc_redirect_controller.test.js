import { expect, test } from "bun:test"
import { readFile } from "node:fs/promises"

const moduleURL = text => `data:text/javascript;base64,${Buffer.from(text).toString("base64")}`

async function controllerWith(preview) {
  const source = (await readFile(new URL("../../app/javascript/controllers/oidc_redirect_controller.js", import.meta.url), "utf8"))
    .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
    .replace('import("web_preview_offline_release")', `import(${JSON.stringify(moduleURL(preview))})`)
  const { default: Redirect } = await import(moduleURL(source))
  const controller = new Redirect()
  controller.baseValue = "/shelf"
  controller.hasFormTarget = true
  controller.formTarget = { requestSubmit: () => globalThis.events.push("submit") }
  return controller
}

globalThis.requestAnimationFrame = callback => setTimeout(callback, 0)

test("single sign-on waits for the preview's offline account to be released before leaving the page", async () => {
  globalThis.events = []
  const controller = await controllerWith("export const releasePreviewAccount = async base => { await new Promise(done => setTimeout(done, 50)); globalThis.events.push(['released', base]) }")
  await controller.connect()
  await new Promise(done => setTimeout(done, 10))
  expect(globalThis.events).toEqual([["released", "/shelf"], "submit"])
})

test("a release that never finishes does not keep single sign-on from continuing", async () => {
  globalThis.events = []
  const controller = await controllerWith("export const releasePreviewAccount = () => new Promise(() => {})")
  const started = Date.now()
  await controller.connect()
  await new Promise(done => setTimeout(done, 10))
  expect(globalThis.events).toEqual(["submit"])
  expect(Date.now() - started).toBeGreaterThanOrEqual(1500)
})
