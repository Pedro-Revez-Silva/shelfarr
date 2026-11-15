import { useGoSession } from "../go/session";
import { useDocumentTitle } from "../title";

export function LockedScreen({ reason, classicLibrary }: { reason: "signed_out" | "account_changed"; classicLibrary: string | null }) {
  const here = window.location.href;
  const go = useGoSession();
  useDocumentTitle(reason === "signed_out" ? "Session ended" : "Account changed");
  return (
    <main className="locked" id="main">
      <h1>{reason === "signed_out" ? "Your session ended" : "The signed-in account changed"}</h1>
      <p>
        {reason === "signed_out"
          ? "You were signed out, so this page stopped showing your library. Nothing was changed."
          : "Another tab signed in as someone else. This page was opened for the previous account, so it stopped. Nothing was changed."}
      </p>
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
