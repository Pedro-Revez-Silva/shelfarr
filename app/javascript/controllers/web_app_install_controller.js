import { Controller } from "@hotwired/stimulus"
import { askToInstall, installOffered, installedDuringThisVisit, runningAsInstalledApp, subscribe } from "web_app_install"

const OUTCOME_MESSAGES = {
  accepted: "Your browser is adding Shelfarr to this device.",
  dismissed: "Shelfarr wasn't installed. You can add it later from here or from your browser's menu.",
  installed: "Shelfarr is installed. Open it from your home screen or app list.",
  unavailable: "Your browser didn't open its install window. Use the steps below instead."
}

export default class extends Controller {
  static targets = ["offer", "status", "guide", "installed", "insecure"]

  connect() {
    this.outcome = installedDuringThisVisit() ? "installed" : null
    this.unsubscribe = subscribe(() => {
      if (installedDuringThisVisit()) this.outcome = "installed"
      this.render()
    })
    this.render()
  }

  disconnect() {
    this.unsubscribe()
  }

  async install() {
    const outcome = await askToInstall()
    if (this.outcome !== "installed") this.outcome = outcome
    this.render()
  }

  render() {
    const standalone = runningAsInstalledApp()
    const installed = this.outcome === "installed"
    this.installedTarget.hidden = !standalone
    this.guideTarget.hidden = standalone || installed
    this.offerTarget.hidden = standalone || installed || !installOffered()
    this.insecureTarget.hidden = standalone || installed || window.isSecureContext
    this.statusTarget.textContent = standalone ? "" : OUTCOME_MESSAGES[this.outcome] || ""
  }
}
