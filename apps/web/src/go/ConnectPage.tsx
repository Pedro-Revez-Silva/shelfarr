import { useCallback, useEffect, useId, useReducer, useRef, useState, type FormEvent } from "react";
import { failureKind, isApiError } from "../api/errors";
import type { ConnectGrant } from "../contract";
import { useAccountRevalidation } from "../revalidation";
import { useGuardState, useServices } from "../services";
import { LockedScreen } from "../components/LockedScreen";
import { PageHeading } from "../components/PageHeading";
import { useDocumentTitle } from "../title";
import { AuthFrame } from "./AuthFrame";
import { useGoSession } from "./session";

const CONNECT_PATH = "/consumer/connect";
const MAX_CODE_CHARACTERS = 32;

type Decidable = { clientName: string; upgrade: boolean; requesting: boolean; scopes: string[]; expiresAt: string | null };

export type ConnectState =
  | { kind: "entry"; notice: string | null }
  | { kind: "inspecting"; code: string }
  | { kind: "failed"; code: string; message: string }
  | { kind: "invalid"; code: string; message: string }
  | { kind: "wrong_account"; code: string }
  | { kind: "decidable"; code: string; grant: Decidable; notice: string | null }
  | { kind: "deciding"; code: string; grant: Decidable; decision: "allow" | "deny" }
  | { kind: "uncertain"; code: string; grant: Decidable }
  | { kind: "done"; decision: "allowed" | "denied"; upgrade: boolean; requesting: boolean };

type Action =
  | { type: "entry"; notice?: string }
  | { type: "inspect"; code: string }
  | { type: "inspected"; code: string; grant: ConnectGrant | null; notice?: string }
  | { type: "failed"; code: string; message: string }
  | { type: "decide"; decision: "allow" | "deny" }
  | { type: "decided"; decision: "allowed" | "denied"; upgrade: boolean; requesting: boolean }
  | { type: "wrong_account" }
  | { type: "invalid"; message: string }
  | { type: "uncertain" };

const EXPIRED = "This connection code has expired or has already been used. Start again in the app.";

function decidable(grant: ConnectGrant): Decidable | null {
  if (!grant.decidable || grant.client_name === undefined) return null;
  return { clientName: grant.client_name, upgrade: grant.upgrade === true, requesting: grant.requesting === true, scopes: grant.scopes ?? [], expiresAt: grant.expires_at ?? null };
}

export function reduce(state: ConnectState, action: Action): ConnectState {
  switch (action.type) {
    case "entry":
      return { kind: "entry", notice: action.notice ?? null };
    case "inspect":
      return { kind: "inspecting", code: action.code };
    case "failed":
      return { kind: "failed", code: action.code, message: action.message };
    case "inspected": {
      if (!action.grant || !action.grant.pending) return { kind: "invalid", code: action.code, message: EXPIRED };
      const grant = decidable(action.grant);
      if (!grant) return { kind: "wrong_account", code: action.code };
      return { kind: "decidable", code: action.code, grant, notice: action.notice ?? null };
    }
    case "decide":
      return state.kind === "decidable" ? { kind: "deciding", code: state.code, grant: state.grant, decision: action.decision } : state;
    case "decided":
      return { kind: "done", decision: action.decision, upgrade: action.upgrade, requesting: action.requesting };
    case "wrong_account":
      return "code" in state ? { kind: "wrong_account", code: state.code } : state;
    case "invalid":
      return "code" in state ? { kind: "invalid", code: state.code, message: action.message } : state;
    case "uncertain":
      return state.kind === "deciding" ? { kind: "uncertain", code: state.code, grant: state.grant } : state;
  }
}

export function readUserCode(search: string): string | null {
  const values = new URLSearchParams(search).getAll("user_code");
  const last = values[values.length - 1];
  if (last === undefined) return null;
  const code = [...last.trim()].slice(0, MAX_CODE_CHARACTERS).join("");
  return code === "" ? null : code;
}

const SCOPE_TEXT: Record<string, string> = {
  "library:read": "Browse and download your library.",
  "progress:write": "Save your reading and listening progress.",
  "search:read": "Search for titles to request.",
  "requests:write": "Request ebooks and audiobooks for you. Requests follow this server's usual rules, including duplicate checks.",
  "requests:read": "See and cancel your own requests.",
};

function initialState(): ConnectState {
  const code = readUserCode(window.location.search);
  return code ? { kind: "inspecting", code } : { kind: "entry", notice: null };
}

export function ConnectPage() {
  const { api, guard } = useServices();
  const go = useGoSession();
  const guardState = useGuardState();
  useAccountRevalidation();
  const [state, dispatch] = useReducer(reduce, undefined, initialState);
  const [accountName, setName] = useState<string | null>(null);
  const deciding = useRef(false);
  const controller = useRef<AbortController | null>(null);
  const navigation = useRef(0);

  const inspect = useCallback(
    (code: string, notice?: string) => {
      controller.current?.abort();
      navigation.current += 1;
      const next = new AbortController();
      controller.current = next;
      dispatch({ type: "inspect", code });
      api.inspectConnection(code, next.signal).then(
        (result) => {
          if (next.signal.aborted) return;
          setName(result.account_name);
          dispatch(notice ? { type: "inspected", code, grant: result.grant, notice } : { type: "inspected", code, grant: result.grant });
        },
        (error: unknown) => {
          if (next.signal.aborted || !guard.isActive()) return;
          dispatch({ type: "failed", code, message: failureMessage(error) });
        },
      );
    },
    [api, guard],
  );

  useEffect(() => {
    if (state.kind === "inspecting") inspect(state.code);
    return () => controller.current?.abort();
  }, []);

  useEffect(() => {
    const onPop = () => {
      const code = readUserCode(window.location.search);
      deciding.current = false;
      if (code) inspect(code);
      else {
        controller.current?.abort();
        navigation.current += 1;
        dispatch({ type: "entry" });
      }
    };
    window.addEventListener("popstate", onPop);
    return () => window.removeEventListener("popstate", onPop);
  }, [inspect]);

  useEffect(() => {
    if (state.kind === "done") window.history.replaceState(null, "", CONNECT_PATH);
  }, [state.kind]);

  const decide = useCallback(
    (choice: "allow" | "deny") => {
      if (deciding.current || state.kind !== "decidable") return;
      deciding.current = true;
      const code = state.code;
      const issued = navigation.current;
      dispatch({ type: "decide", decision: choice });
      api.decideConnection(code, choice).then(
        (result) => {
          if (issued !== navigation.current) return;
          deciding.current = false;
          dispatch({ type: "decided", decision: result.decision, upgrade: result.upgrade, requesting: result.requesting });
        },
        (error: unknown) => {
          if (issued !== navigation.current) return;
          deciding.current = false;
          if (!guard.isActive()) return;
          const kind = failureKind(error);
          if (kind === "different_account") dispatch({ type: "wrong_account" });
          else if (kind === "invalid_grant") dispatch({ type: "invalid", message: EXPIRED });
          else if (kind === "csrf") inspect(code, "This page was out of date and has been refreshed. Check the details, then choose again.");
          else dispatch({ type: "uncertain" });
        },
      );
    },
    [api, guard, inspect, state],
  );

  const open = (code: string) => {
    window.history.pushState(null, "", `${CONNECT_PATH}?user_code=${encodeURIComponent(code)}`);
    inspect(code);
  };

  if (guardState.status !== "active") return <LockedScreen reason={guardState.status} classicLibrary={null} />;

  return (
    <AuthFrame>
      <ConnectBody state={state} accountName={accountName} onOpen={open} onDecide={decide} onCheck={(code) => inspect(code)} onSwitch={() => void go?.signOut()} />
    </AuthFrame>
  );
}

function failureMessage(error: unknown): string {
  if (!isApiError(error)) return "Something went wrong while checking the code.";
  switch (error.kind) {
    case "network":
      return "Could not reach the server. Check your connection, then try again. Nothing was changed.";
    case "busy":
      return "The server is busy. Try again in a moment. Nothing was changed.";
    case "not_found":
      return "These screens are not switched on for this server or account.";
    default:
      return "The server had a problem checking the code. Try again in a moment. Nothing was changed.";
  }
}

type BodyProps = {
  state: ConnectState;
  accountName: string | null;
  onOpen: (code: string) => void;
  onDecide: (choice: "allow" | "deny") => void;
  onCheck: (code: string) => void;
  onSwitch: () => void;
};

function Heading({ children }: { children: string }) {
  useDocumentTitle(children);
  return (
    <PageHeading key={children} id="connect-heading">
      {children}
    </PageHeading>
  );
}

function ConnectBody({ state, accountName, onOpen, onDecide, onCheck, onSwitch }: BodyProps) {
  const name = accountName ?? "this account";
  switch (state.kind) {
    case "entry":
      return (
        <section className="auth-card" aria-labelledby="connect-heading">
          <Heading>Connect your Shelfarr app</Heading>
          <CodeForm onOpen={onOpen} notice={state.notice} />
        </section>
      );
    case "inspecting":
      return (
        <section className="auth-card" aria-busy="true">
          <Heading>Checking the code</Heading>
          <p className="state state--loading" role="status">
            <span className="spinner" aria-hidden="true" />
            Checking the code…
          </p>
        </section>
      );
    case "failed":
      return (
        <section className="auth-card">
          <Heading>Could not check the code</Heading>
          <p className="form-error" role="alert">
            {state.message}
          </p>
          <div className="state-actions">
            <button type="button" className="button button--primary" onClick={() => onCheck(state.code)}>
              Try again
            </button>
          </div>
        </section>
      );
    case "invalid":
      return (
        <section className="auth-card">
          <Heading>This code cannot be used</Heading>
          <p className="lede">{state.message}</p>
          <p className="muted">Codes expire after ten minutes. If you already chose Allow or Not now, open the app to see the result.</p>
          <CodeForm onOpen={onOpen} notice={null} initial="" />
        </section>
      );
    case "wrong_account":
      return (
        <section className="auth-card">
          <Heading>Different account</Heading>
          <p className="lede" data-consumer-approval="wrong-account">
            This code belongs to an app that is connected to a different Shelfarr account, so <strong>{name}</strong> can't approve it.
          </p>
          <p className="muted">Sign out, sign in with the account the app uses, and this same code will be checked again. Nothing has changed for either account.</p>
          <div className="state-actions">
            <button type="button" className="button button--primary" onClick={onSwitch}>
              Sign out and switch account
            </button>
          </div>
        </section>
      );
    case "decidable":
    case "deciding":
    case "uncertain":
      return <Consent state={state} name={name} onDecide={onDecide} onCheck={onCheck} />;
    case "done":
      return <Done state={state} />;
  }
}

function CodeForm({ onOpen, notice, initial = "" }: { onOpen: (code: string) => void; notice: string | null; initial?: string }) {
  const id = useId();
  const [empty, setEmpty] = useState(false);
  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const value = new FormData(event.currentTarget).get("user_code");
    const code = typeof value === "string" ? [...value.trim()].slice(0, MAX_CODE_CHARACTERS).join("") : "";
    if (code === "") {
      setEmpty(true);
      return;
    }
    setEmpty(false);
    onOpen(code);
  }
  return (
    <form className="auth-form" method="get" onSubmit={submit}>
      <p className="lede">Enter the code displayed in your Shelfarr app. Codes expire after ten minutes.</p>
      {notice ? (
        <p className="notice" role="status">
          {notice}
        </p>
      ) : null}
      <div className="field">
        <label htmlFor={id}>Connection code</label>
        <input
          id={id}
          name="user_code"
          type="text"
          defaultValue={initial}
          autoComplete="off"
          autoCapitalize="characters"
          autoCorrect="off"
          spellCheck={false}
          enterKeyHint="go"
          required
          aria-invalid={empty}
          className="code-input"
        />
      </div>
      <button type="submit" className="button button--primary button--large">
        Check code
      </button>
    </form>
  );
}

function Consent({ state, name, onDecide, onCheck }: { state: Extract<ConnectState, { kind: "decidable" | "deciding" | "uncertain" }>; name: string; onDecide: (choice: "allow" | "deny") => void; onCheck: (code: string) => void }) {
  const { grant, code } = state;
  const busy = state.kind === "deciding";
  const uncertain = state.kind === "uncertain";
  const allowLabel = grant.upgrade ? "Allow requesting" : grant.requesting ? "Connect and allow requesting" : "Connect app";
  const denyLabel = grant.upgrade ? "Not now" : "Deny";
  const title = grant.upgrade ? "Allow requesting from your app" : "Connect your Shelfarr app";
  return (
    <section className="auth-card" aria-labelledby="connect-heading" aria-busy={busy}>
      <Heading>{title}</Heading>
      {grant.upgrade ? (
        <p className="lede">
          <strong className="client-name">{grant.clientName}</strong>, already connected as <strong>{name}</strong>, is asking to also request books.
        </p>
      ) : (
        <p className="lede">
          <strong className="client-name">{grant.clientName}</strong> is asking to connect as <strong>{name}</strong>.
        </p>
      )}
      <p className="muted">Check that this code matches the one shown in the app you just opened:</p>
      <p className="user-code" aria-label={`Code ${[...code.toUpperCase()].join(" ")}`}>
        {code.toUpperCase()}
      </p>
      <div className="permissions" data-consumer-approval={grant.requesting ? "requesting" : "base"}>
        <p className="permissions-title">If you allow it, the app can:</p>
        <ul>
          {grant.scopes.map((scope) => (
            <li key={scope}>{SCOPE_TEXT[scope] ?? `Use the “${scope}” permission.`}</li>
          ))}
        </ul>
        {grant.requesting ? (
          <p className="muted">It cannot see other people's requests, manage users or change server settings. You can revoke it from your Account page in the classic app.</p>
        ) : (
          <p className="muted">It cannot request books or manage your server. You can revoke it from your Account page in the classic app.</p>
        )}
        {grant.upgrade ? <p className="muted">If you choose Not now, the app keeps its current read-and-listen access.</p> : null}
        {grant.expiresAt ? <p className="muted">This code expires at {new Date(grant.expiresAt).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}.</p> : null}
      </div>
      <p className="warning">Only approve a connection you started yourself. Do not approve a code someone sent you.</p>
      {uncertain ? (
        <div className="form-error" role="alert">
          <p>We could not confirm whether your choice reached the server. Nothing was sent again.</p>
          <button type="button" className="button" onClick={() => onCheck(code)}>
            Check the code's status
          </button>
        </div>
      ) : (
        <div className="state-actions consent-actions">
          <button type="button" className="button button--primary button--large" disabled={busy} onClick={() => onDecide("allow")}>
            {busy && state.decision === "allow" ? "Saving…" : allowLabel}
          </button>
          <button type="button" className="button button--large" disabled={busy} onClick={() => onDecide("deny")}>
            {busy && state.decision === "deny" ? "Saving…" : denyLabel}
          </button>
        </div>
      )}
      {state.kind === "decidable" && state.notice ? (
        <p className="notice" role="status">
          {state.notice}
        </p>
      ) : null}
    </section>
  );
}

function Done({ state }: { state: Extract<ConnectState, { kind: "done" }> }) {
  const allowed = state.decision === "allowed";
  let title: string;
  let body: string;
  if (allowed && state.upgrade) {
    title = "Requesting allowed";
    body = "Return to the Shelfarr app. It can now find and request books for you; your downloads and saved places are unchanged.";
  } else if (allowed) {
    title = "App connected";
    body = state.requesting ? "Return to the Shelfarr app to open your library and request books." : "Return to the Shelfarr app to open your library.";
  } else if (state.upgrade) {
    title = "Requesting not allowed";
    body = "The app keeps its current read-and-listen access and cannot request books.";
  } else {
    title = "Connection denied";
    body = "The app was not granted access to your account.";
  }
  return (
    <section className="auth-card" role="status">
      <Heading>{title}</Heading>
      <p className="lede">{body}</p>
    </section>
  );
}
