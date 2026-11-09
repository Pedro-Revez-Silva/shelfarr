import { Controller } from "@hotwired/stimulus"

// The sign-in page means this browser has no session. Forget the account
// offline pages would otherwise open downloads for. Its files stay hidden
// until that account opens the reader here again.
export default class extends Controller {
  static values = { base: String }

  async connect() {
    try {
      const offline = await import("consumer_offline")
      if (await offline.hasWorker(this.baseValue)) await offline.clearAccount(this.baseValue)
    } catch (_) { /* nothing was stored */ }
  }
}
