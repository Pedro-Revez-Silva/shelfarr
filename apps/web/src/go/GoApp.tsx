import { useCallback, useEffect, useMemo, useState } from "react";
import { App } from "../App";
import { AccountGuard } from "../api/account-guard";
import { ApiError } from "../api/errors";
import { PageHeading, markPageNavigated } from "../components/PageHeading";
import type { Bootstrap, GoBoot } from "../contract";
import { ReaderApp } from "../reader/ReaderApp";
import { createAppRouter } from "../router";
import { createServices, ServicesProvider } from "../services";
import { useDocumentTitle } from "../title";
import { AuthClient, CsrfSession, type LoginResult } from "./auth";
import { AuthFrame } from "./AuthFrame";
import { ConnectPage } from "./ConnectPage";
import { GoSessionProvider, type GoSession } from "./session";
import { SignInPage, type LoginToken } from "./SignInPage";
import { LockedScreen } from "../components/LockedScreen";
import { confirmationFrom, OfflineProvider, type Offline } from "../offline/context";
import { DownloadsPage } from "../offline/DownloadsPage";
import type { ConfirmedAccount, OfflineStore } from "../offline/model";
import { definitiveRefusal, OfflineApp, OfflineUnavailable, serverUnreachable } from "../offline/OfflineApp";
import { SaveFailure } from "../offline/save";
import { offlineStore } from "../offline/store";
import { hasWorker, retireWorker } from "../offline/worker";
import { useAccountRevalidation } from "../revalidation";
import { useGuardState } from "../services";

const SESSION_ENDED = "Your session ended. Sign in to continue.";
const SIGNED_OUT = "You are signed out.";

type AuthState =
  | { kind: "loading" }
  | { kind: "unavailable"; message: string; retry: boolean }
  | { kind: "signed_out"; token: LoginToken; availability: { available: boolean; reason: string | null }; notice: string | null; focus: boolean }
  | { kind: "signed_in"; account: string; token: string; expiresIn: number; confirmation: ConfirmedAccount | null }
  | { kind: "offline"; record: ConfirmedAccount }
  | { kind: "offline_unavailable" };

type Load = { notice?: string; focus?: boolean };

const RETIRED_WORKER = { scope: "/preview/library/", worker: "/preview/offline-worker.js" };
const SAVED_VIEWS: readonly GoBoot["view"][] = ["reader", "downloads"];

async function keepOfflineAccount(boot: GoBoot, store: OfflineStore, confirmation: ConfirmedAccount | null, askedAt: number): Promise<void> {
  if (!boot.offline) return;
  if (!confirmation) {
    await store.release(askedAt);
    return;
  }
  if ((await hasWorker(boot.offline)) || (await store.accountState()).record) await store.confirm(confirmation);
}

async function retireOffline(store: OfflineStore): Promise<void> {
  await store.forget().catch(() => undefined);
  await retireWorker(RETIRED_WORKER);
}

async function offlineFallback(boot: GoBoot, store: OfflineStore, error: unknown): Promise<AuthState | null> {
  if (!boot.offline || !SAVED_VIEWS.includes(boot.view) || !serverUnreachable(error)) return null;
  const { record } = await store.accountState().catch(() => ({ record: null }));
  if (!record) return { kind: "offline_unavailable" };
  const kept = await store.touch(record.account, Date.now()).catch(() => false);
  return kept ? { kind: "offline", record } : { kind: "offline_unavailable" };
}

function describeUnavailable(error: unknown): { message: string; retry: boolean } {
  if (error instanceof ApiError && error.kind === "not_found") return { message: "These screens are not switched on for this server or account.", retry: false };
  if (error instanceof ApiError && error.kind === "network") return { message: "Could not reach the server. Check your connection, then try again.", retry: true };
  return { message: "The server answered with something these screens do not understand. Reload the page to try again.", retry: true };
}

export function GoApp({ boot, fetcher, store = offlineStore }: { boot: GoBoot; fetcher?: typeof fetch; store?: OfflineStore }) {
  const auth = useMemo(() => new AuthClient(boot.api, fetcher), [boot.api, fetcher]);
  const [state, setState] = useState<AuthState>({ kind: "loading" });
  const [epoch, setEpoch] = useState(0);

  const load = useCallback(
    async (options: Load = {}) => {
      setState({ kind: "loading" });
      if (!boot.offline) void retireOffline(store).catch(() => undefined);
      const sentAt = Date.now();
      try {
        const result = await auth.bootstrap();
        setEpoch((value) => value + 1);
        const next = fromBootstrap(result, options, sentAt);
        void keepOfflineAccount(boot, store, next.kind === "signed_in" ? next.confirmation : null, sentAt).catch(() => undefined);
        setState(next);
      } catch (error) {
        if (definitiveRefusal(error)) await store.release(sentAt).catch(() => undefined);
        const fallback = await offlineFallback(boot, store, error);
        if (fallback) setEpoch((value) => value + 1);
        setState(fallback ?? { kind: "unavailable", ...describeUnavailable(error) });
      }
    },
    [auth, boot, store],
  );

  useEffect(() => {
    void load();
  }, [load]);

  const signedIn = useCallback(
    (result: LoginResult) => {
      markPageNavigated();
      setEpoch((value) => value + 1);
      const confirmation = confirmationFrom(result.account, result.offline_expires_in, Date.now());
      void keepOfflineAccount(boot, store, confirmation, Date.now()).catch(() => undefined);
      setState({ kind: "signed_in", account: result.account, token: result.csrf_token, expiresIn: result.expires_in, confirmation });
    },
    [boot, store],
  );

  switch (state.kind) {
    case "loading":
      return (
        <AuthFrame>
          <p className="state state--loading" role="status">
            <span className="spinner" aria-hidden="true" />
            Loading Shelfarr…
          </p>
        </AuthFrame>
      );
    case "unavailable":
      return <Unavailable message={state.message} retry={state.retry} onRetry={() => void load()} />;
    case "signed_out":
      return (
        <SignInPage
          key={epoch}
          auth={auth}
          token={state.token}
          availability={state.availability}
          intro={introFor(boot.view)}
          notice={state.notice}
          focusHeading={state.focus}
          onSignedIn={signedIn}
          onAlreadySignedIn={() => void load({ focus: true })}
        />
      );
    case "signed_in":
      return (
        <SignedIn
          key={epoch}
          boot={boot}
          auth={auth}
          account={state.account}
          token={state.token}
          expiresIn={state.expiresIn}
          confirmation={state.confirmation}
          store={store}
          fetcher={fetcher}
          onEnded={(options) => void load(options)}
        />
      );
    case "offline":
      return boot.offline ? <OfflineApp key={epoch} boot={{ ...boot, offline: boot.offline }} auth={auth} store={store} record={state.record} onConnected={() => void load()} /> : null;
    case "offline_unavailable":
      return <OfflineUnavailable onRetry={() => void load()} />;
  }
}

function introFor(view: GoBoot["view"]): string {
  if (view === "connect") return "Sign in to approve or decline the connection you started in your Shelfarr app. You will come straight back to it.";
  if (view === "reader") return "Sign in to open this book. You will come straight back to it.";
  if (view === "account") return "Sign in to manage your account. You will come straight back to it.";
  if (view === "discover") return "Sign in to find books. You will come straight back to your search.";
  if (view === "requests" || view === "request") return "Sign in to see your requests. You will come straight back to them.";
  if (view === "admin") return "Sign in to see the server overview. You will come straight back to it.";
  if (view === "server_settings") return "Sign in to change the server settings. You will come straight back to them.";
  return "Sign in to browse your library.";
}

function fromBootstrap(result: Bootstrap, options: Load, sentAt: number): AuthState {
  if (result.authenticated) {
    if (options.focus) markPageNavigated();
    return {
      kind: "signed_in",
      account: result.account,
      token: result.csrf_token,
      expiresIn: result.expires_in,
      confirmation: confirmationFrom(result.account, result.offline_expires_in, sentAt),
    };
  }
  return {
    kind: "signed_out",
    token: { value: result.csrf_token, expiresAt: Date.now() + result.expires_in * 1000 },
    availability: result.sign_in,
    notice: options.notice ?? null,
    focus: options.focus ?? false,
  };
}

function Unavailable({ message, retry, onRetry }: { message: string; retry: boolean; onRetry: () => void }) {
  useDocumentTitle("Unavailable");
  return (
    <AuthFrame>
      <section className="auth-card">
        <PageHeading id="unavailable-heading">Shelfarr is unavailable here</PageHeading>
        <p className="form-error" role="alert">
          {message}
        </p>
        {retry ? (
          <div className="state-actions">
            <button type="button" className="button button--primary" onClick={onRetry}>
              Try again
            </button>
          </div>
        ) : null}
      </section>
    </AuthFrame>
  );
}

type SignedInProps = {
  boot: GoBoot;
  auth: AuthClient;
  account: string;
  token: string;
  expiresIn: number;
  confirmation: ConfirmedAccount | null;
  store: OfflineStore;
  fetcher: typeof fetch | undefined;
  onEnded: (options: Load) => void;
};

function SignedIn({ boot, auth, account, token, expiresIn, confirmation, store, fetcher, onEnded }: SignedInProps) {
  const [built] = useState(() => {
    const guard = new AccountGuard(account);
    const csrf = new CsrfSession(auth, guard, token, expiresIn);
    const services = createServices({
      boot: { version: 1, account, mount: boot.mount, api: boot.api, classic_library: null, runtime: "go", ...(boot.reader_formats ? { reader_formats: boot.reader_formats } : {}) },
      guard,
      csrfToken: csrf.token,
      mutations: csrf.lifecycle,
      ...(fetcher ? { fetcher } : {}),
    });
    const router = boot.view === "connect" || boot.view === "reader" || boot.view === "downloads" ? null : createAppRouter({ basepath: boot.mount });
    return { csrf, services, router };
  });
  const { csrf, services, router } = built;

  useEffect(
    () =>
      services.guard.subscribe(() => {
        void store.forget(account).catch(() => undefined);
      }),
    [services, account, store],
  );

  const [offline] = useState<Offline | null>(() =>
    boot.offline
      ? {
          boot: boot.offline,
          store,
          confirmation,
          connected: true,
          confirm: async () => {
            await store.prepare();
            const sentAt = Date.now();
            let answer: Bootstrap;
            try {
              answer = await auth.bootstrap();
            } catch (error) {
              if (definitiveRefusal(error)) {
                await store.release(sentAt);
                throw new SaveFailure("signed_out");
              }
              throw new SaveFailure("network");
            }
            if (!answer.authenticated) {
              await store.release(sentAt);
              services.guard.lock("signed_out");
              throw new SaveFailure("signed_out");
            }
            if (answer.account !== account) {
              services.guard.lock("account_changed");
              throw new SaveFailure("signed_out");
            }
            const fresh = confirmationFrom(answer.account, answer.offline_expires_in, sentAt);
            if (!fresh) throw new SaveFailure("unsupported");
            if (!(await store.confirm(fresh))) throw new SaveFailure("signed_out");
            return fresh;
          },
        }
      : null,
  );

  useEffect(() => {
    const queryClient = services.queryClient;
    return () => {
      void queryClient.cancelQueries();
      queryClient.clear();
    };
  }, [services]);

  const session = useMemo<GoSession>(
    () => ({
      signOut: async () => {
        await csrf.lifecycle.prepare();
        const value = csrf.token();
        if (!value) return false;
        try {
          await auth.logout(account, value);
        } catch (error) {
          const gone = error instanceof ApiError && (error.kind === "signed_out" || error.kind === "account_changed");
          if (!gone) {
            if (error instanceof ApiError && error.kind === "csrf") await csrf.refresh();
            return false;
          }
        }
        await store.forget().catch(() => undefined);
        onEnded({ notice: SIGNED_OUT, focus: true });
        services.guard.lock("signed_out");
        return true;
      },
      recover: (reason) => onEnded({ ...(reason === "signed_out" ? { notice: SESSION_ENDED } : {}), focus: true }),
    }),
    [account, auth, csrf, onEnded, services, store],
  );

  return (
    <GoSessionProvider value={session}>
      <OfflineProvider value={offline}>
        {router ? (
          <App services={services} router={router} />
        ) : (
          <ServicesProvider services={services}>
            {boot.view === "reader" ? <ReaderApp engine={boot.reader_engine} pageEngine={boot.page_engine} /> : boot.view === "downloads" ? <OnlineDownloads /> : <ConnectPage />}
          </ServicesProvider>
        )}
      </OfflineProvider>
    </GoSessionProvider>
  );
}

function OnlineDownloads() {
  const guard = useGuardState();
  useAccountRevalidation();
  if (guard.status !== "active") return <LockedScreen reason={guard.status} classicLibrary={null} />;
  return <DownloadsPage />;
}
