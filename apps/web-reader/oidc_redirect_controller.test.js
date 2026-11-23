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
  const listeners = []
  controller.hasFormTarget = true
  controller.formTarget = {
    addEventListener: (type, listener) => listeners.push(listener),
    removeEventListener: () => {},
    requestSubmit: () => globalThis.events.push("submit"),
    pressContinue: () => {
      const event = { prevented: false, preventDefault() { this.prevented = true } }
      for (const listener of listeners) listener(event)
      globalThis.events.push(event.prevented ? "held" : "continued")
    }
  }
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

test("pressing Continue before the release finishes is held until the page submits itself", async () => {
  globalThis.events = []
  const controller = await controllerWith("export const releasePreviewAccount = async base => { await new Promise(done => setTimeout(done, 50)); globalThis.events.push(['released', base]) }")
  const connecting = controller.connect()
  controller.formTarget.pressContinue()
  await connecting
  await new Promise(done => setTimeout(done, 10))
  controller.formTarget.pressContinue()
  expect(globalThis.events).toEqual(["held", ["released", "/shelf"], "submit", "continued"])
})
