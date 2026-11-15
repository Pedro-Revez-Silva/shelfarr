export function LockedScreen({ reason, classicLibrary }: { reason: "signed_out" | "account_changed"; classicLibrary: string }) {
  const here = window.location.href;
  return (
    <main className="locked" id="main">
      <h1>{reason === "signed_out" ? "Your session ended" : "The signed-in account changed"}</h1>
      <p>
        {reason === "signed_out"
          ? "You were signed out, so this page stopped showing your library. Nothing was changed."
          : "Another tab signed in as someone else. This page was opened for the previous account, so it stopped. Nothing was changed."}
      </p>
      <p className="state-actions">
        <a className="button button--primary" href={here}>
          {reason === "signed_out" ? "Sign in again" : "Reload as the current account"}
        </a>
        <a className="button" href={classicLibrary}>
          Open the classic library
        </a>
      </p>
    </main>
  );
}
