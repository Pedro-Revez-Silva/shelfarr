import type { LockReason } from "../api/account-guard";
import { useGoSession } from "../go/session";
import { useDocumentTitle } from "../title";

const LOCKED: Record<LockReason, { title: string; heading: string; body: string }> = {
  signed_out: { title: "Session ended", heading: "Your session ended", body: "You were signed out, so this page stopped showing your library. Nothing was changed." },
  account_changed: {
    title: "Account changed",
    heading: "The signed-in account changed",
    body: "Another tab signed in as someone else. This page was opened for the previous account, so it stopped. Nothing was changed.",
  },
  access_changed: {
    title: "Access changed",
    heading: "This account's access changed",
    body: "An administrator changed what this account may see, so this page stopped showing what it had loaded. Nothing was changed.",
  },
};

export function LockedScreen({ reason, classicLibrary }: { reason: LockReason; classicLibrary: string | null }) {
  const here = window.location.href;
  const go = useGoSession();
  const text = LOCKED[reason];
  useDocumentTitle(text.title);
  return (
    <main className="locked" id="main">
      <h1>{text.heading}</h1>
      <p>{text.body}</p>
      <p className="state-actions">
        {go ? (
          <button type="button" className="button button--primary" onClick={() => go.recover(reason)}>
            {reason === "signed_out" ? "Sign in again" : "Continue as the current account"}
          </button>
        ) : (
          <a className="button button--primary" href={here}>
            {reason === "signed_out" ? "Sign in again" : "Reload as the current account"}
          </a>
        )}
        {classicLibrary ? (
          <a className="button" href={classicLibrary}>
            Open the classic library
          </a>
        ) : null}
      </p>
    </main>
  );
}
