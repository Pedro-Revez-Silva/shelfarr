import { Link, useLocation } from "@tanstack/react-router";
import { useEffect, useId, useRef, useState, type FormEvent, type ReactNode } from "react";
import { ErrorPanel, Loading } from "../../components/States";
import { Time } from "../../components/requestText";
import { ConfirmAction } from "../../devices/kobo/KoboParts";
import { useFocusStaysInCard } from "../../devices/kobo-accounts/focus";
import { Said, useSay } from "../../server/extras";
import { useServices } from "../../services";
import * as api from "./api";
import type { HardcoverConnection, HardcoverDevice, HardcoverState } from "./contract";
import { external, hardcoverFailure, useCodePoll, useHardcover, useHardcoverBusy, useHardcoverWrite, useHardcoverWriting, type CodeOutcome } from "./queries";
import "./hardcover.css";

type Say = (tone: "success" | "error", text: string) => void;

const UNCONFIRMED = "Shelfarr could not confirm whether your Hardcover connection changed. The card shows its current state.";

function useFocusOnHash(target: string, ready: boolean) {
  const section = useRef<HTMLElement>(null);
  const hash = useLocation({ select: (location) => location.hash });
  useEffect(() => {
    if (hash !== target || !ready) return;
    section.current?.scrollIntoView({ block: "start" });
    section.current?.focus({ preventScroll: true });
  }, [hash, ready, target]);
  return section;
}

export function HardcoverCard({ admin }: { admin: boolean }) {
  const headingId = useId();
  const hardcover = useHardcover();
  const section = useFocusOnHash("hardcover", hardcover.data !== undefined);
  const heading = useRef<HTMLHeadingElement>(null);
  useFocusStaysInCard(section, heading, `${hardcover.data?.connection?.version ?? ""}:${hardcover.data?.device?.user_code ?? ""}`);
  const { said, say } = useSay();
  const outcome = hardcover.data?.outcome;
  const sayRef = useRef(say);
  sayRef.current = say;
  useEffect(() => {
    if (outcome) sayRef.current(outcome.tone, outcome.message);
  }, [outcome]);
  return (
    <section ref={section} id="hardcover" className="account-card" aria-labelledby={headingId} tabIndex={-1}>
      <h2 id={headingId} ref={heading} tabIndex={-1}>
        Hardcover
      </h2>
      <p className="muted">
        Connect your own Hardcover account to see your Want to Read shelf and lists, choose books to request, and optionally request new additions automatically. Shelfarr only reads from Hardcover; it never changes your Hardcover library.
      </p>
      {hardcover.data ? (
        <HardcoverBody state={hardcover.data} admin={admin} say={say} />
      ) : hardcover.isError ? (
        <ErrorPanel error={hardcover.error} onRetry={() => void hardcover.refetch()} />
      ) : (
        <Loading label="Loading your Hardcover connection…" />
      )}
      <Said said={said} />
    </section>
  );
}

function HardcoverBody({ state, admin, say }: { state: HardcoverState; admin: boolean; say: Say }) {
  if (!state.enabled) return <p>Hardcover is disabled on this Shelfarr instance.</p>;
  const connection = state.connection;
  const canConnect = state.methods.sign_in || state.methods.api_key;
  const needsConnecting = connection === null || connection.state === "needs_reconnecting";
  return (
    <>
      {connection ? <Connected connection={connection} following={state.links.following} say={say} /> : <p>No Hardcover account is connected.</p>}
      {needsConnecting ? (
        canConnect ? (
          <Connect state={state} version={connection?.version ?? null} say={say} />
        ) : (
          <NotOffered admin={admin} />
        )
      ) : null}
    </>
  );
}

function NotOffered({ admin }: { admin: boolean }) {
  if (!admin) return <p className="muted">An administrator has not enabled Hardcover account connections yet.</p>;
  return (
    <p className="muted">
      To let people connect, register a Hardcover developer app and add its client ID in{" "}
      <Link to="/server/$category" params={{ category: "sources" }} hash="hardcover_accounts">
        Server ▸ Catalogues and sources
      </Link>
      .
    </p>
  );
}

function Connected({ connection, following, say }: { connection: HardcoverConnection; following: string; say: Say }) {
  const { api: client } = useServices();
  const busy = useHardcoverBusy();
  const writing = useHardcoverWriting();
  const remove = useHardcoverWrite((version: string) => api.disconnect(client, version));
  const confirm = (version: string) => {
    if (writing()) return;
    remove.mutate(version, {
      onSuccess: (answer) => say(answer.kind === "done" ? "success" : "error", answer.kind === "done" ? (answer.notice ?? "Hardcover account disconnected.") : answer.message),
      onError: (error) => say("error", hardcoverFailure(error, UNCONFIRMED)),
    });
  };
  const active = connection.state === "active";
  return (
    <div className="hardcover-connection">
      <p className="hardcover-break">
        Connected as{" "}
        {connection.profile_url ? (
          <a href={connection.profile_url} target="_blank" rel="noopener noreferrer">
            @{connection.username}
            <span className="sr-only"> (opens Hardcover in a new tab)</span>
          </a>
        ) : (
          `@${connection.username}`
        )}
      </p>
      <p className="request-meta">
        <span>{connection.method === "sign_in" ? "Signed in with Hardcover" : "Personal API key"}</span>
        <span>{active ? "Active" : "Needs reconnecting"}</span>
      </p>
      {!active && connection.problem ? <p className="form-error hardcover-break">{connection.problem}</p> : null}
      <div className="form-actions">
        <a className="button" href={following}>
          Following and reading lists
        </a>
        <ConfirmAction
          label="Disconnect Hardcover"
          question="Disconnect Hardcover? Want to Read automation stops. Requests already created are kept."
          confirmLabel="Disconnect"
          busy={busy}
          danger
          subject={connection.version}
          onConfirm={confirm}
        />
      </div>
    </div>
  );
}

function Connect({ state, version, say }: { state: HardcoverState; version: string | null; say: Say }) {
  return (
    <div className="hardcover-connect">
      {state.device ? <CodePanel device={state.device} say={say} /> : state.methods.sign_in ? <SignIn code={state.methods.code} version={version} say={say} /> : null}
      {state.methods.api_key ? <ApiKeyForm open={!state.methods.sign_in} page={state.links.api_key_page ?? null} version={version} say={say} /> : null}
    </div>
  );
}

function SignIn({ code, version, say }: { code: boolean; version: string | null; say: Say }) {
  const { api: client } = useServices();
  const busy = useHardcoverBusy();
  const writing = useHardcoverWriting();
  const [leaving, setLeaving] = useState(false);
  useEffect(() => {
    const returned = (event: PageTransitionEvent) => {
      if (event.persisted) setLeaving(false);
    };
    window.addEventListener("pageshow", returned);
    return () => window.removeEventListener("pageshow", returned);
  }, []);
  const authorize = useHardcoverWrite((expected: string | null) => api.authorize(client, expected));
  const startCode = useHardcoverWrite((expected: string | null) => api.startCode(client, expected));
  const signIn = () => {
    if (writing() || leaving) return;
    authorize.mutate(version, {
      onSuccess: (answer) => {
        if (answer.kind === "refused") return say("error", answer.message);
        if (external.open(answer.url)) setLeaving(true);
        else say("error", "Shelfarr was given a sign-in address outside Hardcover, so it did not open it. Nothing was changed.");
      },
      onError: (error) => say("error", hardcoverFailure(error, "Shelfarr could not start Hardcover sign-in. Try again.")),
    });
  };
  const withCode = () => {
    if (writing() || leaving) return;
    startCode.mutate(version, {
      onSuccess: (answer) => {
        if (answer.kind === "refused") say("error", answer.message);
      },
      onError: (error) => say("error", hardcoverFailure(error, "Shelfarr could not confirm whether a sign-in code was created. The card shows its current state.")),
    });
  };
  return (
    <>
      <div className="form-actions">
        <button type="button" className="button button--primary" aria-disabled={busy || leaving ? true : undefined} aria-busy={authorize.isPending || leaving} onClick={signIn}>
          {leaving ? "Opening Hardcover…" : "Sign in with Hardcover"}
        </button>
        {code ? (
          <button type="button" className="button" aria-disabled={busy || leaving ? true : undefined} aria-busy={startCode.isPending} onClick={withCode}>
            {startCode.isPending ? "Asking Hardcover for a code…" : "Sign in with a code"}
          </button>
        ) : null}
      </div>
      <p className="muted">Shelfarr asks Hardcover for read-only access to your profile, library, lists, and the catalog. You come back here when Hardcover is done.</p>
    </>
  );
}

function CodePanel({ device, say }: { device: HardcoverDevice; say: Say }) {
  const headingId = useId();
  const { api: client } = useServices();
  const busy = useHardcoverBusy();
  const writing = useHardcoverWriting();
  const heading = useRef<HTMLHeadingElement>(null);
  const ended = (outcome: CodeOutcome) => say(outcome.tone, outcome.message);
  const poll = useCodePoll(device, ended);
  const cancel = useHardcoverWrite(() => api.cancelCode(client, device.user_code));
  useEffect(() => {
    if (document.activeElement === null || document.activeElement === document.body) heading.current?.focus();
  }, [device.user_code]);
  const page = device.verification_uri_complete ?? device.verification_uri;
  return (
    <section className="hardcover-code" aria-labelledby={headingId}>
      <h3 id={headingId} ref={heading} tabIndex={-1}>
        Sign in with a code
      </h3>
      <ol>
        <li>
          Open{" "}
          <a href={page} target="_blank" rel="noopener noreferrer">
            {device.verification_uri}
            <span className="sr-only"> (opens Hardcover in a new tab)</span>
          </a>{" "}
          on any device.
        </li>
        <li>Enter this code and approve Shelfarr:</li>
      </ol>
      <p className="hardcover-user-code" aria-label={`Sign-in code ${[...device.user_code].join(" ")}`}>
        {device.user_code}
      </p>
      <p className="muted">
        This page continues by itself. The code expires <Time iso={device.expires_at} relative />.
      </p>
      <p role="status">{poll.problem ?? "Waiting for approval on Hardcover…"}</p>
      <div className="form-actions">
        <button type="button" className="button" aria-disabled={poll.checking || busy ? true : undefined} aria-busy={poll.checking} onClick={() => (poll.checking || busy ? undefined : poll.check())}>
          {poll.checking ? "Checking…" : "I've approved it"}
        </button>
        <button
          type="button"
          className="button button--subtle"
          aria-disabled={busy ? true : undefined}
          onClick={() => {
            if (writing()) return;
            cancel.mutate(undefined, { onError: (error) => say("error", hardcoverFailure(error, UNCONFIRMED)) });
          }}
        >
          Cancel
        </button>
      </div>
    </section>
  );
}

function ApiKeyForm({ open, page, version, say }: { open: boolean; page: string | null; version: string | null; say: Say }) {
  const ids = { key: useId(), help: useId(), error: useId() };
  const { api: client } = useServices();
  const busy = useHardcoverBusy();
  const writing = useHardcoverWriting();
  const input = useRef<HTMLInputElement>(null);
  const [key, setKey] = useState("");
  const [missing, setMissing] = useState(false);
  const submitted = useRef("");
  const connect = useHardcoverWrite((expected: string | null) => {
    const value = submitted.current;
    submitted.current = "";
    return api.connectApiKey(client, value, expected);
  });
  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (writing()) return;
    const value = key.trim();
    if (value === "") {
      setMissing(true);
      input.current?.focus();
      return;
    }
    submitted.current = value;
    connect.mutate(version, {
        onSuccess: (answer) => say(answer.kind === "done" ? "success" : "error", answer.kind === "done" ? (answer.notice ?? "Hardcover account connected.") : answer.message),
        onError: (error) => say("error", hardcoverFailure(error, UNCONFIRMED)),
      onSettled: () => setKey(""),
    });
  };
  return (
    <details className="hardcover-key" open={open}>
      <summary>Connect with a personal API key</summary>
      <p id={ids.help} className="muted">
        <KeyPageLink page={page}>Create a Hardcover API key</KeyPageLink> with read:me:content, read:library, read:lists, and read:catalog, then paste it here. Shelfarr encrypts it and never shows it again. Revoke it on Hardcover's API page at any time.
      </p>
      <form className="account-form" noValidate onSubmit={submit}>
        <div className="field">
          <label htmlFor={ids.key}>Hardcover API key</label>
          <input
            ref={input}
            id={ids.key}
            name="api_key"
            type="password"
            autoComplete="off"
            spellCheck={false}
            autoCapitalize="none"
            maxLength={2000}
            required
            value={key}
            aria-invalid={missing}
            aria-describedby={missing ? `${ids.help} ${ids.error}` : ids.help}
            onChange={(event) => {
              setKey(event.target.value);
              setMissing(false);
            }}
          />
          {missing ? (
            <p id={ids.error} className="field-error">
              <span aria-hidden="true">⚠ </span>Paste a Hardcover API key to connect.
            </p>
          ) : null}
        </div>
        <div className="form-actions">
          <button type="submit" className="button button--primary" aria-disabled={busy ? true : undefined} aria-busy={connect.isPending}>
            {connect.isPending ? "Checking the key with Hardcover…" : "Connect"}
          </button>
        </div>
      </form>
    </details>
  );
}

function KeyPageLink({ page, children }: { page: string | null; children: ReactNode }) {
  if (!page) return <>{children}</>;
  return (
    <a href={page} target="_blank" rel="noopener noreferrer">
      {children}
      <span className="sr-only"> (opens Hardcover in a new tab)</span>
    </a>
  );
}
