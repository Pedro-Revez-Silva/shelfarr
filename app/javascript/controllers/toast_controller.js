import { Controller } from "@hotwired/stimulus"

// Toasts stay until dismissed so assistive-technology users are not on a timer.
export default class extends Controller {
  connect() {
    this.element.classList.add("translate-x-full", "opacity-0")

    requestAnimationFrame(() => {
      this.element.classList.remove("translate-x-full", "opacity-0")
      this.element.classList.add("translate-x-0", "opacity-100")
    })
  }

  dismiss() {
    this.element.classList.remove("translate-x-0", "opacity-100")
    this.element.classList.add("translate-x-full", "opacity-0")

    setTimeout(() => {
      this.element.remove()
    }, 300)
  }
}
