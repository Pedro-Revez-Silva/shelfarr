import { Link } from "@tanstack/react-router";
import type { Session } from "../contract";
import { useServices } from "../services";

export function PrimaryNavigation({ session }: { session: Session | undefined }) {
  const { mode } = useServices();
  const handoffs = mode === "rails";
  return (
    <nav className="primary-nav" aria-label="Primary" aria-busy={session || !handoffs ? undefined : "true"}>
      <ul>
        <li>
          <Link to="/library" className="nav-link">
            Library
          </Link>
        </li>
        {handoffs ? null : (
          <>
            <li>
              <Link to="/discover" className="nav-link">
                Discover
              </Link>
            </li>
            <li>
              <Link to="/account" className="nav-link">
                Account
              </Link>
            </li>
          </>
        )}
        {session && handoffs ? (
          <>
            <HandoffLink href={session.links.discover} label="Discover" />
            <HandoffLink href={session.links.requests} label="Requests" />
            <HandoffLink href={session.links.account} label="Account" />
            {session.admin ? <HandoffLink href={session.admin.url} label="Admin" /> : null}
          </>
        ) : null}
      </ul>
    </nav>
  );
}

function HandoffLink({ href, label }: { href: string; label: string }) {
  return (
    <li>
      <a className="nav-link nav-link--handoff" href={href}>
        {label}
        <span className="sr-only"> (opens the classic Shelfarr app)</span>
      </a>
    </li>
  );
}
