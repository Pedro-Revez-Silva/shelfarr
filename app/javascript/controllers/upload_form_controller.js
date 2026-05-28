import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dropzone", "input", "folderInput", "filename", "mode", "submit"]
  static values = { bulk: Boolean }

  supportedExtensions = ["m4a", "m4b", "mp3", "zip", "rar", "epub", "pdf", "mobi", "azw3"]

  dragover(event) {
    event.preventDefault()
    this.dropzoneTarget.classList.add("border-blue-500", "bg-blue-50")
  }

  dragleave(event) {
    event.preventDefault()
    this.dropzoneTarget.classList.remove("border-blue-500", "bg-blue-50")
  }

  async drop(event) {
    event.preventDefault()
    this.dropzoneTarget.classList.remove("border-blue-500", "bg-blue-50")

    const entries = this.droppedEntries(event.dataTransfer)
    if (entries.some((entry) => entry.isDirectory)) {
      await this.folderDropped(entries)
      return
    }

    const files = event.dataTransfer.files
    if (files.length > 0) {
      if (!this.bulkValue && files.length > 1) {
        this.showFilename("Please choose one file for this request")
        return
      }

      this.setMode("files")
      this.clearFolderInput()
      this.inputTarget.files = files
      this.showSelection(files)
    }
  }

  async folderDropped(entries) {
    if (!this.bulkValue) {
      this.showFilename("Please choose one file for this request")
      return
    }

    if (!window.DataTransfer) {
      this.showFilename("Folder drag and drop is not supported by this browser")
      return
    }

    this.showFilename("Scanning folder...")

    const files = await this.filesFromEntries(entries)
    const supportedFiles = files.filter((file) => this.supportedFile(file))

    this.setMode("folder")
    this.clearFileInput()

    if (supportedFiles.length === 0) {
      this.clearFolderInput()
      this.showFilename("No supported book files found in folder")
      return
    }

    this.keepSupportedFolderFiles(supportedFiles)
    this.showFolderSelection(supportedFiles)
  }

  fileSelected(event) {
    const files = event.target.files
    if (files.length > 0) {
      this.setMode("files")
      this.clearFolderInput()
      this.showSelection(files)
    }
  }

  folderSelected(event) {
    const files = event.target.files
    const supportedFiles = Array.from(files).filter((file) => this.supportedFile(file))

    this.setMode("folder")
    this.clearFileInput()

    if (supportedFiles.length === 0) {
      event.target.value = ""
      this.showFilename("No supported book files found in folder")
      return
    }

    this.keepSupportedFolderFiles(supportedFiles)
    this.showFolderSelection(supportedFiles)
  }

  showFolderSelection(files) {
    const fileLabel = files.length === 1 ? "file" : "files"
    this.showFilename(`${files.length} supported ${fileLabel} selected from folder`)
  }

  showSelection(files) {
    if (files.length === 1) {
      this.showFilename(files[0].name)
      return
    }

    this.showFilename(`${files.length} files selected`)
  }

  showFilename(name) {
    this.filenameTarget.classList.remove("hidden")
    this.filenameTarget.querySelector("span").textContent = name
  }

  supportedFile(file) {
    const extension = file.name.split(".").pop()?.toLowerCase()
    return this.supportedExtensions.includes(extension)
  }

  keepSupportedFolderFiles(files) {
    if (!window.DataTransfer) return

    const transfer = new DataTransfer()
    files.forEach((file) => transfer.items.add(file))
    this.folderInputTarget.files = transfer.files
  }

  droppedEntries(dataTransfer) {
    return Array.from(dataTransfer.items || [])
      .map((item) => item.webkitGetAsEntry?.())
      .filter(Boolean)
  }

  async filesFromEntries(entries) {
    const nestedFiles = await Promise.all(entries.map((entry) => this.filesFromEntry(entry)))
    return nestedFiles.reduce((files, entryFiles) => files.concat(entryFiles), [])
  }

  async filesFromEntry(entry) {
    if (entry.isFile) {
      return new Promise((resolve) => {
        entry.file((file) => resolve([file]), () => resolve([]))
      })
    }

    if (entry.isDirectory) {
      const entries = await this.readDirectoryEntries(entry)
      return this.filesFromEntries(entries)
    }

    return []
  }

  async readDirectoryEntries(directoryEntry) {
    const reader = directoryEntry.createReader()
    const entries = []

    while (true) {
      const batch = await new Promise((resolve) => {
        reader.readEntries(resolve, () => resolve([]))
      })

      if (batch.length === 0) return entries

      entries.push(...batch)
    }
  }

  setMode(mode) {
    if (this.hasModeTarget) this.modeTarget.value = mode
  }

  clearFileInput() {
    this.inputTarget.value = ""
  }

  clearFolderInput() {
    if (this.hasFolderInputTarget) this.folderInputTarget.value = ""
  }
}
