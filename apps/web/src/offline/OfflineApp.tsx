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
import { offlineUntil, type ConfirmedAccount, type OfflineStore } from "./model";
import { OfflineReader } from "./OfflineReader";
import { SaveFailure } from "./save";

const PROBE_INTERVAL_MS = 20_000;
const CHECK_INTERVAL_MS = 30_000;

export function serverUnreachable(error: unknown): boolean {
  if (!(error instanceof ApiError)) return false;
  return error.kind === "network" || error.status === 502 || error.status === 503 || error.status === 504;
}

export function definitiveRefusal(error: unknown): boolean {
  return error instanceof ApiError && typeof error.status === "number" && error.status >= 400 && error.status < 500;
}

type Props = { boot: GoBoot & { offline: OfflineBoot }; auth: AuthClient; store: OfflineStore; record: ConfirmedAccount; onConnected: () => void };

export function OfflineApp({ boot, auth, store, record, onConnected }: Props) {
  const [built] = useState(() => {
    const guard = new AccountGuard(record.account);
    const services = createServices({ boot: { version: 1, account: record.account, mount: boot.mount, api: boot.api, classic_library: null, runtime: "go" }, guard, csrfToken: () => null });
    return { guard, services };
  });
  const { guard, services } = built;
  const [offline, setOffline] = useState<Offline>({ boot: boot.offline, store, confirmation: record, connected: false, confirm: () => Promise.reject(new SaveFailure("network")) });

  const recheck = useCallback(async () => {
    const state = await store.accountState().catch(() => null);
    const switched = state?.record != null && state.record.account !== guard.account;
    const kept = !switched && state !== null && (await store.touch(guard.account, Date.now()).catch(() => false));
    if (!kept) guard.lock(switched ? "account_changed" : "signed_out");
  }, [store, guard]);

  const probe = useCallback(async () => {
    if (!guard.isActive()) return;
    const before = await store.accountState().catch(() => null);
    if (!before) return;
    let answer;
    try {
      answer = await auth.bootstrap();
    } catch (error) {
      if (!definitiveRefusal(error) || !guard.isActive()) return;
      await store.forget().catch(() => undefined);
      guard.lock("signed_out");
      return;
    }
    if (!guard.isActive()) return;
    const confirmation = answer.authenticated ? confirmationFrom(answer.account, answer.offline_expires_in, Date.now()) : null;
    if (!answer.authenticated || !confirmation) {
      await store.forget().catch(() => undefined);
      guard.lock("signed_out");
      return;
    }
    if (!(await store.confirm(confirmation, before.generation).catch(() => false))) {
      await recheck();
      return;
    }
    if (answer.account !== guard.account) {
      guard.lock("account_changed");
      return;
    }
    setOffline((value) => ({ ...value, confirmation, connected: true }));
  }, [auth, store, guard, recheck]);

  const until = offline.confirmation ? offlineUntil(offline.confirmation) : 0;
  useEffect(() => {
    const timer = setTimeout(() => void recheck(), Math.max(0, Math.min(until - Date.now() + 1, 2_147_000_000)));
    return () => clearTimeout(timer);
  }, [until, recheck]);

  useEffect(() => {
    const root = document.documentElement;
    const hide = () => root.setAttribute("data-offline-check", "pending");
    const show = () => {
      void recheck().finally(() => root.removeAttribute("data-offline-check"));
      void probe();
    };
    const restored = (event: PageTransitionEvent) => {
      if (event.persisted) window.location.reload();
      else show();
    };
    const visible = () => document.visibilityState === "visible" && show();
    window.addEventListener("pagehide", hide);
    window.addEventListener("pageshow", restored);
    window.addEventListener("focus", show);
    window.addEventListener("online", show);
    document.addEventListener("visibilitychange", visible);
    const checks = setInterval(() => void recheck(), CHECK_INTERVAL_MS);
    const probes = setInterval(() => void probe(), PROBE_INTERVAL_MS);
    return () => {
      window.removeEventListener("pagehide", hide);
      window.removeEventListener("pageshow", restored);
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
