import { useCallback, useEffect, useState } from "react";
import { AccountGuard } from "../api/account-guard";
import { ApiError } from "../api/errors";
import { AuthFrame } from "../go/AuthFrame";
import type { AuthClient } from "../go/auth";
import { PageHeading } from "../components/PageHeading";
import type { GoBoot, OfflineBoot } from "../contract";
import { createServices, ServicesProvider, useGuardState } from "../services";
import { useDocumentTitle } from "../title";
import { OfflineProvider, confirmationFrom, type Offline } from "./context";
import { DownloadsPage } from "./DownloadsPage";
import { usable, type ConfirmedAccount, type OfflineStore } from "./model";
import { OfflineReader } from "./OfflineReader";

const PROBE_INTERVAL_MS = 20_000;
const CHECK_INTERVAL_MS = 30_000;

export function serverUnreachable(error: unknown): boolean {
  if (!(error instanceof ApiError)) return false;
  return error.kind === "network" || error.status === 502 || error.status === 503 || error.status === 504;
}

type Props = { boot: GoBoot & { offline: OfflineBoot }; auth: AuthClient; store: OfflineStore; record: ConfirmedAccount; onConnected: () => void };

export function OfflineApp({ boot, auth, store, record, onConnected }: Props) {
  const [built] = useState(() => {
    const guard = new AccountGuard(record.account);
    const services = createServices({ boot: { version: 1, account: record.account, mount: boot.mount, api: boot.api, classic_library: null, runtime: "go" }, guard, csrfToken: () => null });
    return { guard, services };
  });
  const { guard, services } = built;
  const [offline, setOffline] = useState<Offline>({ boot: boot.offline, store, confirmation: record, connected: false });

  const recheck = useCallback(async () => {
    const current = await store.account().catch(() => null);
    const switched = current !== null && current.account !== guard.account;
    if (!usable(current, guard.account, Date.now())) guard.lock(switched ? "account_changed" : "signed_out");
  }, [store, guard]);

  const probe = useCallback(async () => {
    if (!guard.isActive()) return;
    let answer;
    try {
      answer = await auth.bootstrap();
    } catch (error) {
      if (serverUnreachable(error)) return;
      await store.forget().catch(() => undefined);
      guard.lock("signed_out");
      return;
    }
    if (!answer.authenticated) {
      await store.forget().catch(() => undefined);
      guard.lock("signed_out");
      return;
    }
    const confirmation = confirmationFrom(answer.account, answer.offline_expires_in, Date.now());
    if (confirmation) await store.confirm(confirmation).catch(() => undefined);
    else await store.forget().catch(() => undefined);
    if (answer.account !== guard.account || !confirmation) {
      guard.lock("account_changed");
      return;
    }
    setOffline((value) => ({ ...value, confirmation, connected: true }));
  }, [auth, store, guard]);

  useEffect(() => {
    const root = document.documentElement;
    const hide = () => root.setAttribute("data-offline-check", "pending");
    const show = () => {
      void recheck().finally(() => root.removeAttribute("data-offline-check"));
      void probe();
    };
    const visible = () => document.visibilityState === "visible" && show();
    window.addEventListener("pagehide", hide);
    window.addEventListener("pageshow", show);
    window.addEventListener("focus", show);
    window.addEventListener("online", show);
    document.addEventListener("visibilitychange", visible);
    const checks = setInterval(() => void recheck(), CHECK_INTERVAL_MS);
    const probes = setInterval(() => void probe(), PROBE_INTERVAL_MS);
    return () => {
      window.removeEventListener("pagehide", hide);
      window.removeEventListener("pageshow", show);
      window.removeEventListener("focus", show);
      window.removeEventListener("online", show);
      document.removeEventListener("visibilitychange", visible);
      clearInterval(checks);
      clearInterval(probes);
      root.removeAttribute("data-offline-check");
    };
  }, [recheck, probe]);

  return (
    <ServicesProvider services={services}>
      <OfflineProvider value={offline}>
        <OfflineView boot={boot} connected={offline.connected} onConnected={onConnected} />
      </OfflineProvider>
    </ServicesProvider>
  );
}

function OfflineView({ boot, connected, onConnected }: { boot: GoBoot; connected: boolean; onConnected: () => void }) {
  const guard = useGuardState();
  if (guard.status !== "active") return <OfflineEnded reason={guard.status} onRetry={onConnected} />;
  return (
    <>
      {connected ? (
        <p className="notice offline-reconnected" role="status">
          You're connected again. Places you reached offline stay on this device.{" "}
          <button type="button" className="button" onClick={onConnected}>
            Continue online
          </button>
        </p>
      ) : null}
      {boot.view === "reader" ? <OfflineReader engine={boot.reader_engine} /> : <DownloadsPage />}
    </>
  );
}

function OfflineEnded({ reason, onRetry }: { reason: string; onRetry: () => void }) {
  const switched = reason === "account_changed";
  useDocumentTitle(switched ? "Account changed" : "Offline access ended");
  return (
    <AuthFrame>
      <section className="auth-card">
        <PageHeading id="offline-ended-heading">{switched ? "The signed-in account changed" : "Offline access ended"}</PageHeading>
        <p>
          {switched
            ? "This browser is now signed in to another account, so the books saved for the previous one stay hidden. Nothing was changed."
            : "This browser's last confirmed sign-in has ended or was signed out, so saved books stay hidden. Connect and sign in again to read them; nothing was removed."}
        </p>
        <div className="state-actions">
          <button type="button" className="button button--primary" onClick={onRetry}>
            Try connecting
          </button>
        </div>
      </section>
    </AuthFrame>
  );
}

export function OfflineUnavailable({ onRetry }: { onRetry: () => void }) {
  useDocumentTitle("Unavailable");
  return (
    <AuthFrame>
      <section className="auth-card">
        <PageHeading id="unavailable-heading">Shelfarr can't be reached</PageHeading>
        <p className="form-error" role="alert">
          The server can't be reached, and this browser has no current sign-in it can use to open saved books. Connect and sign in again to read them.
        </p>
        <div className="state-actions">
          <button type="button" className="button button--primary" onClick={onRetry}>
            Try again
          </button>
        </div>
      </section>
    </AuthFrame>
  );
}
