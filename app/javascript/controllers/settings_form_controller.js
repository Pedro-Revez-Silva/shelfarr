import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = [
    "form",
    "status",
    "autosaveSubmit",
    "autosaveKeys",
    "manualKeys",
    "indexerProvider",
    "prowlarrFields",
    "jackettFields",
    "newznabFields"
  ];

  connect() {
    this.saveTimeout = null;
    this.pendingSettingKeys = new Set();
    this.inFlightSettingKeys = new Set();
    this.explicitInFlightSettingKeys = new Set();
    this.autosaveInFlight = false;
    this.explicitSubmitInFlight = false;
    this.manualChangesPending = false;
    this.manualSettingKeys = new Set();
    this.deferredAction = null;
    this.historyIndex = window.history.state?.turbo?.restorationIndex;
    this.revertingHistory = false;
    this.replayingHistory = false;
    if (this.hasManualKeysTarget) this.manualKeysTarget.name = "manual_keys";

    // Listen for Turbo events to manage status
    this.boundHandleSubmitEnd = this.handleSubmitEnd.bind(this);
    this.boundHandleBeforeVisit = this.handleBeforeVisit.bind(this);
    this.boundHandleBeforeRender = this.handleBeforeRender.bind(this);
    this.boundHandleActionClick = this.handleActionClick.bind(this);
    this.boundHandleExternalSubmit = this.handleExternalSubmit.bind(this);
    this.boundHandleManualChange = this.handleManualChange.bind(this);
    this.boundHandleManualInput = this.handleManualInput.bind(this);
    this.boundHandleBeforeUnload = this.handleBeforeUnload.bind(this);
    this.boundHandlePopState = this.handlePopState.bind(this);
    document.addEventListener("turbo:submit-end", this.boundHandleSubmitEnd);
    document.addEventListener("turbo:before-visit", this.boundHandleBeforeVisit);
    document.addEventListener("turbo:before-render", this.boundHandleBeforeRender);
    this.element.addEventListener("click", this.boundHandleActionClick, true);
    this.element.addEventListener("submit", this.boundHandleExternalSubmit, true);
    this.element.addEventListener("change", this.boundHandleManualChange, true);
    this.element.addEventListener("beforeinput", this.boundHandleManualInput, true);
    window.addEventListener("beforeunload", this.boundHandleBeforeUnload);
    window.settingsNavigationGuard = this.boundHandlePopState;

    this.toggleIndexerProvider();
  }

  disconnect() {
    this.clearSaveTimeout();
    document.removeEventListener("turbo:submit-end", this.boundHandleSubmitEnd);
    document.removeEventListener("turbo:before-visit", this.boundHandleBeforeVisit);
    document.removeEventListener("turbo:before-render", this.boundHandleBeforeRender);
    this.element.removeEventListener("click", this.boundHandleActionClick, true);
    this.element.removeEventListener("submit", this.boundHandleExternalSubmit, true);
    this.element.removeEventListener("change", this.boundHandleManualChange, true);
    this.element.removeEventListener("beforeinput", this.boundHandleManualInput, true);
    window.removeEventListener("beforeunload", this.boundHandleBeforeUnload);
    if (window.settingsNavigationGuard === this.boundHandlePopState) delete window.settingsNavigationGuard;
  }

  autoSave(event) {
    const settingKey = this.settingKey(event?.target?.name);
    if (!settingKey) return;

    this.pendingSettingKeys.add(settingKey);

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

  addUrl(event) {
    event.preventDefault();

    const container = this.urlListContainer(event);
    if (!container) return;

    const input = this.urlListInput(container);
    const result = this.normalizeUrl(input.value);
    if (!result.valid) {
      this.showUrlListError(container, result.error);
      return;
    }

    const urls = this.urlListUrls(container);
    if (urls.includes(result.value)) {
      this.showUrlListError(container, "This URL is already in the list.");
      return;
    }

    urls.push(result.value);
    this.setUrlListUrls(container, urls);
    input.value = "";
    this.hideUrlListError(container);
  }

  removeUrl(event) {
    event.preventDefault();

    const container = this.urlListContainer(event);
    if (!container) return;

    const url = event.currentTarget.dataset.urlListValue;
    const urls = this.urlListUrls(container).filter((existingUrl) => existingUrl !== url);

    this.setUrlListUrls(container, urls);
    this.hideUrlListError(container);
  }

  handleUrlKeydown(event) {
    if (event.key !== "Enter") return;

    this.addUrl(event);
  }

  submitForm() {
    if (!this.hasFormTarget || !this.hasAutosaveSubmitTarget || !this.hasAutosaveKeysTarget) return;
    if (this.autosaveInFlight || this.explicitSubmitInFlight || this.pendingSettingKeys.size === 0) return;

    // Server-side validation is authoritative for bulk auto-save. Full-form
    // HTML5 constraint validation would block unrelated settings when an
    // indexer URL is mid-edit or on a hidden tab (where the browser bubble is
    // easy to miss). The form uses novalidate; type="url" remains a soft hint.
    this.inFlightSettingKeys = new Set(this.pendingSettingKeys);
    this.autosaveKeysTarget.value = [...this.inFlightSettingKeys].join(",");
    this.pendingSettingKeys.clear();
    this.saveTimeout = null;
    this.autosaveInFlight = true;
    this.formTarget.requestSubmit(this.autosaveSubmitTarget);
    this.setFormBusy(true);
  }

  handleSubmit(event) {
    if (event.submitter === this.autosaveSubmitTarget) return;

    const saveAll = event.submitter?.name === "commit";
    if (!saveAll && this.manualChangesPending) {
      event.preventDefault();
      this.showUnsavedManualChanges();
      return;
    }

    if (this.autosaveInFlight || this.explicitSubmitInFlight || (!saveAll && this.pendingSettingKeys.size > 0)) {
      event.preventDefault();
      this.deferAction({ type: "submitter", submitter: event.submitter });
      if (!this.autosaveInFlight && !this.explicitSubmitInFlight) {
        this.clearSaveTimeout();
        this.saveTimeout = setTimeout(() => this.submitForm(), 0);
      }
      return;
    }

    this.clearSaveTimeout();
    if (saveAll && this.hasManualKeysTarget) {
      const submittedKeys = new Set(
        [...new FormData(this.formTarget).keys()].map((name) => this.settingKey(name)).filter(Boolean)
      );
      this.manualKeysTarget.value = [...this.manualSettingKeys].filter((key) => submittedKeys.has(key)).join(",");
    }
    this.explicitInFlightSettingKeys = saveAll ? new Set(this.pendingSettingKeys) : new Set();
    if (saveAll) {
      this.pendingSettingKeys.clear();
    }
    this.explicitSubmitInFlight = true;
    this.showStatus("Saving...");
    this.setFormBusy(true);
  }

  handleSubmitEnd(event) {
    if (!event.target.matches("[data-settings-form-target~='form']")) return;

    const submitter = event.detail?.formSubmission?.submitter;
    const succeeded = event.detail?.success === true;
    if (submitter === this.autosaveSubmitTarget) {
      this.autosaveInFlight = false;
      if (!succeeded) {
        this.inFlightSettingKeys.forEach((key) => this.pendingSettingKeys.add(key));
      }
      this.inFlightSettingKeys.clear();

      if (!succeeded && this.deferredAction?.type === "submitter" && this.deferredAction.submitter?.name === "commit") {
        this.setFormBusy(false);
        this.runDeferredAction();
        return;
      }
      if (this.pendingSettingKeys.size > 0) {
        if (!succeeded) {
          this.discardDeferredActionAfterFailure();
          this.setFormBusy(false);
          this.showStatus("Autosave failed. Change the setting to retry.");
          return;
        }
        this.setFormBusy(false);
        this.submitForm();
        return;
      }
      if (succeeded && this.runDeferredAction()) return;
    } else {
      this.explicitSubmitInFlight = false;
      if (!succeeded) {
        this.explicitInFlightSettingKeys.forEach((key) => this.pendingSettingKeys.add(key));
      }
      this.explicitInFlightSettingKeys.clear();
      this.setFormBusy(false);

      if (!succeeded) {
        this.discardDeferredActionAfterFailure();
        this.showStatus("Save failed. Review the errors and try again.");
        return;
      }
      if (submitter?.name === "commit") {
        this.discardManualChanges();
        this.clearSecretFields();
      }
      if (this.pendingSettingKeys.size > 0) {
        this.submitForm();
        return;
      }
      if (this.runDeferredAction()) return;
    }

    this.setFormBusy(false);
    this.finishStatus();
  }

  handleActionClick(event) {
    const link = event.target.closest("a[data-turbo-method]");
    if (!link) return;

    if (this.manualChangesPending && !this.explicitSubmitInFlight) {
      event.preventDefault();
      event.stopImmediatePropagation();
      this.showUnsavedManualChanges();
      return;
    }
    if (!this.hasSaveWork()) return;

    event.preventDefault();
    event.stopImmediatePropagation();
    this.deferAction({ type: "link", link });
    this.ensureAutosaveScheduled();
  }

  handleExternalSubmit(event) {
    if (event.target === this.formTarget) return;

    if (this.manualChangesPending && !this.explicitSubmitInFlight) {
      event.preventDefault();
      event.stopImmediatePropagation();
      this.showUnsavedManualChanges();
      return;
    }
    if (!this.hasSaveWork()) return;

    event.preventDefault();
    event.stopImmediatePropagation();
    this.deferAction({ type: "form", form: event.target, submitter: event.submitter });
    this.ensureAutosaveScheduled();
  }

  handleBeforeVisit(event) {
    if (this.manualChangesPending && !this.explicitSubmitInFlight) {
      const discardChanges = window.confirm("Leave this page and discard settings that have not been saved?");
      if (!discardChanges) {
        event.preventDefault();
        return;
      }
      this.discardManualChanges();
    }
    if (!this.hasSaveWork()) return;

    event.preventDefault();
    if (!this.deferAction({ type: "visit", url: event.detail.url })) return;
    this.ensureAutosaveScheduled();
  }

  handleBeforeRender(event) {
    if (!this.hasSaveWork()) return;

    event.preventDefault();
    if (!this.deferAction({ type: "render", resume: event.detail.resume })) return;
    this.ensureAutosaveScheduled();
  }

  handleManualChange(event) {
    if (!event.target.matches("[data-settings-form-manual-save]")) return;
    if (!event.target.matches('select, input[type="checkbox"], input[type="radio"], input[type="hidden"]')) return;

    this.markManualField(event.target);
  }

  handleManualInput(event) {
    if (!event.target.matches("[data-settings-form-manual-save]") || event.target !== document.activeElement) return;

    this.markManualField(event.target);
  }

  handleBeforeUnload(event) {
    if (!this.manualChangesPending) return;

    event.preventDefault();
    event.returnValue = "";
  }

  handlePopState(event) {
    const targetIndex = event.state?.turbo?.restorationIndex;
    if (targetIndex == null || this.historyIndex == null) return;

    if (this.replayingHistory) {
      this.replayingHistory = false;
      event.stopImmediatePropagation();
      window.location.reload();
      return;
    }

    if (this.revertingHistory) {
      this.revertingHistory = false;
      event.stopImmediatePropagation();
      if (this.pendingHistoryVisit) {
        const visit = this.pendingHistoryVisit;
        this.pendingHistoryVisit = null;
        if (this.autosaveInFlight || this.explicitSubmitInFlight) {
          this.deferAction({ type: "history", visit });
        } else {
          this.submitHistoryAutosave(visit);
        }
      }
      return;
    }

    const activeElement = document.activeElement;
    if (activeElement && this.formTarget.contains(activeElement) && activeElement.dataset.action?.includes("settings-form#autoSave")) {
      this.autoSave({ target: activeElement });
    }

    if (this.manualChangesPending) {
      if (window.confirm("Leave this page and discard settings that have not been saved?")) {
        this.discardManualChanges();
      } else {
        event.stopImmediatePropagation();
        this.reverseHistoryNavigation(targetIndex);
        return;
      }
    }

    if (!this.hasSaveWork()) return;

    event.stopImmediatePropagation();
    this.pendingHistoryVisit = { url: window.location.href, targetIndex };
    this.reverseHistoryNavigation(targetIndex);
  }

  reverseHistoryNavigation(targetIndex) {
    const delta = this.historyIndex - targetIndex;
    if (delta !== 0) {
      this.revertingHistory = true;
      window.history.go(delta);
    }
  }

  async submitHistoryAutosave(visit) {
    this.clearSaveTimeout();
    if (this.pendingSettingKeys.size === 0) {
      this.resumeHistoryNavigation(visit);
      return;
    }

    this.inFlightSettingKeys = new Set(this.pendingSettingKeys);
    this.autosaveKeysTarget.value = [...this.inFlightSettingKeys].join(",");
    this.pendingSettingKeys.clear();
    this.autosaveInFlight = true;
    this.setFormBusy(true);

    try {
      const response = await window.fetch(this.formTarget.action, {
        method: this.formTarget.method,
        body: new FormData(this.formTarget, this.autosaveSubmitTarget),
        credentials: "same-origin",
        headers: { Accept: "text/vnd.turbo-stream.html" }
      });
      const body = await response.text();
      if (body) window.Turbo.renderStreamMessage(body);

      if (!response.ok) {
        this.inFlightSettingKeys.forEach((key) => this.pendingSettingKeys.add(key));
        this.showStatus("Autosave failed. Change the setting to retry.");
        return;
      }

      this.hideStatus();
      this.resumeHistoryNavigation(visit);
    } catch (_error) {
      this.inFlightSettingKeys.forEach((key) => this.pendingSettingKeys.add(key));
      this.showStatus("Autosave failed. Change the setting to retry.");
    } finally {
      this.inFlightSettingKeys.clear();
      this.autosaveInFlight = false;
      this.setFormBusy(false);
    }
  }

  resumeHistoryNavigation(visit) {
    const delta = visit.targetIndex - this.historyIndex;
    if (delta === 0) {
      window.location.assign(visit.url);
      return;
    }

    this.replayingHistory = true;
    window.history.go(delta);
  }

  hasSaveWork() {
    return this.autosaveInFlight || this.explicitSubmitInFlight || this.pendingSettingKeys.size > 0;
  }

  ensureAutosaveScheduled() {
    if (this.autosaveInFlight || this.explicitSubmitInFlight || this.pendingSettingKeys.size === 0) return;

    this.clearSaveTimeout();
    this.submitForm();
  }

  runDeferredAction() {
    const action = this.deferredAction;
    this.deferredAction = null;
    if (!action) return false;

    this.setFormBusy(false);
    this.hideStatus();

    if (action.type === "submitter" && action.submitter?.isConnected) {
      this.formTarget.requestSubmit(action.submitter);
    } else if (action.type === "link" && action.link.isConnected) {
      action.link.click();
    } else if (action.type === "form" && action.form.isConnected) {
      action.form.requestSubmit(action.submitter?.isConnected ? action.submitter : undefined);
    } else if (action.type === "visit") {
      if (window.Turbo?.visit) {
        window.Turbo.visit(action.url);
      } else {
        window.location.assign(action.url);
      }
    } else if (action.type === "history") {
      this.resumeHistoryNavigation(action.visit);
    } else if (action.type === "render") {
      action.resume();
    }
    return true;
  }

  deferAction(action) {
    if (this.deferredAction?.type === "render" && action.type !== "render") return false;

    this.deferredAction = action;
    return true;
  }

  discardDeferredActionAfterFailure() {
    if (this.deferredAction?.type !== "render") this.deferredAction = null;
  }

  showUnsavedManualChanges() {
    this.showStatus("Save all changes before running this action.");
  }

  markManualField(field) {
    const key = this.settingKey(field.name);
    if (!key) return;

    this.manualSettingKeys.add(key);
    this.manualChangesPending = true;
    if (this.hasManualKeysTarget) this.manualKeysTarget.value = [...this.manualSettingKeys].join(",");
    this.showStatus("Unsaved changes. Click Save All.");
  }

  discardManualChanges() {
    this.manualSettingKeys.clear();
    this.manualChangesPending = false;
    if (this.hasManualKeysTarget) this.manualKeysTarget.value = "";
  }

  finishStatus() {
    if (this.manualChangesPending) {
      this.showStatus("Unsaved changes. Click Save All.");
    } else {
      this.hideStatus();
    }
  }

  clearSecretFields() {
    this.formTarget.querySelectorAll('input[type="password"]').forEach((field) => {
      field.value = "";
    });
  }

  setFormBusy(busy) {
    if (!this.hasFormTarget) return;

    if (busy) {
      const activeElement = document.activeElement;
      if (activeElement && this.formTarget.contains(activeElement)) {
        this.focusedControl = {
          id: activeElement.id,
          selectionStart: activeElement.selectionStart,
          selectionEnd: activeElement.selectionEnd
        };
      }
    }

    this.element.querySelectorAll("form").forEach((form) => { form.inert = busy; });
    this.formTarget.setAttribute("aria-busy", busy ? "true" : "false");

    if (!busy && this.focusedControl?.id) {
      const control = document.getElementById(this.focusedControl.id);
      if (control) {
        control.focus({ preventScroll: true });
        if (this.focusedControl.selectionStart != null && control.setSelectionRange) {
          control.setSelectionRange(this.focusedControl.selectionStart, this.focusedControl.selectionEnd);
        }
      }
      this.focusedControl = null;
    }
  }

  clearSaveTimeout() {
    if (!this.saveTimeout) return;

    clearTimeout(this.saveTimeout);
    this.saveTimeout = null;
  }

  settingKey(name) {
    return name?.match(/^settings\[([^\]]+)\](?:\[\])?$/)?.[1];
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
      this.toggleProviderFields(this.prowlarrFieldsTarget, provider === "prowlarr");
    }

    if (this.hasJackettFieldsTarget) {
      this.toggleProviderFields(this.jackettFieldsTarget, provider === "jackett");
    }

    if (this.hasNewznabFieldsTarget) {
      this.toggleProviderFields(this.newznabFieldsTarget, provider === "newznab");
    }
  }

  toggleProviderFields(container, active) {
    container.classList.toggle("hidden", !active);
    container.querySelectorAll('input[type="url"]').forEach((input) => {
      input.disabled = !active;
    });
  }

  urlListContainer(event) {
    return event.currentTarget.closest("[data-url-list]");
  }

  urlListField(container) {
    return container.querySelector("[data-url-list-field]");
  }

  urlListInput(container) {
    return container.querySelector("[data-url-list-input]");
  }

  urlListList(container) {
    return container.querySelector("[data-url-list-list]");
  }

  urlListError(container) {
    return container.querySelector("[data-url-list-error]");
  }

  urlListUrls(container) {
    return this.urlListField(container).value
      .split(/\s+/)
      .map((url) => url.trim())
      .filter((url) => url.length > 0);
  }

  setUrlListUrls(container, urls) {
    const uniqueUrls = [...new Set(urls)];
    const field = this.urlListField(container);

    field.value = uniqueUrls.join("\n");
    field.dispatchEvent(new Event("change", { bubbles: true }));
    this.renderUrlListPills(container, uniqueUrls);
  }

  renderUrlListPills(container, urls) {
    const list = this.urlListList(container);
    if (!list) return;

    list.replaceChildren(...urls.map((url) => this.buildUrlListPill(url)));
  }

  buildUrlListPill(url) {
    const pill = document.createElement("span");
    pill.className = "inline-flex items-center gap-2 rounded-full border border-gray-700 bg-gray-800 px-3 py-1 text-sm text-gray-200";
    pill.dataset.urlListValue = url;

    const label = document.createElement("span");
    label.className = "break-all";
    label.textContent = url;

    const button = document.createElement("button");
    button.type = "button";
    button.className = "rounded-full p-1 text-gray-400 transition hover:bg-gray-700 hover:text-white";
    button.dataset.action = "click->settings-form#removeUrl";
    button.dataset.urlListValue = url;
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

  normalizeUrl(value) {
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

  showUrlListError(container, message) {
    const error = this.urlListError(container);
    if (!error) return;

    error.textContent = message;
    error.classList.remove("hidden");
  }

  hideUrlListError(container) {
    const error = this.urlListError(container);
    if (!error) return;

    error.textContent = "";
    error.classList.add("hidden");
  }
}
