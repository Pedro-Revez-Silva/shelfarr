import { Link, useLocation, useNavigate } from "@tanstack/react-router";
import { useEffect, useId, useRef, useState, type FormEvent } from "react";
import { ErrorPanel, Loading } from "../../components/States";
import { useServices } from "../../services";
import * as api from "./api";
import type { KoboAccountRow, KoboAccounts, ReceivedCatalogue } from "./contract";
import { koboAccountFailure, useKoboAccounts, usePublishAccount } from "./queries";
import "./kobo-accounts.css";

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

export function KoboAccountsCard() {
  const headingId = useId();
  const accounts = useKoboAccounts();
  const section = useFocusOnHash("kobo-accounts", accounts.data !== undefined);
  return (
    <>
      <section ref={section} id="kobo-accounts" className="account-card" aria-labelledby={headingId} tabIndex={-1}>
        <h2 id={headingId}>Kobo accounts</h2>
        <p className="muted">Connect your Kobo Store account to see its books in Shelfarr. Each connection and its catalogue are private to you until you choose to share them with someone in your household.</p>
        <div className="kobo-preview-note" role="note">
          <p className="kobo-option-title">Household sharing preview</p>
          <p>Purchases that Kobo offers as DRM-free EPUBs can be sent to your own Kobo reader or to readers of people you share with. Protected purchases, Kobo Plus titles and previews can't be sent to another account's reader. Your physical Kobo and its settings stay unchanged.</p>
        </div>
        {accounts.data ? (
          <>
            <AccountList accounts={accounts.data.kobo_accounts} />
            <ConnectAccount defaults={accounts.data.new_account} />
          </>
        ) : accounts.isError ? (
          <ErrorPanel error={accounts.error} onRetry={() => void accounts.refetch()} />
        ) : (
          <Loading label="Loading your Kobo accounts…" />
        )}
      </section>
      {accounts.data ? <SharedWithYou received={accounts.data.received} /> : null}
    </>
  );
}

function sharingLine(row: KoboAccountRow): string {
  if (row.shared_with === 0) return "private catalogue";
  return `shared with ${row.shared_with} ${row.shared_with === 1 ? "person" : "people"}`;
}

function AccountList({ accounts }: { accounts: KoboAccountRow[] }) {
  if (accounts.length === 0) return <p>No Kobo account is connected yet.</p>;
  return (
    <ul className="kobo-reader-list">
      {accounts.map((row) => (
        <li key={row.id}>
          <p className="token-name">
            <Link to="/account/devices/kobo-accounts/$accountId" params={{ accountId: row.id }}>
              {row.name}
            </Link>
          </p>
          <p className="request-meta">
            <span>{row.status_label}</span>
            <span>{sharingLine(row)}</span>
          </p>
        </li>
      ))}
    </ul>
  );
}

function ConnectAccount({ defaults }: { defaults: KoboAccounts["new_account"] }) {
  const { api: client } = useServices();
  const publish = usePublishAccount();
  const navigate = useNavigate();
  const ids = { heading: useId(), name: useId(), help: useId(), error: useId() };
  const input = useRef<HTMLInputElement>(null);
  const sending = useRef(false);
  const mounted = useRef(true);
  const [name, setName] = useState(defaults.name);
  const [pending, setPending] = useState(false);
  const [missing, setMissing] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (sending.current) return;
    setProblem(null);
    if (name.trim() === "") {
      setMissing(true);
      input.current?.focus();
      return;
    }
    sending.current = true;
    setPending(true);
    try {
      const created = await api.connect(client, name);
      if (!mounted.current || !publish.active()) return;
      publish.account(created);
      void navigate({ to: "/account/devices/kobo-accounts/$accountId", params: { accountId: created.id } });
    } catch (error) {
      if (!mounted.current) return;
      setProblem(koboAccountFailure(error, "Shelfarr could not confirm whether the connection started. Check the list above before trying again."));
    } finally {
      sending.current = false;
      if (mounted.current) setPending(false);
    }
  }

  return (
    <section className="kobo-connect" aria-labelledby={ids.heading}>
      <h3 id={ids.heading}>Connect a Kobo account</h3>
      <p id={ids.help} className="muted">
        You will get a code to approve on Kobo's website. Shelfarr never asks for your Kobo password. Your server stores the resulting connection credentials encrypted.
      </p>
      <form className="account-form" method="post" noValidate aria-labelledby={ids.heading} onSubmit={(event) => void submit(event)}>
        <div className="field">
          <label htmlFor={ids.name}>Connection name</label>
          <input
            ref={input}
            id={ids.name}
            name="name"
            type="text"
            required
            maxLength={80}
            autoComplete="off"
            value={name}
            aria-invalid={missing}
            aria-describedby={missing ? `${ids.help} ${ids.error}` : ids.help}
            onChange={(event) => {
              setName(event.target.value);
              setMissing(false);
              setProblem(null);
            }}
          />
          {missing ? (
            <p id={ids.error} className="field-error">
              <span aria-hidden="true">⚠ </span>Enter a name for this connection.
            </p>
          ) : null}
        </div>
        <div className="form-actions">
          <button type="submit" className="button button--primary" disabled={pending} aria-busy={pending}>
            {pending ? "Asking Kobo for a code…" : "Connect Kobo account"}
          </button>
        </div>
        <div className="form-outcome" role="status">
          {problem ? <p className="form-error">{problem}</p> : null}
        </div>
      </form>
    </section>
  );
}

function SharedWithYou({ received }: { received: ReceivedCatalogue[] }) {
  const headingId = useId();
  const section = useFocusOnHash("kobo-shared", true);
  return (
    <section ref={section} id="kobo-shared" className="account-card" aria-labelledby={headingId} tabIndex={-1}>
      <h2 id={headingId}>Kobo books shared with you</h2>
      {received.length === 0 ? (
        <p className="muted">Nobody has shared a Kobo catalogue with you yet. The account owner can share one from their own Kobo account page in Shelfarr.</p>
      ) : (
        <>
          <p className="muted">Kobo catalogues that people in your household chose to share with you. You can send their DRM-free purchases to your own Kobo reader. You never see their Kobo sign-in, and nothing changes on their readers.</p>
          <ul className="kobo-reader-list">
            {received.map((entry) => (
              <li key={entry.id}>
                <p className="token-name">
                  <Link to="/account/devices/kobo-shared/$accountId" params={{ accountId: entry.id }}>
                    {entry.name}
                  </Link>
                </p>
                <p className="request-meta">
                  <span>Shared by {entry.owner_name}</span>
                  <span>
                    {entry.sendable_count} {entry.sendable_count === 1 ? "book" : "books"} can be sent
                  </span>
                </p>
              </li>
            ))}
          </ul>
        </>
      )}
    </section>
  );
}
