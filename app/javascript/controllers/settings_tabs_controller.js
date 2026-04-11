import { Controller } from "@hotwired/stimulus"

// Progressive enhancement for settings tabs.
// Panels render visible by default so the page remains usable if JS fails.
export default class extends Controller {
  static targets = ["tab", "panel"]
  static values = {
    active: { type: String, default: "search" }
  }

  connect() {
    const hash = window.location.hash.replace("#", "")
    if (hash && this.panelTargets.some((panel) => panel.dataset.tab === hash)) {
      this.activeValue = hash
    }

    this.showTab()
  }

  switch(event) {
    event.preventDefault()

    const tab = event.currentTarget.dataset.tab
    if (!tab) return

    this.activeValue = tab
    this.showTab()
    history.replaceState(null, "", `#${tab}`)
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
    })

    this.panelTargets.forEach((panel) => {
      const isActive = panel.dataset.tab === active
      panel.classList.toggle("hidden", !isActive)
      panel.setAttribute("aria-hidden", isActive ? "false" : "true")
    })
  }
}
