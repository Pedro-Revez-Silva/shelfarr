type KeyTarget = { closest?: (selector: string) => unknown; isContentEditable?: boolean } | null;

const EDITING = "input, select, textarea, [contenteditable]:not([contenteditable='false']), [role='slider'], [role='spinbutton'], [role='textbox'], [role='combobox'], [role='listbox']";
const ACTIVATING = "button, a[href], summary, [role='button'], [role='link']";

function within(target: EventTarget | null, selector: string): boolean {
  const element = target as KeyTarget;
  if (!element) return false;
  if (element.isContentEditable) return true;
  return typeof element.closest === "function" && element.closest(selector) !== null;
}

function plain(event: KeyboardEvent): boolean {
  return !event.defaultPrevented && !event.isComposing && !event.altKey && !event.ctrlKey && !event.metaKey;
}

export function pageKey(event: KeyboardEvent): "next" | "previous" | null {
  if (!plain(event) || within(event.target, EDITING)) return null;
  if (event.key === "ArrowRight" || event.key === "PageDown") return "next";
  if (event.key === "ArrowLeft" || event.key === "PageUp") return "previous";
  return null;
}

export function playKey(event: KeyboardEvent): boolean {
  return plain(event) && !event.shiftKey && event.key === " " && !within(event.target, EDITING) && !within(event.target, ACTIVATING);
}
