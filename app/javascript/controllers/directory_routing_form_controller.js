import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["mode", "layout", "layoutSection", "pathSection"];

  connect() {
    this.refresh();
  }

  refresh() {
    const modeSet = this.modeTarget.value !== "";
    this.toggleSection(this.layoutSectionTarget, modeSet);

    const pathNeeded = modeSet && this.layoutTarget.value !== "nested";
    this.toggleSection(this.pathSectionTarget, pathNeeded);
  }

  toggleSection(section, active) {
    section.classList.toggle("hidden", !active);
    section.querySelectorAll("select, input").forEach((field) => {
      field.disabled = !active;
    });
  }
}
