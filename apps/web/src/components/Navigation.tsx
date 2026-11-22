import { Link, useLocation } from "@tanstack/react-router";
import type { Session } from "../contract";
import { useOffline } from "../offline/context";
import { useServices } from "../services";

export type Place = "library" | "find" | "account" | "server" | null;

export function placeOf(pathname: string, basepath: string): Place {
  const path = pathname.startsWith(basepath) ? pathname.slice(basepath.replace(/\/$/, "").length) || "/" : pathname;
  if (/^\/(?:library)(?:\/|$)/.test(path)) return "library";
  if (/^\/(?:find|discover|books|requests)(?:\/|$)/.test(path)) return "find";
  if (/^\/account(?:\/|$)/.test(path)) return "account";
  if (/^\/(?:admin|server)(?:\/|$)/.test(path)) return "server";
  return null;
}

function current(place: Place, item: Place): "page" | undefined {
  return place === item ? "page" : undefined;
}

export function PrimaryNavigation({ session }: { session: Session | undefined }) {
  const { mode, boot } = useServices();
  const offline = useOffline();
  const place = placeOf(useLocation({ select: (location) => location.pathname }), boot.mount);
  const go = mode === "go";
  const ready = session !== undefined || go;
  return (
    <nav className="primary-nav" aria-label="Primary" aria-busy={ready ? undefined : "true"}>
      <ul>
        <li>
          <Link to="/library" className="nav-link" aria-current={current(place, "library")} activeProps={{}}>
            Library
          </Link>
        </li>
        <li>
          <Link to={go ? "/discover" : "/find"} className="nav-link" aria-current={current(place, "find")} activeProps={{}}>
            Find
          </Link>
        </li>
        {go && offline ? (
          <li>
            <a className="nav-link" href={offline.boot.downloads}>
              Downloads
            </a>
          </li>
        ) : null}
        <li>
          <Link to="/account" className="nav-link" aria-current={current(place, "account")} activeProps={{}}>
            Account
          </Link>
        </li>
        {session?.admin ? (
          <li>
            <Link to={go ? "/admin" : "/server"} className="nav-link" aria-current={current(place, "server")} activeProps={{}}>
              Server
            </Link>
          </li>
        ) : null}
      </ul>
    </nav>
  );
}

export function NotificationBell({ session }: { session: Session | undefined }) {
  const link = session?.notifications;
  if (!link) return null;
  const unread = link.unread;
  return (
    <a className="bell" href={link.url} aria-label={unread > 0 ? `Notifications, ${unread} unread` : "Notifications"}>
      <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" aria-hidden="true" focusable="false">
        <path d="M6 16V11a6 6 0 1 1 12 0v5l1.5 2h-15zM10 20a2 2 0 0 0 4 0" />
      </svg>
      {unread > 0 ? (
        <span className="bell-count" aria-hidden="true">
          {unread > 9 ? "9+" : unread}
        </span>
      ) : null}
    </a>
  );
}
