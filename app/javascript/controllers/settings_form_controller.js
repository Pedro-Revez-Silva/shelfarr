import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["form", "status"];

  connect() {
    this.saveTimeout = null;

    // Listen for Turbo events to manage status
    this.boundHandleSubmitEnd = this.handleSubmitEnd.bind(this);
    document.addEventListener("turbo:submit-end", this.boundHandleSubmitEnd);
  }

  disconnect() {
    document.removeEventListener("turbo:submit-end", this.boundHandleSubmitEnd);
  }

  autoSave(event) {
    // Clear any pending save
    if (this.saveTimeout) {
      clearTimeout(this.saveTimeout);
    }

    // Show saving indicator
    this.showStatus("Saving...");

    // Debounce the save - wait 800ms after last change
    this.saveTimeout = setTimeout(() => {
      this.submitForm();
    }, 800);
  }

  handleAuthDisabledToggle(event) {
    if (!event?.target?.checked) {
      this.autoSave(event);
      return;
    }

    const shouldDisableAuth = window.confirm(
      "You are enabling username-only authentication. This disables password and 2FA logins and may be insecure outside trusted networks. Continue?"
    );

    if (!shouldDisableAuth) {
      event.preventDefault();
      event.target.checked = false;
      return;
    }

    this.autoSave(event);
  }

  submitForm() {
    if (this.hasFormTarget) {
      this.formTarget.requestSubmit();
    }
  }

  handleSubmitEnd(event) {
    // Hide the saving indicator when form submission completes
    this.hideStatus();
  }

  showStatus(message) {
    if (this.hasStatusTarget) {
      this.statusTarget.textContent = message;
      this.statusTarget.classList.remove("hidden");
    }
  }

  hideStatus() {
    if (this.hasStatusTarget) {
      this.statusTarget.classList.add("hidden");
    }
  }
}
