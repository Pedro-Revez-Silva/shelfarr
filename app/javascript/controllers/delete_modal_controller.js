import { Controller } from "@hotwired/stimulus"

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
    const form = this.modalTarget.querySelector("form")
    if (form) {
      form.submit()
    }
  }

  backdropClick(event) {
    if (event.target === this.modalTarget) {
      this.close()
    }
  }
}
