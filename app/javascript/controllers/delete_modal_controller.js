import { Controller } from "@hotwired/stimulus"

// Handles delete confirmation modals with optional checkboxes
export default class extends Controller {
  static targets = ["modal", "checkbox"]
  static values = {
    title: String,
    message: String
  }

  open(event) {
    event.preventDefault()
    this.modalTarget.showModal()
  }

  close() {
    this.modalTarget.close()
  }

  confirm() {
    // Find the form within the modal and submit it
    const form = this.modalTarget.querySelector("form")
    if (form) {
      form.submit()
    }
  }

  // Handle clicking outside the modal to close it
  backdropClick(event) {
    if (event.target === this.modalTarget) {
      this.close()
    }
  }
}
