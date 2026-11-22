import type { FailureKind } from "./model";

export const FAILURES: Record<FailureKind, string> = {
  network: "The connection dropped before the book was saved, so nothing new was stored. Try again when you're connected.",
  signed_out: "Your session or the signed-in account changed, so nothing was saved. Sign in again to save books.",
  changed: "The book changed on the server or didn't arrive complete, so nothing new was stored. Try again.",
  missing: "This book is no longer on the server, so it can't be saved.",
  space: "There isn't enough room in this browser for this book. Remove a saved book or free some space, then try again.",
  too_large: "This EPUB is larger than 32 MiB, the most this browser reader keeps, so it can't be saved.",
  storage: "This browser couldn't store the book, so nothing new was saved.",
  worker: "Offline reading couldn't start in this browser, so nothing was saved. Reload the page and try again.",
  busy: "Another tab is already saving this book. Wait for it to finish.",
  unsupported: "This browser can't keep books for offline reading.",
  removed: "The saved copy was removed while the new one was saving, so nothing was stored. Save it again if you still want it.",
};

export const RETRYABLE: ReadonlySet<FailureKind> = new Set(["network", "changed", "space", "storage", "worker", "busy", "removed"]);

const DATE = new Intl.DateTimeFormat(undefined, { dateStyle: "medium" });
const MOMENT = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" });

export const formatDay = (at: number): string => DATE.format(at);
export const formatMoment = (at: number): string => MOMENT.format(at);
