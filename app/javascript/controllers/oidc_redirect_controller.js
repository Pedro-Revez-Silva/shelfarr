import { Controller } from "@hotwired/stimulus"

const RELEASE_LIMIT_MS = 1500

export default class extends Controller {
  static targets = ["form"]
  static values = { base: String }

  async connect() {
    this.submitted = false
    const signedOutAt = Date.now()
    const released = import("web_preview_offline_release")
      .then(preview => preview.releasePreviewAccount(this.baseValue, signedOutAt))
      .catch(() => false)
    await Promise.race([released, new Promise(done => setTimeout(done, RELEASE_LIMIT_MS))])

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
