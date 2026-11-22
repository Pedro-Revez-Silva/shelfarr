import type { FailureKind, Upload } from "./model";

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

export function uploadText(upload: Upload | undefined): string {
  switch (upload?.state) {
    case undefined:
    case "pending":
      return "Your place is saved on this device and will be sent to your account as soon as Shelfarr can be reached.";
    case "synced":
      return "Your place was sent to your account.";
    case "superseded":
      return "Your account already has a later place from another device, so this device's place wasn't sent. It is kept here.";
    case "held":
      return upload.reason === "rejected"
        ? `Your account didn't accept this device's place${upload.message ? `: ${upload.message}` : ""}. It is kept here.`
        : "This device's place wasn't sent because your account has a place in another file or with an unclear time. Open the book while connected to choose.";
  }
}
