import { Controller } from "@hotwired/stimulus"

// Handles persistent toast notifications. Messages remain available until the
// user dismisses them or navigates, so assistive-technology users are not put
// on a timer while reading an authentication, sync, or backup result.
export default class extends Controller {
  connect() {
    this.element.classList.add("translate-x-full", "opacity-0")

    // Trigger enter animation
    requestAnimationFrame(() => {
      this.element.classList.remove("translate-x-full", "opacity-0")
      this.element.classList.add("translate-x-0", "opacity-100")
    })
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
