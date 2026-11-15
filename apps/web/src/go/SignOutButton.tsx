import { useState } from "react";
import { useGoSession } from "./session";

export function SignOutButton() {
  const go = useGoSession();
  const [pending, setPending] = useState(false);
  const [failed, setFailed] = useState(false);
  if (!go) return null;
  return (
    <div className="sign-out">
      <button
        type="button"
        className="button button--subtle"
        disabled={pending}
        onClick={() => {
          setPending(true);
          setFailed(false);
          void go.signOut().then((done) => {
            if (!done) {
              setPending(false);
              setFailed(true);
            }
          });
        }}
      >
        {pending ? "Signing out…" : "Sign out"}
      </button>
      {failed ? (
        <span role="alert" className="status-error">
          Could not sign out. Try again.
        </span>
      ) : null}
    </div>
  );
}
