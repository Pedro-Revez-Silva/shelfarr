import { Controller } from "@hotwired/stimulus"

// Toggles the mobile navigation menu and its open/close icons
export default class extends Controller {
  static targets = ["menu", "openIcon", "closeIcon"]

  toggle() {
    const isHidden = this.menuTarget.classList.toggle("hidden")
    this.openIconTarget.classList.toggle("hidden", !isHidden)
    this.closeIconTarget.classList.toggle("hidden", isHidden)
  }

  close() {
    this.menuTarget.classList.add("hidden")
    this.openIconTarget.classList.remove("hidden")
    this.closeIconTarget.classList.add("hidden")
  }
}
