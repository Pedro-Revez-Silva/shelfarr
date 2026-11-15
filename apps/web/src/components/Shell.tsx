import { Link, Outlet } from "@tanstack/react-router";
import { useGuardState } from "../services";
import { useSession } from "../queries";
import { AccountBar } from "./AccountBar";
import { PrimaryNavigation } from "./Navigation";
import { LockedScreen } from "./LockedScreen";
import { useServices } from "../services";

export function Shell() {
  const guard = useGuardState();
  const { boot } = useServices();

  if (guard.status !== "active") {
    return <LockedScreen reason={guard.status} classicLibrary={boot.classic_library} />;
  }

  return <ActiveShell classicLibrary={boot.classic_library} />;
}

function ActiveShell({ classicLibrary }: { classicLibrary: string }) {
  const session = useSession();

  return (
    <div className="shell">
      <a className="skip-link" href="#main">
        Skip to content
      </a>
      <header className="shell-header">
        <div className="brand">
          <Link to="/library" className="wordmark" aria-label="Shelfarr library">
            <svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" aria-hidden="true" focusable="false">
              <path d="M4 4h5v16H4zM10 7h4v13h-4zM16 4l4-1 3 16-4 1z" />
            </svg>
            shelfarr
          </Link>
          <span className="preview-badge">Library preview</span>
        </div>
        <AccountBar session={session.data} loading={session.isPending} />
        <a className="classic-link" href={session.data?.links.legacy_library ?? classicLibrary}>
          Classic library
          <span className="sr-only"> (opens the classic Shelfarr app)</span>
        </a>
        <PrimaryNavigation session={session.data} />
      </header>
      <main id="main" className="shell-main">
        <Outlet />
      </main>
    </div>
  );
}
