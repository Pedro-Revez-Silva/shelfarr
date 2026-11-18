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

const SESSION_ENDED = "Your session ended. Sign in to continue.";
const SIGNED_OUT = "You are signed out.";

type AuthState =
  | { kind: "loading" }
  | { kind: "unavailable"; message: string; retry: boolean }
  | { kind: "signed_out"; token: LoginToken; availability: { available: boolean; reason: string | null }; notice: string | null; focus: boolean }
  | { kind: "signed_in"; account: string; token: string; expiresIn: number };

type Load = { notice?: string; focus?: boolean };

function describeUnavailable(error: unknown): { message: string; retry: boolean } {
  if (error instanceof ApiError && error.kind === "not_found") return { message: "These screens are not switched on for this server or account.", retry: false };
  if (error instanceof ApiError && error.kind === "network") return { message: "Could not reach the server. Check your connection, then try again.", retry: true };
  return { message: "The server answered with something these screens do not understand. Reload the page to try again.", retry: true };
}

export function GoApp({ boot, fetcher }: { boot: GoBoot; fetcher?: typeof fetch }) {
  const auth = useMemo(() => new AuthClient(boot.api, fetcher), [boot.api, fetcher]);
  const [state, setState] = useState<AuthState>({ kind: "loading" });
  const [epoch, setEpoch] = useState(0);

  const load = useCallback(
    async (options: Load = {}) => {
      setState({ kind: "loading" });
      try {
        const result = await auth.bootstrap();
        setEpoch((value) => value + 1);
        setState(fromBootstrap(result, options));
      } catch (error) {
        setState({ kind: "unavailable", ...describeUnavailable(error) });
      }
    },
    [auth],
  );

  useEffect(() => {
    void load();
  }, [load]);

  const signedIn = useCallback((result: LoginResult) => {
    markPageNavigated();
    setEpoch((value) => value + 1);
    setState({ kind: "signed_in", account: result.account, token: result.csrf_token, expiresIn: result.expires_in });
  }, []);

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
      return <SignedIn key={epoch} boot={boot} auth={auth} account={state.account} token={state.token} expiresIn={state.expiresIn} fetcher={fetcher} onEnded={(options) => void load(options)} />;
  }
}

function introFor(view: GoBoot["view"]): string {
  if (view === "connect") return "Sign in to approve or decline the connection you started in your Shelfarr app. You will come straight back to it.";
  if (view === "reader") return "Sign in to open this book. You will come straight back to it.";
  if (view === "account") return "Sign in to manage your account. You will come straight back to it.";
  return "Sign in to browse your library.";
}

function fromBootstrap(result: Bootstrap, options: Load): AuthState {
  if (result.authenticated) {
    if (options.focus) markPageNavigated();
    return { kind: "signed_in", account: result.account, token: result.csrf_token, expiresIn: result.expires_in };
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
  fetcher: typeof fetch | undefined;
  onEnded: (options: Load) => void;
};

function SignedIn({ boot, auth, account, token, expiresIn, fetcher, onEnded }: SignedInProps) {
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
    const router = boot.view === "connect" || boot.view === "reader" ? null : createAppRouter({ basepath: boot.mount });
    return { csrf, services, router };
  });
  const { csrf, services, router } = built;

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
        onEnded({ notice: SIGNED_OUT, focus: true });
        services.guard.lock("signed_out");
        return true;
      },
      recover: (reason) => onEnded({ ...(reason === "signed_out" ? { notice: SESSION_ENDED } : {}), focus: true }),
    }),
    [account, auth, csrf, onEnded, services],
  );

  return (
    <GoSessionProvider value={session}>
      {router ? (
        <App services={services} router={router} />
      ) : (
        <ServicesProvider services={services}>{boot.view === "reader" ? <ReaderApp engine={boot.reader_engine} pageEngine={boot.page_engine} /> : <ConnectPage />}</ServicesProvider>
      )}
    </GoSessionProvider>
  );
}
