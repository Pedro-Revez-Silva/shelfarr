import { getRouteApi, Link } from "@tanstack/react-router";
import { useEffect, useId, useRef, useState, type FormEvent } from "react";
import { PageHeading } from "../../components/PageHeading";
import { AccountRail } from "../../components/PersonalSettings";
import { Time } from "../../components/requestText";
import { EmptyState, ErrorPanel, Loading } from "../../components/States";
import { Said, useSay } from "../../server/extras";
import { useServices } from "../../services";
import { useDocumentTitle } from "../../title";
import { ConfirmAction } from "../kobo/KoboParts";
import * as api from "./api";
import type { CatalogueSearch, KoboAccount } from "./contract";
import { CatalogueCard } from "./KoboCatalogue";
import { isMissing, koboAccountFailure, useAccountBusy, useAccountWrite, useActivationPoll, useCatalogueFollowsRefresh, useKoboAccount, useKoboAccountKeys, usePublishAccount } from "./queries";
import "./kobo-accounts.css";

const routeApi = getRouteApi("/account/devices/kobo-accounts/$accountId");

export function KoboAccountPage() {
  const { accountId } = routeApi.useParams();
  const search = routeApi.useSearch();
  return <AccountPage key={accountId} accountId={accountId} search={search} />;
}

export function DevicesBackLink({ hash }: { hash: string }) {
  return (
    <p className="people-back">
      <Link to="/account/$section" params={{ section: "devices" }} hash={hash}>
        <span aria-hidden="true">← </span>Devices
      </Link>
    </p>
  );
}

function AccountPage({ accountId, search }: { accountId: string; search: CatalogueSearch }) {
  const { mode } = useServices();
  const account = useKoboAccount(accountId);
  const [disconnected, setDisconnected] = useState<string | null>(null);
  useCatalogueFollowsRefresh(account.data);
  useDocumentTitle(account.data?.name ? `${account.data.name} · Devices` : "Kobo account · Devices");
  const missing = account.isError && isMissing(account.error);
  const heading = disconnected ? "Kobo account disconnected" : missing ? "Kobo account" : (account.data?.name ?? (account.isError ? "Kobo account" : "Loading account"));
  return (
    <section className="account kobo-account" aria-labelledby="kobo-account-heading">
      <DevicesBackLink hash="kobo-accounts" />
      <PageHeading id="kobo-account-heading">{heading}</PageHeading>
      <p className="lede">Only you see and change these.</p>
      <AccountRail current="devices" />
      {mode !== "rails" ? (
        <EmptyState title="Kobo accounts are not available here">
          <p>This server does not manage Kobo accounts. Nothing was changed.</p>
        </EmptyState>
      ) : disconnected ? (
        <div className="account-card" role="status">
          <p>{disconnected}</p>
          <p>
            <Link to="/account/$section" params={{ section: "devices" }} hash="kobo-accounts">
              Back to Devices
            </Link>
          </p>
        </div>
      ) : missing ? (
        <EmptyState title="This Kobo account is not connected to your account">
          <p>It may have been disconnected, or it belongs to someone else. Each person manages only their own Kobo connections.</p>
          <Link to="/account/$section" params={{ section: "devices" }} hash="kobo-accounts" className="button">
            Your devices
          </Link>
        </EmptyState>
      ) : account.data ? (
        <AccountView account={account.data} search={search} onDisconnected={setDisconnected} />
      ) : account.isError ? (
        <ErrorPanel error={account.error} onRetry={() => void account.refetch()} />
      ) : (
        <Loading label="Loading this Kobo account…" />
      )}
    </section>
  );
}

function AccountView({ account, search, onDisconnected }: { account: KoboAccount; search: CatalogueSearch; onDisconnected: (notice: string) => void }) {
  const linked = account.state === "connected" || account.state === "reauthorization_required";
  return (
    <div className="account-sections">
      <p className="muted">{account.shared_with === 0 ? "Private to your Shelfarr user" : `Shared with ${account.shared_with} ${account.shared_with === 1 ? "person" : "people"} in your household`}</p>
      {account.error ? (
        <p role="alert" className="kobo-tone kobo-tone--warning">
          {account.error}
        </p>
      ) : null}
      {account.state === "pending" ? <Activation account={account} /> : null}
      {linked ? (
        <>
          <Connection account={account} />
          <Sharing account={account} />
          <CatalogueCard accountId={account.id} search={search} route="/account/devices/kobo-accounts/$accountId" />
        </>
      ) : null}
      {account.state === "incomplete" ? (
        <div className="account-card">
          <p>
            This connection did not complete. Return to{" "}
            <Link to="/account/$section" params={{ section: "devices" }} hash="kobo-accounts">
              Devices
            </Link>{" "}
            to start a new connection.
          </p>
        </div>
      ) : null}
      <Disconnect account={account} onDisconnected={onDisconnected} />
    </div>
  );
}

function Activation({ account }: { account: KoboAccount }) {
  const headingId = useId();
  const poller = useActivationPoll(account);
  const activation = account.activation;
  const heading = useRef<HTMLHeadingElement>(null);
  useEffect(() => {
    if (poller.ended && (document.activeElement === null || document.activeElement === document.body)) heading.current?.focus();
  }, [poller.ended]);
  if (!activation) return null;
  const ended = poller.ended;
  return (
    <section className="account-card" aria-labelledby={headingId}>
      <h2 id={headingId} ref={heading} tabIndex={-1}>
        {ended ? "Approval can't continue here" : "Approve this connection on Kobo"}
      </h2>
      {ended ? null : <p>Open Kobo's activation page, sign in to the account you want to connect, and enter this code:</p>}
      {ended ? null : (
        <p className="kobo-activation-code" data-testid="kobo-activation-code">
          {activation.code}
        </p>
      )}
      {ended ? null : (
        <p>
          <a className="button button--primary" href={activation.page} target="_blank" rel="noopener noreferrer">
            Open Kobo activation<span className="sr-only"> (opens in a new tab)</span>
          </a>
        </p>
      )}
      {ended ? null : (
        <p className="muted">
          Return here after approving. This code expires <Time iso={activation.expires_at} relative />. Keep it private.
        </p>
      )}
      <p role="status">{poller.problem ?? "Waiting for approval…"}</p>
      {ended ? null : (
        <div className="form-actions">
          <button type="button" className="button" aria-disabled={poller.checking ? true : undefined} aria-busy={poller.checking} onClick={() => (poller.checking ? undefined : poller.check())}>
            {poller.checking ? "Checking…" : "Check connection"}
          </button>
        </div>
      )}
    </section>
  );
}

function Connection({ account }: { account: KoboAccount }) {
  const headingId = useId();
  const { api: client } = useServices();
  const { said, say } = useSay();
  const refresh = useAccountWrite(account.id, () => api.refresh(client, account.id));
  const busy = useAccountBusy(account.id);
  const start = () => {
    if (busy) return;
    refresh.mutate(undefined, {
      onSuccess: (answer) => say(answer.kind === "done" ? "success" : "error", answer.kind === "done" ? (answer.notice ?? "Catalogue refresh queued.") : answer.message),
      onError: (error) => say("error", koboAccountFailure(error, "Shelfarr could not confirm whether a refresh was queued. The page shows the current state.")),
    });
  };
  return (
    <section className="account-card" aria-labelledby={headingId}>
      <h2 id={headingId}>{account.state === "connected" ? "Connected to Kobo" : "Kobo sign-in required"}</h2>
      {account.kobo_email ? <p className="kobo-break">Account: {account.kobo_email}</p> : null}
      <p className="muted">
        Check that this is the account you intended to connect. Only you and people you share it with below can see its catalogue, and only you can see this sign-in. Book files are copied only when someone prepares a DRM-free title.
      </p>
      {account.refreshing ? (
        <p role="status" className="kobo-progress">
          Refreshing your catalogue… This page will update when it finishes.
        </p>
      ) : account.can_refresh ? (
        <div className="form-actions">
          <button type="button" className="button button--primary" aria-disabled={busy ? true : undefined} aria-busy={refresh.isPending} onClick={start}>
            {refresh.isPending ? "Queuing…" : "Refresh catalogue"}
          </button>
        </div>
      ) : null}
      {account.last_synced_at ? (
        <p className="muted">
          Last refreshed <Time iso={account.last_synced_at} relative />.
        </p>
      ) : null}
      <Said said={said} />
    </section>
  );
}

function Sharing({ account }: { account: KoboAccount }) {
  const headingId = useId();
  const ids = { select: useId(), error: useId() };
  const { api: client } = useServices();
  const { said, say } = useSay();
  const select = useRef<HTMLSelectElement>(null);
  const heading = useRef<HTMLHeadingElement>(null);
  const people = (account.sharing?.people ?? []).map((person) => person.id).join(" ");
  const shownPeople = useRef(people);
  useEffect(() => {
    const now = new Set(people.split(" "));
    const removed = shownPeople.current.split(" ").some((id) => id !== "" && !now.has(id));
    shownPeople.current = people;
    if (removed && (document.activeElement === null || document.activeElement === document.body)) heading.current?.focus();
  }, [people]);
  const [recipient, setRecipient] = useState("");
  const [missing, setMissing] = useState(false);
  const add = useAccountWrite(account.id, (recipientId: string) => api.share(client, account.id, recipientId));
  const remove = useAccountWrite(account.id, (shareId: string) => api.stopSharing(client, account.id, shareId));
  const sharing = account.sharing;
  const busy = useAccountBusy(account.id);
  if (!sharing) return null;
  const settle = (fallback: string) => ({
    onSuccess: (answer: api.AccountAnswer) => say(answer.kind === "done" ? "success" : "error", answer.kind === "done" ? (answer.notice ?? fallback) : answer.message),
    onError: (error: unknown) => say("error", koboAccountFailure(error, "Shelfarr could not confirm the change. The page shows the current sharing.")),
  });
  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (busy) return;
    if (!sharing.candidates.some((candidate) => candidate.id === recipient)) {
      setMissing(true);
      select.current?.focus();
      return;
    }
    add.mutate(recipient, {
      ...settle("Shared."),
      onSuccess: (answer) => {
        if (answer.kind === "done") setRecipient("");
        settle("Shared.").onSuccess(answer);
      },
    });
  };
  return (
    <section id="sharing" className="account-card" aria-labelledby={headingId}>
      <h2 id={headingId} ref={heading} tabIndex={-1}>
        Household sharing
      </h2>
      <p className="muted">
        {sharing.people.length === 0 ? "Only you can see this catalogue." : "You and the people below can see this catalogue."} People you share with can send its DRM-free purchases to their own Kobo reader. They never see your Kobo sign-in or email, can't change this connection, and can't reach your readers. Protected, subscription and preview titles stay listed as unavailable.
      </p>
      {sharing.people.length ? (
        <ul className="kobo-reader-list">
          {sharing.people.map((person) => (
            <li key={person.id} data-testid="kobo-share" className="kobo-row">
              <div className="kobo-delivery-text">
                <p>
                  {person.name} <span className="muted">({person.username})</span>
                </p>
                <p className="request-meta">
                  <span>
                    Shared <Time iso={person.shared_at} relative />
                  </span>
                  {person.inactive ? <span>account no longer active</span> : null}
                </p>
              </div>
              <ConfirmAction
                label={
                  <>
                    Stop sharing<span className="sr-only"> with {person.name}</span>
                  </>
                }
                question={`Stop sharing with ${person.name}? Shelfarr stops offering these books to their readers. Copies already downloaded stay on their Kobo.`}
                confirmLabel="Stop sharing"
                busy={busy}
                danger
                subject={person.id}
                onConfirm={(shareId) =>
                  remove.mutate(shareId, settle("Sharing stopped."))
                }
              />
            </li>
          ))}
        </ul>
      ) : null}
      {sharing.candidates.length ? (
        <form className="account-form kobo-share-form" method="post" noValidate onSubmit={submit}>
          <div className="field">
            <label htmlFor={ids.select}>Share with</label>
            <select
              ref={select}
              id={ids.select}
              required
              value={recipient}
              aria-invalid={missing}
              aria-describedby={missing ? ids.error : undefined}
              onChange={(event) => {
                setRecipient(event.target.value);
                setMissing(false);
              }}
            >
              <option value="" disabled>
                Choose a person
              </option>
              {sharing.candidates.map((candidate) => (
                <option key={candidate.id} value={candidate.id}>
                  {candidate.label}
                </option>
              ))}
            </select>
            {missing ? (
              <p id={ids.error} className="field-error">
                <span aria-hidden="true">⚠ </span>Choose someone to share with.
              </p>
            ) : null}
          </div>
          <div className="form-actions">
            <button type="submit" className="button button--primary" aria-disabled={busy ? true : undefined} aria-busy={add.isPending}>
              {add.isPending ? "Sharing…" : "Share catalogue"}
            </button>
          </div>
        </form>
      ) : (
        <p className="muted">There are no other Shelfarr users to share with{sharing.people.length ? " who don't already have access" : ""}.</p>
      )}
      <Said said={said} />
    </section>
  );
}

function Disconnect({ account, onDisconnected }: { account: KoboAccount; onDisconnected: (notice: string) => void }) {
  const headingId = useId();
  const { api: client } = useServices();
  const publish = usePublishAccount();
  const keys = useKoboAccountKeys();
  const writing = useAccountBusy(account.id);
  const { said, say } = useSay();
  const [busy, setBusy] = useState(false);
  const confirm = async (version: string) => {
    if (busy || writing) return;
    setBusy(true);
    try {
      const answer = await api.disconnect(client, account.id, version);
      if (!publish.active()) return;
      if (answer.kind === "disconnected") {
        publish.forget(account.id);
        onDisconnected(answer.notice);
        return;
      }
      publish.account(answer.kobo_account);
      publish.reread(keys.account(account.id));
      say("error", answer.message);
    } catch (error) {
      say("error", koboAccountFailure(error, "Shelfarr could not confirm whether the connection was removed. Reload the page to see its current state."));
    } finally {
      setBusy(false);
    }
  };
  return (
    <section className="account-card" aria-labelledby={headingId}>
      <h2 id={headingId}>Disconnect</h2>
      <p className="muted">
        Remove this connection's saved credentials, private catalogue, prepared copies and shares from Shelfarr. People you shared with stop receiving its books. This does not sign out or reset a physical Kobo, remove books already on readers, or revoke credentials at Kobo.
      </p>
      <div className="form-actions">
        <ConfirmAction label="Disconnect Kobo account" question="Remove this connection and its catalogue from Shelfarr?" confirmLabel="Disconnect" busy={busy || writing} danger subject={account.version} onConfirm={(version) => void confirm(version)} />
      </div>
      <Said said={said} />
    </section>
  );
}
