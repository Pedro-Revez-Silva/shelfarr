const BOOK_IMAGE_TAGS = new Set(["img", "image"])
const BOOK_IMAGE_ATTRS = new Set(["src", "href", "xlink:href"])
const SECTION_POLICY = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline' blob:; img-src data: blob:; font-src data: blob:; connect-src 'none'; form-action 'none'; base-uri 'self'"
const FORBIDDEN_TAGS = ["script", "iframe", "frame", "form", "input", "button", "object", "embed", "base", "meta", "audio", "video", "source"]
const FORBIDDEN_ATTRS = ["srcset", "action", "formaction"]
const UNSAFE_HREF = /^(?:https?:|javascript:|file:|data:|\/\/)/i

export function ownBookImages(book, origin) {
  return new Set((book.resources?.replacementUrls || []).filter(url => typeof url === "string" && url.startsWith(`blob:${origin}/`)))
}

export function sanitizeSection(DOMPurify, html, { images, base }) {
  const ownImage = (node, data) => {
    if (BOOK_IMAGE_TAGS.has(node.nodeName.toLowerCase()) && BOOK_IMAGE_ATTRS.has(data.attrName) && images.has(data.attrValue)) data.forceKeepAttr = true
  }
  DOMPurify.addHook("uponSanitizeAttribute", ownImage)
  let clean
  try {
    clean = DOMPurify.sanitize(html, { WHOLE_DOCUMENT: true, SANITIZE_NAMED_PROPS: true, FORBID_TAGS: FORBIDDEN_TAGS, FORBID_ATTR: FORBIDDEN_ATTRS })
  } finally { DOMPurify.removeHook("uponSanitizeAttribute", ownImage) }
  const document = new DOMParser().parseFromString(clean, "text/html")
  for (const link of document.querySelectorAll("[href]")) {
    if (UNSAFE_HREF.test(link.getAttribute("href") || "")) link.removeAttribute("href")
  }
  const policy = document.createElement("meta")
  policy.httpEquiv = "Content-Security-Policy"
  policy.content = SECTION_POLICY
  const anchor = document.createElement("base")
  anchor.href = base
  document.head.prepend(anchor)
  document.head.prepend(policy)
  return document.documentElement.outerHTML
}

export function sectionBase(book, href, origin) {
  const resolved = book.resolve(href)
  if (/^[a-z][a-z0-9+.-]*:/i.test(resolved)) {
    const url = new URL(resolved)
    if (url.origin === origin) return url.href
  }
  return new URL(`/${resolved.replace(/^\/+/, "")}`, origin).href
}

export function fragmentOf(locator) {
  const fragment = Array.isArray(locator?.locations?.fragments) ? locator.locations.fragments[0] : null
  return typeof fragment === "string" && fragment && !fragment.includes("=") ? fragment : null
}

export function restorableFraction(locator) {
  return locator && !locator.locations?.cfi && !fragmentOf(locator) && locator.locations?.progression > 0 ? locator.locations.progression : null
}

export function fractionPlace(contents, progression) {
  const walker = contents.document.createTreeWalker(contents.document.body, NodeFilter.SHOW_TEXT)
  const nodes = []
  while (walker.nextNode()) if (walker.currentNode.textContent.length) nodes.push(walker.currentNode)
  const pictures = nodes.some(node => node.textContent.trim()) ? [] : [...contents.document.querySelectorAll("img, image")]
  if (pictures.length) return contents.cfiFromNode(pictures[Math.min(pictures.length - 1, Math.round(pictures.length * progression))])
  let offset = Math.floor(nodes.reduce((length, node) => length + node.textContent.length, 0) * Math.min(1, progression))
  for (const node of nodes) {
    if (offset <= node.textContent.length) {
      const range = contents.document.createRange()
      range.setStart(node, offset)
      range.collapse(true)
      return contents.cfiFromRange(range)
    }
    offset -= node.textContent.length
  }
  return null
}

export function elementCfi(contents, element) {
  const range = element.ownerDocument.createRange()
  range.selectNodeContents(element)
  range.collapse(true)
  return contents.cfiFromRange(range)
}

export async function settleFrames(rendition) {
  for (const view of rendition.views().all?.() || []) {
    view.expand?.()
    await view.contents?.document?.fonts?.ready
    view.expand?.()
  }
}

export function pageCfi(rendition, viewport, location) {
  const start = location?.start
  const contents = start?.cfi && rendition.getContents().find(item => item.sectionIndex === start.index)
  const frame = contents?.window?.frameElement
  if (!frame) return start?.cfi
  const view = viewport.getBoundingClientRect(), box = frame.getBoundingClientRect()
  const onPage = rect => rect.width + rect.height > 0 && rect.right > view.left - box.left + 1 && rect.left < view.right - box.left - 1
  let named = null
  try { named = rendition.getRange(start.cfi) } catch (_) { named = null }
  if (textOnPage(named, onPage)) return start.cfi
  const picture = [...contents.document.querySelectorAll("img, image")].find(node => onPage(node.getBoundingClientRect()))
  return picture ? contents.cfiFromNode(picture) : start.cfi
}

export function textOnPage(range, onPage) {
  const node = range?.startContainer
  if (node?.nodeType !== Node.TEXT_NODE) return false
  const skip = node.textContent.slice(range.startOffset).search(/\S/)
  if (skip < 0) return false
  const character = node.ownerDocument.createRange()
  character.setStart(node, range.startOffset + skip)
  character.setEnd(node, range.startOffset + skip + 1)
  return [...character.getClientRects()].some(onPage)
}

export function pageProgression(start, spineLength) {
  const fraction = Math.max(0, (start.displayed.page - 1) / Math.max(1, start.displayed.total))
  const total = Math.min(1, (start.index + fraction) / Math.max(1, spineLength))
  return { fraction, total }
}
