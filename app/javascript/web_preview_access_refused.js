import { releasePreviewAccount } from "web_preview_offline_release"

const base = document.querySelector('meta[name="shelfarr-base"]')?.content ?? ""
releasePreviewAccount(base, Math.floor(performance.timeOrigin)).catch(() => false)
