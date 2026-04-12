import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "item", "list"]

  connect() {
    this.draggedItem = null
    this.syncInput()
    this.refreshButtons()
  }

  dragStart(event) {
    this.draggedItem = event.currentTarget
    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData("text/plain", event.currentTarget.dataset.type)
    event.currentTarget.classList.add("opacity-60")
  }

  dragOver(event) {
    event.preventDefault()
    event.dataTransfer.dropEffect = "move"
  }

  drop(event) {
    event.preventDefault()

    const targetItem = event.currentTarget
    if (!this.draggedItem || this.draggedItem === targetItem) return

    const targetBounds = targetItem.getBoundingClientRect()
    const insertAfter = event.clientY > targetBounds.top + (targetBounds.height / 2)

    if (insertAfter) {
      targetItem.insertAdjacentElement("afterend", this.draggedItem)
    } else {
      targetItem.insertAdjacentElement("beforebegin", this.draggedItem)
    }

    this.persist()
  }

  dragEnd(event) {
    event.currentTarget.classList.remove("opacity-60")
    this.draggedItem = null
  }

  moveUp(event) {
    const item = event.currentTarget.closest("[data-download-type-preferences-target='item']")
    const previous = item?.previousElementSibling
    if (!item || !previous) return

    previous.insertAdjacentElement("beforebegin", item)
    this.persist()
  }

  moveDown(event) {
    const item = event.currentTarget.closest("[data-download-type-preferences-target='item']")
    const next = item?.nextElementSibling
    if (!item || !next) return

    next.insertAdjacentElement("afterend", item)
    this.persist()
  }

  persist() {
    this.syncInput(true)
    this.refreshButtons()
  }

  syncInput(notify = false) {
    const order = this.itemTargets.map((item) => item.dataset.type)
    this.inputTarget.value = JSON.stringify(order)

    if (notify) {
      this.inputTarget.dispatchEvent(new Event("change", { bubbles: true }))
    }
  }

  refreshButtons() {
    this.itemTargets.forEach((item, index) => {
      const buttons = item.querySelectorAll("[data-download-type-preferences-target$='Button']")
      const [moveUpButton, moveDownButton] = buttons

      if (moveUpButton) moveUpButton.disabled = index === 0
      if (moveDownButton) moveDownButton.disabled = index === this.itemTargets.length - 1
    })
  }
}
