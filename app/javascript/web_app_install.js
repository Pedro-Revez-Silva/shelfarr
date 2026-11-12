const subscribers = new Set()
let offeredPrompt = null
let installedDuringVisit = false

function notify() {
  for (const subscriber of subscribers) subscriber()
}

window.addEventListener("beforeinstallprompt", event => {
  event.preventDefault()
  offeredPrompt = event
  notify()
})

window.addEventListener("appinstalled", () => {
  offeredPrompt = null
  installedDuringVisit = true
  notify()
})

export function runningAsInstalledApp() {
  return window.matchMedia("(display-mode: standalone)").matches || window.navigator.standalone === true
}

export function installOffered() {
  return offeredPrompt !== null
}

export function installedDuringThisVisit() {
  return installedDuringVisit
}

export async function askToInstall() {
  const prompt = offeredPrompt
  if (!prompt) return "unavailable"
  offeredPrompt = null
  notify()
  try {
    await prompt.prompt()
    return (await prompt.userChoice).outcome
  } catch {
    return "unavailable"
  }
}

export function subscribe(subscriber) {
  subscribers.add(subscriber)
  return () => subscribers.delete(subscriber)
}
