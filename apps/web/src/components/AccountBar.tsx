import type { Session } from "../contract";

export function AccountBar({ session, loading }: { session: Session | undefined; loading: boolean }) {
  if (!session) {
    return <p className="account-bar">{loading ? "Checking your session…" : "Session unavailable"}</p>;
  }
  return (
    <p className="account-bar">
      <span className="account-server">{session.server.name}</span>
      <span aria-hidden="true"> · </span>
      <span>
        Signed in as <strong>{session.account.name}</strong>
      </span>
    </p>
  );
}
