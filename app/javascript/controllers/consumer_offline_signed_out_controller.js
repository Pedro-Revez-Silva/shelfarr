import { Controller } from "@hotwired/stimulus"

// The sign-in page means this browser has no session. Forget the account
// offline pages would otherwise open downloads for. Its files stay hidden
// until that account opens the reader here again.
export default class extends Controller {
  static values = { base: String }

  async connect() {
    const signedOutAt = Date.now()
    try {
      const offline = await import("consumer_offline")
      if (await offline.hasWorker(this.baseValue)) await offline.clearAccount(this.baseValue)
    } catch (_) { /* nothing was stored */ }
    await import("web_preview_offline_release").then(preview => preview.releasePreviewAccount(this.baseValue, signedOutAt)).catch(() => false)
  }
}
