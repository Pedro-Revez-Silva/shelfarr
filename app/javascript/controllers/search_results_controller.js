import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["content", "result", "pagination", "pageInfo", "prevBtn", "nextBtn", "toggleBtn"]
  static values = {
    expanded: { type: Boolean, default: false },
    page: { type: Number, default: 1 },
    perPage: { type: Number, default: 5 }
  }

  connect() {
    // Respect initial expanded state (e.g. show page starts expanded)
    if (this.hasContentTarget) {
      this.contentTarget.classList.toggle("hidden", !this.expandedValue)
    }
    this.updateVisibility()
  }

  toggle() {
    this.expandedValue = !this.expandedValue
    this.contentTarget.classList.toggle("hidden", !this.expandedValue)
    
    if (this.hasToggleBtnTarget) {
      const count = this.resultTargets.length
      this.toggleBtnTarget.textContent = this.expandedValue 
        ? `Hide Results (${count})`
        : `View Results (${count})`
    }
  }

  nextPage() {
    const totalPages = this.totalPages()
    if (this.pageValue < totalPages) {
      this.pageValue++
      this.updateVisibility()
    }
  }

  prevPage() {
    if (this.pageValue > 1) {
      this.pageValue--
      this.updateVisibility()
    }
  }

  updateVisibility() {
    const results = this.resultTargets
    const total = results.length
    const perPage = this.perPageValue
    const currentPage = this.pageValue
    const totalPages = this.totalPages()

    results.forEach((result, index) => {
      const pageStart = (currentPage - 1) * perPage
      const pageEnd = pageStart + perPage
      const isVisible = index >= pageStart && index < pageEnd
      result.classList.toggle("hidden", !isVisible)
    })

    if (this.hasPageInfoTarget) {
      this.pageInfoTarget.textContent = `Page ${currentPage} of ${totalPages}`
    }

    if (this.hasPrevBtnTarget) {
      this.prevBtnTarget.disabled = currentPage <= 1
      this.prevBtnTarget.classList.toggle("opacity-50", currentPage <= 1)
    }
    if (this.hasNextBtnTarget) {
      this.nextBtnTarget.disabled = currentPage >= totalPages
      this.nextBtnTarget.classList.toggle("opacity-50", currentPage >= totalPages)
    }

    if (this.hasPaginationTarget) {
      this.paginationTarget.classList.toggle("hidden", totalPages <= 1)
    }
  }

  totalPages() {
    return Math.ceil(this.resultTargets.length / this.perPageValue)
  }
}
