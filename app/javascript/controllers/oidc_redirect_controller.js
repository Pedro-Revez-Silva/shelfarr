import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["form"]

  connect() {
    this.submitted = false

    requestAnimationFrame(() => {
      this.submit()
    })
  }

  submit() {
    if (!this.hasFormTarget || this.submitted) return

    this.submitted = true
    this.formTarget.requestSubmit()
  }
}
