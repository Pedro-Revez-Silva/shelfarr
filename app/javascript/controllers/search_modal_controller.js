import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.keydownHandler = this.keydown.bind(this)
    document.addEventListener("keydown", this.keydownHandler)
  }

  disconnect() {
    document.removeEventListener("keydown", this.keydownHandler)
  }

  close(event) {
    event?.preventDefault()
    const frame = this.element.closest("turbo-frame")

    if (frame) {
      frame.innerHTML = ""
    } else {
      this.element.remove()
    }
  }

  backdropClick(event) {
    if (event.target === this.element) {
      this.close(event)
    }
  }

  keydown(event) {
    if (event.key === "Escape") {
      this.close(event)
    }
  }
}
