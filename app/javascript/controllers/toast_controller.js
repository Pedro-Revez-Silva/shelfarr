import { Controller } from "@hotwired/stimulus"

// Handles toast notifications that auto-dismiss
export default class extends Controller {
  static values = {
    duration: { type: Number, default: 5000 }
  }

  connect() {
    // Start auto-dismiss timer
    this.timeout = setTimeout(() => {
      this.dismiss()
    }, this.durationValue)

    // Trigger enter animation
    requestAnimationFrame(() => {
      this.element.classList.remove("translate-x-full", "opacity-0")
      this.element.classList.add("translate-x-0", "opacity-100")
    })
  }

  disconnect() {
    if (this.timeout) {
      clearTimeout(this.timeout)
    }
  }

  dismiss() {
    // Trigger exit animation
    this.element.classList.remove("translate-x-0", "opacity-100")
    this.element.classList.add("translate-x-full", "opacity-0")

    // Remove element after animation
    setTimeout(() => {
      this.element.remove()
    }, 300)
  }
}
