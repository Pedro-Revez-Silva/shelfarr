import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = [
    "form",
    "status",
    "indexerProvider",
    "prowlarrFields",
    "jackettFields",
    "zlibraryUrlField",
    "zlibraryUrlInput",
    "zlibraryUrlList",
    "zlibraryUrlError"
  ];

  connect() {
    this.saveTimeout = null;

    // Listen for Turbo events to manage status
    this.boundHandleSubmitEnd = this.handleSubmitEnd.bind(this);
    document.addEventListener("turbo:submit-end", this.boundHandleSubmitEnd);

    this.toggleIndexerProvider();
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

  handleIndexerProviderChange(event) {
    this.toggleIndexerProvider();
    this.autoSave(event);
  }

  addZlibraryUrl(event) {
    event.preventDefault();

    if (!this.hasZlibraryUrlInputTarget || !this.hasZlibraryUrlFieldTarget) return;

    const result = this.normalizeZlibraryUrl(this.zlibraryUrlInputTarget.value);
    if (!result.valid) {
      this.showZlibraryUrlError(result.error);
      return;
    }

    const urls = this.zlibraryUrls();
    if (urls.includes(result.value)) {
      this.showZlibraryUrlError("This URL is already in the list.");
      return;
    }

    urls.push(result.value);
    this.setZlibraryUrls(urls);
    this.zlibraryUrlInputTarget.value = "";
    this.hideZlibraryUrlError();
  }

  removeZlibraryUrl(event) {
    event.preventDefault();

    if (!this.hasZlibraryUrlFieldTarget) return;

    const url = event.currentTarget.dataset.zlibraryUrl;
    const urls = this.zlibraryUrls().filter((existingUrl) => existingUrl !== url);

    this.setZlibraryUrls(urls);
    this.hideZlibraryUrlError();
  }

  handleZlibraryUrlKeydown(event) {
    if (event.key !== "Enter") return;

    this.addZlibraryUrl(event);
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

  toggleIndexerProvider() {
    if (!this.hasIndexerProviderTarget) return;

    const provider = this.indexerProviderTarget.value;

    if (this.hasProwlarrFieldsTarget) {
      this.prowlarrFieldsTarget.classList.toggle("hidden", provider !== "prowlarr");
    }

    if (this.hasJackettFieldsTarget) {
      this.jackettFieldsTarget.classList.toggle("hidden", provider !== "jackett");
    }
  }

  zlibraryUrls() {
    return this.zlibraryUrlFieldTarget.value
      .split(/\s+/)
      .map((url) => url.trim())
      .filter((url) => url.length > 0);
  }

  setZlibraryUrls(urls) {
    const uniqueUrls = [...new Set(urls)];

    this.zlibraryUrlFieldTarget.value = uniqueUrls.join("\n");
    this.zlibraryUrlFieldTarget.dispatchEvent(new Event("change", { bubbles: true }));
    this.renderZlibraryUrlPills(uniqueUrls);
  }

  renderZlibraryUrlPills(urls) {
    if (!this.hasZlibraryUrlListTarget) return;

    this.zlibraryUrlListTarget.replaceChildren(...urls.map((url) => this.buildZlibraryUrlPill(url)));
  }

  buildZlibraryUrlPill(url) {
    const pill = document.createElement("span");
    pill.className = "inline-flex items-center gap-2 rounded-full border border-gray-700 bg-gray-800 px-3 py-1 text-sm text-gray-200";
    pill.dataset.zlibraryUrl = url;

    const label = document.createElement("span");
    label.className = "break-all";
    label.textContent = url;

    const button = document.createElement("button");
    button.type = "button";
    button.className = "rounded-full p-1 text-gray-400 transition hover:bg-gray-700 hover:text-white";
    button.dataset.action = "click->settings-form#removeZlibraryUrl";
    button.dataset.zlibraryUrl = url;
    button.setAttribute("aria-label", `Remove ${url}`);

    const icon = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    icon.setAttribute("class", "h-3 w-3");
    icon.setAttribute("fill", "none");
    icon.setAttribute("stroke", "currentColor");
    icon.setAttribute("viewBox", "0 0 24 24");

    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    path.setAttribute("stroke-linecap", "round");
    path.setAttribute("stroke-linejoin", "round");
    path.setAttribute("stroke-width", "2");
    path.setAttribute("d", "M6 18L18 6M6 6l12 12");

    icon.appendChild(path);
    button.appendChild(icon);
    pill.append(label, button);

    return pill;
  }

  normalizeZlibraryUrl(value) {
    const rawValue = value.trim();
    if (rawValue.length === 0) {
      return { valid: false, error: "Enter a URL before adding it." };
    }

    const candidate = /^[a-z][a-z0-9+.-]*:\/\//i.test(rawValue) ? rawValue : `https://${rawValue}`;

    try {
      const url = new URL(candidate);
      if (!["http:", "https:"].includes(url.protocol) || url.hostname.length === 0) {
        return { valid: false, error: "Use an http or https URL." };
      }

      if ((url.pathname && url.pathname !== "/") || url.search || url.hash || url.username || url.password) {
        return { valid: false, error: "Use only the site origin, without paths, query strings, or credentials." };
      }

      return { valid: true, value: url.origin };
    } catch (_error) {
      return { valid: false, error: "Enter a valid URL." };
    }
  }

  showZlibraryUrlError(message) {
    if (!this.hasZlibraryUrlErrorTarget) return;

    this.zlibraryUrlErrorTarget.textContent = message;
    this.zlibraryUrlErrorTarget.classList.remove("hidden");
  }

  hideZlibraryUrlError() {
    if (!this.hasZlibraryUrlErrorTarget) return;

    this.zlibraryUrlErrorTarget.textContent = "";
    this.zlibraryUrlErrorTarget.classList.add("hidden");
  }
}
