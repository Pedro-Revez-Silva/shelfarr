import { releasePreviewAccount } from "web_preview_offline_release"

const path = window.location.pathname
releasePreviewAccount(path.slice(0, path.indexOf("/preview"))).catch(() => false)
