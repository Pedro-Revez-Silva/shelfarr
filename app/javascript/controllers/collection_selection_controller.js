import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["wholeSeries", "member", "format", "submit", "validation"]

  connect() {
    this.update()
  }

  update() {
    const wholeSeries = this.wholeSeriesTarget.checked
    this.memberTargets.forEach((member) => { member.disabled = wholeSeries })

    const hasFormat = this.formatTargets.some((format) => format.checked)
    const hasBooks = wholeSeries || this.memberTargets.some((member) => member.checked)
    this.submitTarget.disabled = !hasFormat || !hasBooks
    this.validationTarget.textContent = !hasFormat
      ? "Select ebooks, audiobooks, or both."
      : !hasBooks ? "Select at least one book." : ""
  }
}
