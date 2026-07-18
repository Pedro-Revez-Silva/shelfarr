import { Controller } from "@hotwired/stimulus"

// Progressive enhancement for settings tabs.
// Panels render visible by default so the page remains usable if JS fails.
export default class extends Controller {
  static targets = ["tab", "panel"]
  static values = {
    active: { type: String, default: "search" }
  }

  initialize() {
    this.navigate = this.navigate.bind(this)
    this.handleHashChange = this.handleHashChange.bind(this)
    this.handleTurboRender = this.handleTurboRender.bind(this)
  }

  connect() {
    this.prepareAccessibility()

    const hash = window.location.hash.replace("#", "")
    const url = new URL(window.location.href)
    const queryTab = url.searchParams.get("tab")
    const requestedTab = hash || queryTab
    if (requestedTab && this.panelTargets.some((panel) => panel.dataset.tab === requestedTab)) {
      this.activeValue = requestedTab
    }

    // Fetch-based Turbo redirects discard URL fragments. Controllers include
    // a temporary query value so we can restore the selected tab, then return
    // the address bar to the same clean hash URLs used by direct navigation.
    if (queryTab && this.panelTargets.some((panel) => panel.dataset.tab === queryTab)) {
      url.searchParams.delete("tab")
      url.hash = requestedTab
      history.replaceState(null, "", url)
    }

    this.showTab()
    window.addEventListener("hashchange", this.handleHashChange)
    document.addEventListener("turbo:render", this.handleTurboRender)
  }

  disconnect() {
    this.tabTargets.forEach((tab) => tab.removeEventListener("keydown", this.navigate))
    window.removeEventListener("hashchange", this.handleHashChange)
    document.removeEventListener("turbo:render", this.handleTurboRender)
  }

  tabTargetConnected() {
    this.refreshAfterTargetChange()
  }

  panelTargetConnected() {
    this.refreshAfterTargetChange()
  }

  switch(event) {
    event.preventDefault()

    const tab = event.currentTarget.dataset.tab ||
      event.currentTarget.hash?.replace("#", "")
    if (!tab) return

    this.activeValue = tab
    this.showTab()
    history.replaceState(null, "", `#${tab}`)
  }

  navigate(event) {
    const keys = ["ArrowLeft", "ArrowRight", "Home", "End"]
    if (!keys.includes(event.key)) return

    event.preventDefault()
    const currentIndex = this.tabTargets.indexOf(event.currentTarget)
    if (currentIndex < 0) return

    let nextIndex
    if (event.key === "Home") {
      nextIndex = 0
    } else if (event.key === "End") {
      nextIndex = this.tabTargets.length - 1
    } else {
      const direction = event.key === "ArrowRight" ? 1 : -1
      nextIndex = (currentIndex + direction + this.tabTargets.length) % this.tabTargets.length
    }

    const nextTab = this.tabTargets[nextIndex]
    this.activeValue = nextTab.dataset.tab
    this.showTab()
    history.replaceState(null, "", `#${this.activeValue}`)
    nextTab.focus()
  }

  handleHashChange() {
    const hash = window.location.hash.replace("#", "")
    if (!hash || !this.panelTargets.some((panel) => panel.dataset.tab === hash)) return

    this.activeValue = hash
    this.showTab()
  }

  handleTurboRender() {
    this.refreshAfterTargetChange()
  }

  refreshAfterTargetChange() {
    if (this.refreshScheduled) return

    this.refreshScheduled = true
    queueMicrotask(() => {
      this.refreshScheduled = false
      if (!this.element.isConnected) return

      this.prepareAccessibility()
      const hash = window.location.hash.replace("#", "")
      if (hash && this.panelTargets.some((panel) => panel.dataset.tab === hash)) {
        this.activeValue = hash
      }
      this.showTab()
    })
  }

  showTab() {
    const active = this.activeValue

    this.tabTargets.forEach((tab) => {
      const isActive = tab.dataset.tab === active
      tab.classList.toggle("border-blue-500", isActive)
      tab.classList.toggle("text-blue-400", isActive)
      tab.classList.toggle("border-transparent", !isActive)
      tab.classList.toggle("text-gray-400", !isActive)
      tab.classList.toggle("hover:text-gray-300", !isActive)
      tab.classList.toggle("hover:border-gray-600", !isActive)
      tab.setAttribute("aria-selected", isActive ? "true" : "false")
      tab.setAttribute("tabindex", isActive ? "0" : "-1")
    })

    this.panelTargets.forEach((panel) => {
      const isActive = panel.dataset.tab === active
      panel.classList.toggle("hidden", !isActive)
      panel.setAttribute("aria-hidden", isActive ? "false" : "true")
    })
  }

  prepareAccessibility() {
    const namespace = this.element.id || `settings-tabs-${this.identifier}`

    this.tabTargets.forEach((tab, index) => {
      const key = tab.dataset.tab || index
      const panel = this.panelTargets.find((candidate) => candidate.dataset.tab === tab.dataset.tab)
      const tabId = `${namespace}-tab-${key}`
      const panelId = `${namespace}-panel-${key}`

      tab.id ||= tabId
      tab.setAttribute("aria-controls", panel?.id || panelId)
      tab.addEventListener("keydown", this.navigate)

      if (panel) {
        panel.id ||= panelId
        panel.setAttribute("aria-labelledby", tab.id)
      }
    })
  }
}
