import { Link, useLocation, useNavigate, useSearch } from "@tanstack/react-router";
import { createContext, useContext, useEffect, useRef, useState, type FormEvent, type ReactNode } from "react";
import { failureKind } from "../../api/errors";
import { ErrorPanel, Loading } from "../../components/States";
import { Time } from "../../components/requestText";
import type { SettingField } from "../contract";
import type { DraftValue } from "../draft";
import { Said, useSay } from "../extras";
import { CardActions, SettingControl, SettingsCard, TestResult, useScope, type TestOutcome } from "../primitives";
import { CardBody, commandFailureText, FormProblem, focusSoon, useRevalidateAccessWhenDenied, type DirtyReporter } from "../downloads/DownloadManagement";
import { useAudible, useAudibleCommand, useCatalogue, type AudibleCommand, type CompanionValues } from "./api";
import { audibleSearchSchema, type Audible, type AudibleAction, type AudibleRejection, type Catalogue, type CatalogueItem } from "./contract";
import "./audible.css";

const CARD_ID = "audible";
export const AUDIBLE_CARDS = [{ id: CARD_ID, title: "Audible backup" }] as const;
const SECTION_IDS = ["audible-connection", "audible-account", "audible-sync", "audible-automation", "audible-catalogue"] as const;
const TOKEN_FILE_VARIABLE = "SHELFARR_LIBATION_TOKEN_FILE";

type SectionId = (typeof SECTION_IDS)[number];
type Outcome = { where: SectionId | null; said: ReturnType<typeof useSay>["said"] };
const OutcomeContext = createContext<Outcome | null>(null);

function outcomeSection(command: AudibleCommand, data: Audible | undefined): SectionId | null {
  switch (command.kind) {
    case "save":
      return "audible-connection";
    case "test":
      return null;
    case "start_sign_in":
    case "complete_sign_in":
      return "audible-account";
    case "sync":
    case "dismiss_existing":
      return "audible-sync";
    case "back_up_existing":
      return data?.existing_backup.prompt ? "audible-sync" : "audible-automation";
    case "automation":
      return "audible-automation";
    case "back_up_item":
      return "audible-catalogue";
  }
}

type Run = (command: AudibleCommand, then?: (action: AudibleAction) => void, rejected?: (errors: AudibleRejection) => void) => void;

const COMPANION_STATUS: Record<Audible["connection"]["status"], string> = { needs_setup: "Needs setup", ready: "Ready", busy: "Ready · Busy", unavailable: "Unavailable" };
const SIGN_IN_STATUS: Record<Audible["sign_in"]["state"], string> = { not_ready: "Set up the companion first", starting: "Starting sign-in", pending: "Finish sign-in", connected: "Connected", needs_sign_in: "Needs sign-in" };
const BACKUP_STATES: Record<CatalogueItem["state"], string> = {
  not_eligible: "Not eligible: subscription title",
  in_shelfarr: "In Shelfarr",
  on_server: "Already on this server",
  possible_match: "Possible match on this server",
  waiting: "Waiting in the existing-library batch",
  stalled: "No recent update",
  queued: "Queued",
  starting: "Starting",
  downloading: "Backing up",
  processing: "Importing",
  failed: "Backup failed",
  in_libation: "Backed up in Libation, ready to import",
  not_backed_up: "Not backed up",
};
const ORIGINS: Record<NonNullable<CatalogueItem["origin"]>, string> = { existing: "Existing-library backup", automatic: "Automatic backup", manual: "Backup" };
const OWNERSHIP: Record<CatalogueItem["ownership"], string> = { purchased: "Purchased", subscription: "Subscription", unknown: "Unknown" };

function bringIntoView(id: string) {
  const target = document.getElementById(id);
  const active = document.activeElement;
  if (!target || !(active === null || active === document.body || active === document.getElementById(CARD_ID))) return;
  target.scrollIntoView({ block: "start" });
  target.focus({ preventScroll: true });
}

function useArrival(ready: boolean) {
  const hash = useLocation({ select: (location) => location.hash });
  const handled = useRef<string | null>(null);
  useEffect(() => {
    if (!ready || !hash || handled.current === hash) return;
    if (hash !== CARD_ID && !(SECTION_IDS as readonly string[]).includes(hash)) return;
    handled.current = hash;
    requestAnimationFrame(() => bringIntoView(hash));
  }, [ready, hash]);
}

function countsText(counts: { status: string; count: number }[]): string {
  return counts.map((entry) => `${entry.count.toLocaleString("en")} ${entry.status}`).join(" · ");
}

function plural(count: number, word: string): string {
  return `${count.toLocaleString("en")} ${word}${count === 1 ? "" : "s"}`;
}

export function AudibleBackup({ onDirtyChange }: { onDirtyChange: DirtyReporter }) {
  const query = useAudible();
  const scope = useScope();
  const { said, say } = useSay();
  const command = useAudibleCommand();
  const denied = query.isError && failureKind(query.error) === "not_found";
  useRevalidateAccessWhenDenied(denied);
  useArrival(query.data !== undefined);
  const [where, setWhere] = useState<SectionId | null>(null);
  const run: Run = (next, then, rejected) => {
    if (command.isPending) return;
    setWhere(outcomeSection(next, query.data));
    command.mutate(next, {
      onSuccess: (answer) => {
        if (answer.kind === "rejected") {
          say("error", "Nothing was saved. Correct the highlighted fields and save again.");
          rejected?.(answer.errors);
          return;
        }
        say(answer.action.outcome.tone, answer.action.outcome.message);
        then?.(answer.action);
      },
      onError: (error) => {
        setWhere(outcomeSection(next, query.data) ?? "audible-connection");
        say("error", commandFailureText(error));
      },
    });
  };
  return (
    <SettingsCard
      id={CARD_ID}
      headingId={`${scope}-heading`}
      title="Audible backup"
      status={<span className="badge audible-beta">Beta</span>}
      summary="Keep personal backups of purchased Audible audiobooks through a Libation companion. Shelfarr never receives your Audible password."
    >
      <CardBody query={query} label="Loading Audible backup…" denied="Only administrators can manage Audible backup.">
        {(data) => (
          <OutcomeContext.Provider value={denied ? null : { where, said }}>
            <p className="field-warning audible-shared">
              <span aria-hidden="true">⚠ </span>Imported backups join this server's shared library and may be available to other people here. Only give library access to people allowed to use the connected account holder's purchases.
            </p>
            <AudibleStatus data={data} />
            <ConnectionSection data={data} run={run} busy={command.isPending} onDirtyChange={onDirtyChange} />
            <AccountSection data={data} run={run} busy={command.isPending} />
            <SyncSection data={data} run={run} busy={command.isPending} />
            <AutomationSection data={data} run={run} busy={command.isPending} onDirtyChange={onDirtyChange} />
            <CatalogueSection data={data} run={run} busy={command.isPending} />
            <p className="field-hint">
              Powered by{" "}
              <a href="https://github.com/rmcrackan/Libation" target="_blank" rel="noopener noreferrer">
                Libation<span className="sr-only"> (opens in a new tab)</span>
              </a>
              , an independent GPL-3.0 open-source project.
            </p>
          </OutcomeContext.Provider>
        )}
      </CardBody>
    </SettingsCard>
  );
}

function AudibleStatus({ data }: { data: Audible }) {
  const versions = data.connection.companion_version || data.connection.provider_version ? `Companion ${data.connection.companion_version ?? "unknown"} · Libation ${data.connection.provider_version ?? "unknown"}` : null;
  const signedIn = data.sign_in.accounts.filter((entry) => entry.authenticated).map((entry) => entry.label);
  return (
    <dl className="inventory-counts audible-status">
      <div>
        <dt>Libation companion</dt>
        <dd>
          <span className={`badge${data.connection.status === "unavailable" ? " badge--down" : data.connection.status === "needs_setup" ? "" : " badge--healthy"}`}>{COMPANION_STATUS[data.connection.status]}</span>
          {versions ? <span className="field-hint"> {versions}</span> : null}
        </dd>
      </div>
      <div>
        <dt>Audible account</dt>
        <dd>
          <span className={`badge${data.sign_in.state === "connected" ? " badge--healthy" : ""}`}>{SIGN_IN_STATUS[data.sign_in.state]}</span>
          {signedIn.length > 0 ? <span className="field-hint"> {signedIn.join(", ")}</span> : data.sign_in.accounts_paused ? <span className="field-hint"> Account details are paused while Libation works.</span> : null}
        </dd>
      </div>
      <div>
        <dt>Owned library</dt>
        <dd>
          {data.automation.first_sync_done ? plural(data.library.total, "title") : "Not synced"}
          {data.automation.first_sync_done ? (
            <span className="field-hint">
              {" "}
              {data.library.purchased.toLocaleString("en")} purchased · {data.library.subscription.toLocaleString("en")} subscription
            </span>
          ) : null}
        </dd>
      </div>
    </dl>
  );
}

function Section({ id, title, summary, children }: { id: SectionId; title: string; summary?: string; children: ReactNode }) {
  const outcome = useContext(OutcomeContext);
  return (
    <section id={id} className="audible-section" aria-labelledby={`${id}-heading`} tabIndex={-1}>
      <h4 id={`${id}-heading`}>{title}</h4>
      {summary ? <p className="field-hint">{summary}</p> : null}
      {children}
      {outcome ? <Said said={outcome.where === id ? outcome.said : null} /> : null}
    </section>
  );
}

function companionFields(data: Audible): SettingField[] {
  const connection = data.connection;
  return [
    { key: "url", label: "Companion address", description: "The bundled Docker service address, or a custom companion you trust.", input: "url", value: connection.url, placeholder: connection.default_url },
    {
      key: "bridge_token",
      label: "Bridge token",
      description: "Authenticates Shelfarr to the companion. A token for a custom address is encrypted at rest.",
      input: "secret",
      value: null,
      configured: connection.bridge_token_saved,
      clearable: false,
      placeholder: "Required for a custom companion",
      ...(connection.token_file_managed ? { managed_by: TOKEN_FILE_VARIABLE } : {}),
    },
    { key: "enabled", label: "Turn on Audible backup", description: "Makes Audible sync and backups available to administrators.", input: "toggle", value: connection.enabled },
    { key: "allow_private_network", label: "Allow a local or private companion address", description: "Needed for the bundled companion and other addresses on your network.", input: "toggle", value: connection.allow_private_network },
    { key: "timeout_seconds", label: "Request timeout", description: "Seconds Shelfarr waits for the companion to answer.", input: "number", value: String(connection.timeout_seconds), min: 1, max: 120 },
  ];
}

function companionDraft(data: Audible): CompanionValues {
  const connection = data.connection;
  return { url: connection.url, bridge_token: "", enabled: connection.enabled, allow_private_network: connection.allow_private_network, timeout_seconds: String(connection.timeout_seconds) };
}

function sameCompanion(left: CompanionValues, right: CompanionValues): boolean {
  return left.url === right.url && left.bridge_token === right.bridge_token && left.enabled === right.enabled && left.allow_private_network === right.allow_private_network && left.timeout_seconds === right.timeout_seconds;
}

function useDraft<T>(saved: T, same: (left: T, right: T) => boolean, key: string, onDirtyChange: DirtyReporter) {
  const [draft, setDraft] = useState(saved);
  const [base, setBase] = useState(saved);
  const dirty = !same(draft, base);
  if (!dirty && !same(base, saved)) {
    setBase(saved);
    setDraft(saved);
  }
  useEffect(() => {
    onDirtyChange(key, dirty);
  }, [key, dirty, onDirtyChange]);
  useEffect(() => () => onDirtyChange(key, false), [key, onDirtyChange]);
  const reset = (next: T) => {
    setBase(next);
    setDraft(next);
  };
  return { draft, setDraft, dirty, reset };
}

function ConnectionSection({ data, run, busy, onDirtyChange }: { data: Audible; run: Run; busy: boolean; onDirtyChange: DirtyReporter }) {
  const scope = useScope();
  const saved = companionDraft(data);
  const { draft, setDraft, dirty, reset } = useDraft(saved, sameCompanion, "audible-connection", onDirtyChange);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [problem, setProblem] = useState<string | null>(null);
  const [test, setTest] = useState<TestOutcome | null>(null);
  const fields = companionFields(data);
  const locked = data.connection.locked;
  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (busy || locked) return;
    setErrors({});
    setProblem(null);
    run(
      { kind: "save", values: draft },
      (action) => {
        if (action.outcome.tone === "success") reset(companionDraft(action));
      },
      (rejection) => {
        const byField: Record<string, string> = {};
        for (const entry of rejection) byField[entry.field] = byField[entry.field] ? `${byField[entry.field]} ${entry.message}` : entry.message;
        setErrors(byField);
        setProblem(byField.base ?? null);
        if (rejection.some((entry) => entry.field !== "base")) focusSoon(() => document.querySelector<HTMLElement>(`#audible-connection [aria-invalid="true"]`));
      },
    );
  };
  const value = (field: SettingField): DraftValue => {
    const current = draft[field.key as keyof CompanionValues];
    return typeof current === "boolean" ? current : String(current);
  };
  const change = (field: SettingField, next: DraftValue) => {
    if (field.key in errors) setErrors((previous) => Object.fromEntries(Object.entries(previous).filter(([key]) => key !== field.key)));
    setDraft((previous) => ({ ...previous, [field.key]: field.input === "toggle" ? next === true : typeof next === "string" ? next : "" }));
  };
  return (
    <Section id="audible-connection" title="Libation companion" summary="Connection changes are saved only when you press Save, and a stored token is kept unless you enter a new one.">
      <form className="settings-form audible-form" method="post" noValidate onSubmit={submit} aria-labelledby="audible-connection-heading">
        {data.connection.problem ? (
          <p className="field-warning" role="alert">
            <span aria-hidden="true">⚠ </span>The companion is set up but did not answer: {data.connection.problem}
          </p>
        ) : null}
        {fields.map((field) => (
          <SettingControl key={field.key} scope={scope} field={field} value={value(field)} error={errors[field.key]} onChange={(next) => change(field, next)} />
        ))}
        <FormProblem text={problem} />
        {locked ? <p className="field-hint" id={`${scope}-locked`}>Wait for the current Libation work or Audible sign-in to finish before changing or testing the connection.</p> : null}
        <CardActions unsaved={dirty}>
          <button type="submit" className="button button--primary" disabled={busy || locked} aria-describedby={locked ? `${scope}-locked` : undefined}>
            Save
          </button>
          {dirty ? (
            <button type="button" className="button button--subtle" onClick={() => reset(saved)} disabled={busy}>
              Discard changes
            </button>
          ) : null}
          {data.connection.saved ? (
            <button
              type="button"
              className="button"
              disabled={busy || locked}
              aria-describedby={locked ? `${scope}-locked` : undefined}
              onClick={() => run({ kind: "test" }, (action) => setTest({ tone: action.outcome.tone, message: action.outcome.message, at: new Date(), note: dirty ? "This tested the saved settings, not your unsaved changes." : undefined }))}
            >
              Test
            </button>
          ) : null}
        </CardActions>
        <TestResult result={test} />
      </form>
    </Section>
  );
}

function AccountSection({ data, run, busy }: { data: Audible; run: Run; busy: boolean }) {
  const sign = data.sign_in;
  return (
    <Section id="audible-account" title="Audible account" summary="Sign-in opens Amazon or Audible directly through Libation. Shelfarr never sees your password.">
      {sign.state === "not_ready" ? (
        <p className="field-hint">Save and turn on the Libation companion before connecting an Audible account.</p>
      ) : (
        <>
          {sign.accounts.length > 0 ? (
            <ul className="audible-accounts" aria-label="Accounts in Libation">
              {sign.accounts.map((entry) => (
                <li key={`${entry.label}-${entry.marketplace}`}>
                  {entry.label} ({entry.marketplace}) · {entry.authenticated ? "connected" : "sign-in required"}
                </li>
              ))}
            </ul>
          ) : sign.accounts_paused ? (
            <p className="field-hint">Account details are paused while Libation works. Your connection is kept.</p>
          ) : null}
          {sign.state === "starting" ? (
            <p className="field-hint" role="status">
              Libation is preparing the secure Audible sign-in. This updates by itself when it is ready.
            </p>
          ) : sign.state === "pending" ? (
            <PendingSignIn data={data} run={run} busy={busy} />
          ) : sign.locked ? (
            <p className="field-hint">Account changes become available after the current Libation work finishes.</p>
          ) : sign.state === "connected" ? (
            <details className="settings-note">
              <summary>Reconnect or add an Audible account</summary>
              <StartSignIn data={data} run={run} busy={busy} />
            </details>
          ) : (
            <StartSignIn data={data} run={run} busy={busy} />
          )}
        </>
      )}
    </Section>
  );
}

function StartSignIn({ data, run, busy }: { data: Audible; run: Run; busy: boolean }) {
  const scope = useScope();
  const [account, setAccount] = useState("");
  const [locale, setLocale] = useState(data.marketplaces[0]?.value ?? "us");
  const [reregister, setReregister] = useState(data.sign_in.reregister_default);
  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (busy) return;
    run({ kind: "start_sign_in", account: account.trim(), locale, reregister }, (action) => {
      if (action.sign_in.state === "pending") focusSoon(() => document.getElementById("audible-open-sign-in"));
    });
  };
  return (
    <form className="settings-form audible-form" method="post" onSubmit={submit} aria-label="Start Audible sign-in">
      <div className="field">
        <label htmlFor={`${scope}-account`}>Audible account email</label>
        <input id={`${scope}-account`} name="account" type="text" inputMode="email" required maxLength={320} autoComplete="email" autoCapitalize="none" autoCorrect="off" spellCheck={false} value={account} onChange={(event) => setAccount(event.target.value)} />
      </div>
      <div className="field">
        <label htmlFor={`${scope}-locale`}>Marketplace</label>
        <select id={`${scope}-locale`} name="locale" value={locale} onChange={(event) => setLocale(event.target.value)}>
          {data.marketplaces.map((entry) => (
            <option key={entry.value} value={entry.value}>
              {entry.label}
            </option>
          ))}
        </select>
      </div>
      <div className="check-field">
        <input id={`${scope}-reregister`} type="checkbox" checked={reregister} aria-describedby={`${scope}-reregister-hint`} onChange={(event) => setReregister(event.target.checked)} />
        <label htmlFor={`${scope}-reregister`}>Replace the stored Libation device registration</label>
        <p id={`${scope}-reregister-hint`} className="field-hint">
          Use once after upgrading from Libation 13 to 14.2. It replaces the saved sign-in for this email and marketplace; other accounts and scan preferences are kept.
        </p>
      </div>
      <div className="settings-card-actions">
        <button type="submit" className="button button--primary" disabled={busy}>
          Start sign-in
        </button>
      </div>
    </form>
  );
}

function PendingSignIn({ data, run, busy }: { data: Audible; run: Run; busy: boolean }) {
  const scope = useScope();
  const [address, setAddress] = useState("");
  const token = data.sign_in.sign_in_token;
  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (busy || !token) return;
    run({ kind: "complete_sign_in", sign_in_token: token, response_url: address.trim() }, (action) => {
      if (action.outcome.tone === "success") setAddress("");
    });
  };
  return (
    <ol className="audible-steps">
      <li>
        <p>Sign in to Audible in a new tab.</p>
        {data.sign_in.login_url ? (
          <a id="audible-open-sign-in" className="button button--primary" href={data.sign_in.login_url} target="_blank" rel="noopener noreferrer" referrerPolicy="no-referrer">
            Open Audible sign-in<span className="sr-only"> (opens in a new tab)</span>
          </a>
        ) : (
          <p className="field-warning">
            <span aria-hidden="true">⚠ </span>Libation returned a sign-in address Shelfarr does not trust, so it is not shown. Start the sign-in again.
          </p>
        )}
        {data.sign_in.expires_at ? (
          <p className="field-hint">
            This sign-in expires <Time iso={data.sign_in.expires_at} relative />.
          </p>
        ) : null}
      </li>
      <li>
        <form className="settings-form audible-form" method="post" onSubmit={submit} aria-label="Complete Audible sign-in">
          <div className="field">
            <label htmlFor={`${scope}-response`}>Address the Audible tab ends on</label>
            <input id={`${scope}-response`} name="response_url" type="url" inputMode="url" required autoComplete="off" autoCapitalize="none" autoCorrect="off" spellCheck={false} value={address} aria-describedby={`${scope}-response-hint`} onChange={(event) => setAddress(event.target.value)} />
            <p id={`${scope}-response-hint`} className="field-hint">
              After signing in, copy the full address from that tab's address bar and paste it here.
            </p>
          </div>
          <div className="settings-card-actions">
            <button type="submit" className="button button--primary" disabled={busy || !token}>
              Complete sign-in
            </button>
          </div>
        </form>
      </li>
    </ol>
  );
}

function SyncStatus({ data }: { data: Audible }) {
  const sync = data.sync;
  const failed = sync.state === "failed";
  let body: ReactNode;
  switch (sync.state) {
    case "queued":
      body = <p>{sync.recoverable ? "Library sync queued, but the queue has not picked it up. Use Recover sync to queue a fresh check safely." : "Library sync queued. Waiting for Shelfarr's background worker."}</p>;
      break;
    case "syncing":
      body = (
        <>
          <p>
            {sync.refreshing ? "Refreshing" : "Syncing"} your Audible library{sync.started_at ? <>, started <Time iso={sync.started_at} relative /></> : null}. Libation does not report a percentage or a reliable estimate. You can leave this page.
          </p>
          {sync.recoverable ? <p>{sync.job_recorded ? "You can ask for a status check now if the polling stopped." : "Shelfarr did not record a companion job in time. Use Recover sync to resume safely."}</p> : null}
          <progress className="audible-progress" aria-label="Library sync in progress" />
        </>
      );
      break;
    case "failed":
      body = (
        <>
          <p>
            <span aria-hidden="true">⚠ </span>Library sync failed: {sync.error ?? "Libation could not complete the library sync."}
          </p>
          {data.library.total > 0 ? <p className="field-hint">The previous snapshot of {plural(data.library.total, "title")} is still available.</p> : null}
        </>
      );
      break;
    case "succeeded":
      body = (
        <>
          <p>{data.library.total === 0 ? "Sync finished, but no supported Audible titles were found." : `Library ready · ${plural(data.library.total, "active title")}.`}</p>
          {sync.last_synced_at ? (
            <p className="field-hint">
              Last sync finished <Time iso={sync.last_synced_at} relative />.
            </p>
          ) : null}
        </>
      );
      break;
    default:
      body = <p>{data.sign_in.state === "connected" ? "Audible is connected. One more step: sync your library." : "Connect an Audible account before the first sync."}</p>;
  }
  return (
    <div className={`audible-sync-status${failed ? " audible-sync-status--failed" : ""}`} role={failed ? "alert" : "status"}>
      {body}
      {data.active_backups.total > 0 ? (
        <p>
          {plural(data.active_backups.total, "backup")} active · {countsText(data.active_backups.counts)}
        </p>
      ) : null}
    </div>
  );
}

function SyncSection({ data, run, busy }: { data: Audible; run: Run; busy: boolean }) {
  if (!data.connection.saved || !data.connection.enabled) {
    return (
      <Section id="audible-sync" title="Library sync">
        <p className="field-hint">Turn on the Libation companion, connect Audible, then run the first library sync.</p>
      </Section>
    );
  }
  return (
    <Section id="audible-sync" title="Library sync" summary="Refreshes Shelfarr's private copy of the account cached by your companion. Reading this page never asks Audible.">
      <SyncStatus data={data} />
      <div className="settings-card-actions">
        <button type="button" className="button button--primary" disabled={busy || !data.sync.available} onClick={() => run({ kind: "sync" })}>
          {data.sync.action}
        </button>
      </div>
      {data.existing_backup.prompt && data.existing_backup.available ? <ExistingBackupPrompt run={run} busy={busy} /> : null}
    </Section>
  );
}

function ExistingBackupPrompt({ run, busy }: { run: Run; busy: boolean }) {
  return (
    <div className="audible-prompt">
      <h5>Back up your existing Audible library?</h5>
      <p>Shelfarr found purchased audiobooks that may be eligible for a one-time backup. If you continue, Shelfarr checks each one against this server's library, queues every eligible title in a background batch, and Libation backs them up one at a time.</p>
      <p className="field-warning">
        <span aria-hidden="true">⚠ </span>A full backup can take a long time and use a lot of bandwidth and disk space. Subscription titles, files already here, uncertain matches and titles tried before are skipped.
      </p>
      <ExistingBackupForm run={run} busy={busy} confirmText="I understand this queues every eligible personal backup and continues in the background." />
      <p>
        <button type="button" className="button button--subtle" disabled={busy} onClick={() => run({ kind: "dismiss_existing" })}>
          Not now
        </button>
        <span className="field-hint"> You can start it later under Automation.</span>
      </p>
    </div>
  );
}

function ExistingBackupForm({ run, busy, confirmText }: { run: Run; busy: boolean; confirmText: string }) {
  const scope = useScope();
  const [confirmed, setConfirmed] = useState(false);
  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (busy || !confirmed) return;
    run({ kind: "back_up_existing" }, () => setConfirmed(false));
  };
  return (
    <form className="settings-form audible-form" method="post" onSubmit={submit} aria-label="Queue the existing-library backup">
      <div className="check-field">
        <input id={`${scope}-confirm`} type="checkbox" required checked={confirmed} onChange={(event) => setConfirmed(event.target.checked)} />
        <label htmlFor={`${scope}-confirm`}>{confirmText}</label>
      </div>
      <div className="settings-card-actions">
        <button type="submit" className="button button--primary" disabled={busy}>
          Queue eligible backups
        </button>
      </div>
    </form>
  );
}

type AutomationDraft = { scheduled_sync_enabled: boolean; interval: string; automatic_backup_enabled: boolean };

function automationDraft(data: Audible): AutomationDraft {
  return { scheduled_sync_enabled: data.automation.scheduled_sync_enabled, interval: String(data.automation.interval_minutes), automatic_backup_enabled: data.automation.automatic_backup_enabled };
}

function sameAutomation(left: AutomationDraft, right: AutomationDraft): boolean {
  return left.scheduled_sync_enabled === right.scheduled_sync_enabled && left.interval === right.interval && left.automatic_backup_enabled === right.automatic_backup_enabled;
}

function AutomationSection({ data, run, busy, onDirtyChange }: { data: Audible; run: Run; busy: boolean; onDirtyChange: DirtyReporter }) {
  const scope = useScope();
  const saved = automationDraft(data);
  const { draft, setDraft, dirty, reset } = useDraft(saved, sameAutomation, "audible-automation", onDirtyChange);
  if (!data.connection.saved || !data.connection.enabled) {
    return (
      <Section id="audible-automation" title="Automation">
        <p className="field-hint">Turn on the Libation companion before setting up scheduled sync or backups.</p>
      </Section>
    );
  }
  const automation = data.automation;
  const scheduled: SettingField = { key: "scheduled_sync_enabled", label: "Sync the Audible library automatically", description: "Runs through the same one-at-a-time Libation work as a manual sync.", input: "toggle", value: draft.scheduled_sync_enabled };
  const backups: SettingField = {
    key: "automatic_backup_enabled",
    label: "Automatically back up new purchases",
    description: automation.first_sync_done
      ? "Needs scheduled sync. After a first sync that downloads nothing, purchases first found on later syncs are queued by themselves. This covers future purchases only."
      : "Run the first library sync before turning this on, so Shelfarr can record what you already own.",
    input: "toggle",
    value: draft.automatic_backup_enabled,
  };
  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (busy) return;
    run({ kind: "automation", values: { scheduled_sync_enabled: draft.scheduled_sync_enabled, scheduled_sync_interval_minutes: Number(draft.interval), automatic_backup_enabled: draft.automatic_backup_enabled } }, (action) => {
      if (action.outcome.tone === "success") reset(automationDraft(action));
    });
  };
  return (
    <Section id="audible-automation" title="Automation" summary="Changes apply to future scheduled runs and never touch stored Audible sign-ins.">
      <form className="settings-form audible-form" method="post" noValidate onSubmit={submit} aria-labelledby="audible-automation-heading">
        <SettingControl scope={scope} field={scheduled} value={draft.scheduled_sync_enabled} onChange={(next) => setDraft((previous) => ({ ...previous, scheduled_sync_enabled: next === true }))} />
        <div className="field">
          <label htmlFor={`${scope}-interval`}>Sync interval</label>
          <select id={`${scope}-interval`} name="scheduled_sync_interval_minutes" value={draft.interval} aria-describedby={`${scope}-interval-hint`} onChange={(event) => setDraft((previous) => ({ ...previous, interval: event.target.value }))}>
            {automation.intervals.map((entry) => (
              <option key={entry.minutes} value={String(entry.minutes)}>
                {entry.label}
              </option>
            ))}
          </select>
          <p id={`${scope}-interval-hint`} className="field-hint">
            Hourly finds new purchases fastest; every 24 hours is the default.
          </p>
        </div>
        <SettingControl scope={scope} field={backups} value={draft.automatic_backup_enabled} onChange={(next) => setDraft((previous) => ({ ...previous, automatic_backup_enabled: next === true }))} />
        <p className="field-hint">
          {!automation.scheduled_sync_enabled
            ? "Scheduled sync is off."
            : data.sync.state === "queued" || data.sync.state === "syncing"
              ? "A library sync is running. Shelfarr sets the next scheduled time when it finishes."
              : automation.next_sync_at
                ? <>Next sync <Time iso={automation.next_sync_at} relative />.</>
                : "Shelfarr sets the next sync after these settings are saved."}
        </p>
        {automation.automatic_backup_enabled && !automation.owner_ready ? (
          <p className="field-warning" role="alert">
            <span aria-hidden="true">⚠ </span>Automatic backup is paused because the administrator it belongs to is no longer active. Save again to give it to yourself.
          </p>
        ) : automation.automatic_backup_enabled && !automation.baseline_ready ? (
          <p className="field-hint">Automatic backup is on. The next successful sync records what you own without downloading anything; purchases first found after that are queued.</p>
        ) : automation.automatic_backup_enabled ? (
          <p className="field-hint">New backups are credited to {automation.owner ?? "the administrator who saved these settings"}. Turning this off and on again starts a new baseline and does not back up purchases found while it was off.</p>
        ) : null}
        <CardActions unsaved={dirty}>
          <button type="submit" className="button button--primary" disabled={busy}>
            Save automation
          </button>
          {dirty ? (
            <button type="button" className="button button--subtle" onClick={() => reset(saved)} disabled={busy}>
              Discard changes
            </button>
          ) : null}
        </CardActions>
      </form>
      <ExistingBackupStatus data={data} run={run} busy={busy} />
    </Section>
  );
}

function ExistingBackupStatus({ data, run, busy }: { data: Audible; run: Run; busy: boolean }) {
  const existing = data.existing_backup;
  return (
    <div className="audible-existing">
      <h5>Existing-library backup</h5>
      <p className="field-hint">A separate one-time action for purchases already in Audible at the first sync. Each title is checked again before it is backed up.</p>
      {existing.total > 0 ? (
        <div className="audible-sync-status" role="status">
          <p>
            {existing.remaining > 0 ? "Existing-library batch running" : "Existing-library batch processed"} · {existing.processed.toLocaleString("en")} of {existing.total.toLocaleString("en")} processed
          </p>
          {existing.counts.length > 0 ? <p className="field-hint">{countsText(existing.counts)}</p> : null}
          <progress className="audible-progress" max={existing.total} value={existing.processed} aria-label="Existing-library backup progress" />
        </div>
      ) : null}
      {!data.automation.first_sync_done ? (
        <p className="field-hint">Run the first library sync before starting an existing-library backup.</p>
      ) : existing.remaining > 0 ? (
        <p className="field-hint">The current batch continues in the background.</p>
      ) : existing.prompt && existing.available ? (
        <p className="field-hint">
          Shelfarr found purchases that may be eligible. <a href="#audible-sync">Review and confirm under Library sync</a>.
        </p>
      ) : existing.available ? (
        <ExistingBackupForm run={run} busy={busy} confirmText="I understand this background batch may take a long time and use a lot of bandwidth and disk space." />
      ) : (
        <p className="field-hint">No unattempted purchased audiobooks are left to check.</p>
      )}
    </div>
  );
}

function CatalogueSection({ data, run, busy }: { data: Audible; run: Run; busy: boolean }) {
  if (!data.connection.saved || !data.connection.enabled) {
    return (
      <Section id="audible-catalogue" title="Audible catalogue">
        <p className="field-hint">Turn on the Libation companion and sync an Audible account to see its titles.</p>
      </Section>
    );
  }
  return <CatalogueBody data={data} run={run} busy={busy} />;
}

function CatalogueBody({ data, run, busy }: { data: Audible; run: Run; busy: boolean }) {
  const search = audibleSearchSchema.parse(useSearch({ strict: false }));
  const navigate = useNavigate();
  const query = search.audible_q ?? "";
  const page = Number(search.audible_page ?? "1");
  const catalogue = useCatalogue(query, page, data.working);
  const [text, setText] = useState(query);
  const [shownQuery, setShownQuery] = useState(query);
  if (shownQuery !== query) {
    setShownQuery(query);
    setText(query);
  }
  const submitButton = useRef<HTMLButtonElement>(null);
  const scope = useScope();
  const go = (nextQuery: string, nextPage: number) => {
    void navigate({
      to: "/server/$category",
      params: { category: "library" },
      search: { audible_q: nextQuery.trim() === "" ? undefined : nextQuery, audible_page: nextPage > 1 ? String(nextPage) : undefined },
      hash: "audible-catalogue",
      resetScroll: false,
    });
  };
  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    go(text, 1);
    if (text === query) void catalogue.refetch();
  };
  return (
    <Section id="audible-catalogue" title="Audible catalogue" summary={`Ownership and backup state for ${plural(data.library.total, "active title")}.`}>
      <search>
        <form className="audible-filter" onSubmit={submit} aria-label="Filter the Audible catalogue">
          <div className="field">
            <label htmlFor={`${scope}-filter`}>Title or author</label>
            <input id={`${scope}-filter`} name="q" type="search" maxLength={200} autoComplete="off" autoCorrect="off" spellCheck={false} enterKeyHint="search" value={text} onChange={(event) => setText(event.target.value)} />
          </div>
          <div className="settings-card-actions">
            <button ref={submitButton} type="submit" className="button">
              Filter
            </button>
            {query !== "" ? (
              <button
                type="button"
                className="button button--subtle"
                onClick={() => {
                  setText("");
                  go("", 1);
                  submitButton.current?.focus();
                }}
              >
                Clear filter
              </button>
            ) : null}
          </div>
        </form>
      </search>
      {catalogue.isError && !catalogue.data ? (
        <ErrorPanel error={catalogue.error} onRetry={() => void catalogue.refetch()} />
      ) : !catalogue.data ? (
        <Loading label="Loading the Audible catalogue…" />
      ) : (
        <CatalogueList catalogue={catalogue.data} stale={catalogue.isPlaceholderData} run={run} busy={busy} onPage={(next) => go(query, next)} onShowAll={() => go("", 1)} />
      )}
    </Section>
  );
}

function CatalogueList({ catalogue, stale, run, busy, onPage, onShowAll }: { catalogue: Catalogue; stale: boolean; run: Run; busy: boolean; onPage: (page: number) => void; onShowAll: () => void }) {
  if (catalogue.items.length === 0) {
    return (
      <p className="field-hint" role="status">
        {catalogue.query !== "" ? (
          <>
            No Audible titles match this filter.{" "}
            <button type="button" className="button button--subtle" onClick={onShowAll}>
              Show every title
            </button>
          </>
        ) : !catalogue.synced ? (
          <>
            No Audible catalogue has been synced yet. <a href="#audible-sync">Run the first library sync</a>.
          </>
        ) : (
          "No active Audible titles are available."
        )}
      </p>
    );
  }
  return (
    <>
      <p className="field-hint" role="status">
        {stale ? "Loading…" : `${plural(catalogue.total, "title")} · Page ${catalogue.page} of ${catalogue.pages}`}
      </p>
      <div className="audible-table" role="region" aria-labelledby="audible-catalogue-heading" tabIndex={0}>
        <table>
          <thead>
            <tr>
              <th scope="col">Title</th>
              <th scope="col">Ownership</th>
              <th scope="col">Backup</th>
              <th scope="col">Action</th>
            </tr>
          </thead>
          <tbody>
            {catalogue.items.map((item) => (
              <CatalogueRow key={item.id} item={item} run={run} busy={busy} />
            ))}
          </tbody>
        </table>
      </div>
      {catalogue.pages > 1 ? (
        <nav className="settings-card-actions" aria-label="Audible catalogue pages">
          <button type="button" className="button" disabled={catalogue.page <= 1} onClick={() => onPage(catalogue.page - 1)}>
            Previous page
          </button>
          <button type="button" className="button" disabled={catalogue.page >= catalogue.pages} onClick={() => onPage(catalogue.page + 1)}>
            Next page
          </button>
        </nav>
      ) : null}
    </>
  );
}

function CatalogueRow({ item, run, busy }: { item: CatalogueItem; run: Run; busy: boolean }) {
  const button = useRef<HTMLButtonElement>(null);
  const state = item.origin && item.origin !== "manual" && ["queued", "starting", "downloading", "processing", "failed"].includes(item.state) ? `${ORIGINS[item.origin]}: ${BACKUP_STATES[item.state].toLowerCase()}` : BACKUP_STATES[item.state];
  return (
    <tr>
      <th scope="row">
        <span className="audible-title">{item.title}</span>
        <span className="field-hint">{item.author}</span>
      </th>
      <td data-label="Ownership">{OWNERSHIP[item.ownership]}</td>
      <td data-label="Backup">
        <span className={item.state === "failed" || item.state === "stalled" ? "audible-problem" : undefined}>
          {item.state === "failed" || item.state === "stalled" ? <span aria-hidden="true">⚠ </span> : null}
          {state}
        </span>
        {item.state === "possible_match" ? <span className="field-hint"> Back up separately to keep the existing edition.</span> : null}
        {item.detail ? <span className="field-hint audible-detail">{item.detail}</span> : null}
      </td>
      <td data-label="Action">
        {item.book_id ? (
          <Link to="/library/$publicationId" params={{ publicationId: item.book_id }}>
            Open in Library
          </Link>
        ) : item.action ? (
          <button
            ref={button}
            type="button"
            className="button"
            disabled={busy || !item.action.available}
            aria-label={`${item.action.label} ${item.title}`}
            onClick={() => {
              if (!item.action) return;
              run({ kind: "back_up_item", id: item.id, separate_edition: item.action.separate_edition }, () => focusSoon(() => button.current));
            }}
          >
            {item.action.label}
          </button>
        ) : (
          <span className="field-hint">Not eligible</span>
        )}
      </td>
    </tr>
  );
}
