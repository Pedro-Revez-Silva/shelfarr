import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["menu", "button", "openIcon", "closeIcon"]

  toggle() {
    this.render(this.menuTarget.classList.contains("hidden"))
  }

  close() {
    this.render(false)
  }

  dismiss() {
    if (!this.hasMenuTarget || this.menuTarget.classList.contains("hidden")) return

    this.render(false)
    if (this.hasButtonTarget) this.buttonTarget.focus()
  }

  render(open) {
    this.menuTarget.classList.toggle("hidden", !open)
    this.openIconTarget.classList.toggle("hidden", open)
    this.closeIconTarget.classList.toggle("hidden", !open)
    if (this.hasButtonTarget) this.buttonTarget.setAttribute("aria-expanded", open ? "true" : "false")
  }
}
