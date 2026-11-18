import type { AccountGuard } from "../api/account-guard";
import { errorEnvelopeSchema } from "../contract";

export class ReaderFailure extends Error {}

const MESSAGES: Record<string, string> = {
  signed_out: "Your session ended, so the book was not opened.",
  account_changed: "Another account is signed in now, so this book was not opened.",
  asset_unavailable: "This file changed or was removed from the server. Go back to the book and open it again.",
  not_found: "This book is no longer in your library.",
};

export async function fetchBook(address: string, guard: AccountGuard, signal: AbortSignal): Promise<ArrayBuffer> {
  const url = new URL(address, window.location.href);
  if (url.origin !== window.location.origin) throw new ReaderFailure("The book must come from this server.");
  guard.assertActive();
  let response: Response;
  try {
    response = await fetch(url.pathname, { credentials: "same-origin", cache: "no-store", redirect: "error", referrerPolicy: "no-referrer", signal });
  } catch (error) {
    if (error instanceof DOMException && error.name === "AbortError") throw error;
    throw new ReaderFailure("The book could not be downloaded. Check your connection, then try again.");
  }
  if (!response.ok) {
    const envelope = errorEnvelopeSchema.safeParse(await response.json().catch(() => null));
    const code = envelope.success ? envelope.data.error : null;
    if (code === "signed_out" || code === "account_changed") guard.lock(code);
    throw new ReaderFailure((code && MESSAGES[code]) ?? `The server could not send this book (${response.status}).`);
  }
  const body = await response.arrayBuffer();
  guard.assertActive();
  return body;
}
