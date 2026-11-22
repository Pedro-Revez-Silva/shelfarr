import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { useEffect, useId, useRef, useState, type FormEvent, type ReactNode } from "react";
import { isApiError } from "../api/errors";
import { readCsrfToken } from "../boot";
import type { AccountSettings, ApiToken, CreatedToken, Profile, TwoFactorSetup } from "../contract";
import { useServices } from "../services";
import { describeWriteFailure } from "./accountFields";
import { absoluteTime, Time } from "./requestText";

export const ACCOUNT_SECTIONS = [
  { key: "profile", label: "Profile" },
  { key: "security", label: "Sign-in and security" },
  { key: "devices", label: "Devices" },
  { key: "connections", label: "Connections" },
  { key: "about", label: "About" },
] as const;
export type AccountSection = (typeof ACCOUNT_SECTIONS)[number]["key"];

export function isAccountSection(value: string): value is AccountSection {
  return ACCOUNT_SECTIONS.some((section) => section.key === value);
}

export function AccountRail({ current }: { current: AccountSection }) {
  return (
    <nav className="account-rail" aria-label="Account">
      <ul>
        {ACCOUNT_SECTIONS.map((section) => (
          <li key={section.key}>
            {section.key === "profile" ? (
              <Link to="/account" className="filter-link" aria-current={current === "profile" ? "page" : undefined} activeOptions={{ exact: true }} activeProps={{}}>
                {section.label}
              </Link>
            ) : (
              <Link to="/account/$section" params={{ section: section.key }} className="filter-link" aria-current={current === section.key ? "page" : undefined} activeProps={{}}>
                {section.label}
              </Link>
            )}
          </li>
        ))}
      </ul>
    </nav>
  );
}

function useProfileChange<V, T>(send: (variables: V) => Promise<T>, profileOf: (answer: T) => Profile | null) {
  const { keys, guard } = useServices();
  const client = useQueryClient();
  return useMutation({
    mutationFn: send,
    onSuccess: (answer: T) => {
      if (!guard.isActive()) return;
      const profile = profileOf(answer);
      if (profile) client.setQueryData(keys.profile, profile);
    },
    onSettled: () => {
      if (guard.isActive()) void client.invalidateQueries({ queryKey: keys.profile });
    },
  });
}

function Card({ title, children, description }: { title: string; children: ReactNode; description?: ReactNode }) {
  const headingId = useId();
  return (
    <section className="account-card" aria-labelledby={headingId}>
      <h2 id={headingId}>{title}</h2>
      {description ? <p className="muted">{description}</p> : null}
      {children}
    </section>
  );
}

function Problem({ error, fallback }: { error: unknown; fallback: string }) {
  return (
    <p className="form-error" role="alert">
      {describeWriteFailure(error, fallback)}
    </p>
  );
}

function refusedWith(error: unknown, code: string): boolean {
  return isApiError(error) && error.code === code;
}

export function RequestStats({ settings }: { settings: AccountSettings }) {
  return (
    <Card title="Your requests">
      <dl className="identity identity--stats">
        <div>
          <dt>All requests</dt>
          <dd>{settings.requests.total}</dd>
        </div>
        <div>
          <dt>Completed</dt>
          <dd>{settings.requests.completed}</dd>
        </div>
        <div>
          <dt>Waiting</dt>
          <dd>{settings.requests.pending}</dd>
        </div>
      </dl>
      <p>
        <Link to="/requests">See your requests</Link>
      </p>
    </Card>
  );
}

export function SignOut({ settings }: { settings: AccountSettings }) {
  const [token] = useState(() => readCsrfToken(document));
  const action = settings.links.sign_out;
  return (
    <Card title="Sign out" description="Signs this browser out of Shelfarr. Apps and readers connected to your account stay connected.">
      <form method="post" action={action}>
        <input type="hidden" name="_method" value="delete" />
        {token ? <input type="hidden" name="authenticity_token" value={token} /> : null}
        <button type="submit" className="button">
          Sign out
        </button>
      </form>
    </Card>
  );
}

export function TwoFactorCard({ settings }: { settings: AccountSettings }) {
  const [codes, setCodes] = useState<string[] | null>(null);
  return (
    <Card title="Two-factor sign-in" description="Ask for a code from an authenticator app after your password when you sign in.">
      {codes ? <BackupCodes codes={codes} onDone={() => setCodes(null)} /> : settings.two_factor.enabled ? <TwoFactorOn onCodes={setCodes} /> : <TwoFactorOff onCodes={setCodes} />}
    </Card>
  );
}

function TwoFactorOff({ onCodes }: { onCodes: (codes: string[]) => void }) {
  const { api } = useServices();
  const start = useMutation({ mutationFn: () => api.startTwoFactor() });
  const setup = start.data;
  if (!setup) {
    return (
      <>
        <p>Two-factor sign-in is off.</p>
        <div className="form-actions">
          <button type="button" className="button button--primary" aria-disabled={start.isPending ? true : undefined} onClick={() => (start.isPending ? undefined : start.mutate())}>
            {start.isPending ? "Preparing…" : "Turn on two-factor sign-in"}
          </button>
        </div>
        {start.isError ? <Problem error={start.error} fallback="Two-factor setup could not start. Nothing was changed; try again." /> : null}
      </>
    );
  }
  return <EnableTwoFactor setup={setup} onCodes={onCodes} />;
}

function EnableTwoFactor({ setup, onCodes }: { setup: TwoFactorSetup; onCodes: (codes: string[]) => void }) {
  const { api } = useServices();
  const ids = { code: useId(), hint: useId(), error: useId() };
  const [code, setCode] = useState("");
  const enable = useProfileChange((value: string) => api.enableTwoFactor(value), () => null);
  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (enable.isPending || code.trim() === "") return;
    enable.mutate(code.trim(), { onSuccess: onCodes });
  };
  const refused = enable.isError && refusedWith(enable.error, "invalid_code");
  return (
    <form className="account-form" onSubmit={submit} noValidate>
      <ol className="steps-list">
        <li>Open an authenticator app on your phone, such as 1Password, Google Authenticator or Authy.</li>
        <li>
          Scan this code, or enter the key by hand.
          <div className="qr">{setup.qr_svg ? <img src={`data:image/svg+xml;charset=utf-8,${encodeURIComponent(setup.qr_svg)}`} alt="Code to scan with your authenticator app" width={180} height={180} /> : null}</div>
          <p className="field-hint">
            Key: <code className="secret">{setup.secret}</code>
          </p>
        </li>
        <li>Type the six-digit code the app shows.</li>
      </ol>
      <div className="field">
        <label htmlFor={ids.code}>Code from the app</label>
        <input
          id={ids.code}
          name="otp_code"
          inputMode="numeric"
          autoComplete="one-time-code"
          enterKeyHint="done"
          pattern="[0-9]*"
          maxLength={10}
          value={code}
          aria-invalid={refused}
          aria-describedby={refused ? ids.error : undefined}
          onChange={(event) => setCode(event.target.value)}
        />
        {refused ? (
          <p id={ids.error} className="field-error">
            <span aria-hidden="true">⚠ </span>That code was not accepted. Check the time on your phone and try the newest code.
          </p>
        ) : null}
      </div>
      <div className="form-actions">
        <button type="submit" className="button button--primary" aria-disabled={enable.isPending ? true : undefined}>
          {enable.isPending ? "Checking…" : "Turn on"}
        </button>
      </div>
      {enable.isError && !refused ? <Problem error={enable.error} fallback="Shelfarr could not confirm whether two-factor sign-in was turned on. Reload the page to see its state." /> : null}
    </form>
  );
}

function TwoFactorOn({ onCodes }: { onCodes: (codes: string[]) => void }) {
  const { api } = useServices();
  const codes = useMutation({ mutationFn: (password: string) => api.newBackupCodes(password) });
  const disable = useProfileChange((password: string) => api.disableTwoFactor(password), (profile) => profile);
  return (
    <>
      <p>Two-factor sign-in is on.</p>
      <PasswordAction
        label="Make new backup codes"
        busy="Making codes…"
        note="Your old backup codes stop working."
        state={codes}
        onSubmit={(password, done) => codes.mutate(password, { onSuccess: (value) => { done(); onCodes(value); } })}
      />
      <PasswordAction label="Turn off two-factor sign-in" busy="Turning off…" note="Signing in will need only your password." danger state={disable} onSubmit={(password, done) => disable.mutate(password, { onSuccess: done })} />
    </>
  );
}

function PasswordAction({ label, busy, note, danger = false, state, onSubmit }: { label: string; busy: string; note: string; danger?: boolean; state: { isPending: boolean; isError: boolean; error: unknown }; onSubmit: (password: string, done: () => void) => void }) {
  const [open, setOpen] = useState(false);
  const ids = { password: useId(), error: useId() };
  const input = useRef<HTMLInputElement>(null);
  useEffect(() => {
    if (open) input.current?.focus();
  }, [open]);
  if (!open) {
    return (
      <div className="form-actions">
        <button type="button" className={danger ? "button button--subtle" : "button"} onClick={() => setOpen(true)}>
          {label}
        </button>
      </div>
    );
  }
  const refused = state.isError && refusedWith(state.error, "invalid_password");
  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const value = input.current?.value ?? "";
    if (state.isPending || value === "") return;
    onSubmit(value, () => setOpen(false));
  };
  return (
    <form className="account-form" onSubmit={submit} noValidate>
      <p className="muted">{note}</p>
      <div className="field">
        <label htmlFor={ids.password}>Your password</label>
        <input ref={input} id={ids.password} type="password" autoComplete="current-password" aria-invalid={refused} aria-describedby={refused ? ids.error : undefined} />
        {refused ? (
          <p id={ids.error} className="field-error">
            <span aria-hidden="true">⚠ </span>That is not your password.
          </p>
        ) : null}
      </div>
      <div className="form-actions">
        <button type="submit" className={danger ? "button button--danger" : "button button--primary"} aria-disabled={state.isPending ? true : undefined}>
          {state.isPending ? busy : label}
        </button>
        <button type="button" className="button button--subtle" onClick={() => setOpen(false)}>
          Keep it
        </button>
      </div>
      {state.isError && !refused ? <Problem error={state.error} fallback="Shelfarr could not confirm this change. Reload the page to see the current state." /> : null}
    </form>
  );
}

function BackupCodes({ codes, onDone }: { codes: string[]; onDone: () => void }) {
  const headingId = useId();
  const done = useRef<HTMLButtonElement>(null);
  useEffect(() => done.current?.focus(), []);
  return (
    <div className="backup-codes" role="region" aria-labelledby={headingId}>
      <h3 id={headingId}>Your backup codes</h3>
      <p>Each code signs you in once if you lose your phone. Save them somewhere safe now: Shelfarr will not show them again.</p>
      <ul className="code-list">
        {codes.map((code) => (
          <li key={code}>
            <code>{code}</code>
          </li>
        ))}
      </ul>
      <div className="form-actions">
        <CopyButton text={codes.join("\n")} label="Copy codes" />
        <button ref={done} type="button" className="button button--primary" onClick={onDone}>
          I saved them
        </button>
      </div>
    </div>
  );
}

function CopyButton({ text, label }: { text: string; label: string }) {
  const [result, setResult] = useState("");
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  useEffect(() => () => clearTimeout(timer.current), []);
  const copy = async () => {
    clearTimeout(timer.current);
    try {
      await navigator.clipboard.writeText(text);
      setResult("Copied");
    } catch {
      setResult("Copy failed. Select the text and copy it yourself.");
    }
    timer.current = setTimeout(() => setResult(""), 2500);
  };
  return (
    <span className="copy-button">
      <button type="button" className="button" onClick={() => void copy()}>
        {label}
      </button>
      <span role="status" className="copy-result">
        {result}
      </span>
    </span>
  );
}

export function SingleSignOnCard({ settings }: { settings: AccountSettings }) {
  const oidc = settings.oidc;
  const { api } = useServices();
  const unlink = useProfileChange((password: string) => api.unlinkSingleSignOn(password), (profile) => profile);
  if (!oidc.configured) return null;
  const provider = oidc.provider ?? "single sign-on";
  return (
    <Card title="Single sign-on" description={`Sign in with ${provider} instead of your password.`}>
      {oidc.linked ? (
        <>
          <p>Your account is linked to {provider}.</p>
          {oidc.password_required ? (
            <PasswordAction label={`Unlink ${provider}`} busy="Unlinking…" note="You will sign in with your Shelfarr password only." danger state={unlink} onSubmit={(password, done) => unlink.mutate(password, { onSuccess: done })} />
          ) : (
            <div className="form-actions">
              <button type="button" className="button button--subtle" onClick={() => unlink.mutate("")}>
                Unlink {provider}
              </button>
            </div>
          )}
        </>
      ) : oidc.link_page ? (
        <p>
          <a href={oidc.link_page}>Link {provider} on the classic account page</a>
          <span className="muted"> · linking still happens there while it moves here</span>
        </p>
      ) : null}
    </Card>
  );
}

export function ApiTokensCard({ settings }: { settings: AccountSettings }) {
  const tokens = settings.api_tokens;
  const apps = tokens.filter((token) => token.app);
  const scripts = tokens.filter((token) => !token.app);
  return (
    <>
      <Card title="Connected apps" description="Phone and reader apps you approved with a code. Disconnecting one signs it out at once.">
        {apps.length ? <TokenList tokens={apps} revokeLabel="Disconnect" /> : <p className="muted">No apps are connected.</p>}
      </Card>
      <details className="account-card account-advanced">
        <summary>Advanced: API tokens for scripts and tools</summary>
        <CreateToken settings={settings} />
        {scripts.length ? <TokenList tokens={scripts} revokeLabel="Revoke" /> : <p className="muted">You have no API tokens.</p>}
      </details>
    </>
  );
}

function TokenList({ tokens, revokeLabel }: { tokens: ApiToken[]; revokeLabel: string }) {
  return (
    <ul className="token-list">
      {tokens.map((token) => (
        <li key={token.id}>
          <TokenRow token={token} revokeLabel={revokeLabel} />
        </li>
      ))}
    </ul>
  );
}

const STATE_TEXT: Record<ApiToken["state"], string> = { active: "Active", revoked: "Revoked", expired: "Expired" };

function TokenRow({ token, revokeLabel }: { token: ApiToken; revokeLabel: string }) {
  const { api } = useServices();
  const revoke = useProfileChange(() => api.revokeApiToken(token.id), (profile) => profile);
  return (
    <div className="token-row">
      <div>
        <p className="token-name">{token.name}</p>
        <p className="request-meta">
          <span>
            <code>{token.prefix}…</code>
          </span>
          <span>{STATE_TEXT[token.state]}</span>
          <span title={absoluteTime(token.created_at)}>
            Created <Time iso={token.created_at} relative />
          </span>
          {token.last_used_at ? (
            <span>
              Last used <Time iso={token.last_used_at} relative />
            </span>
          ) : (
            <span>Never used</span>
          )}
        </p>
        {!token.app ? <p className="request-meta">{token.scopes.join(", ")}</p> : null}
      </div>
      {token.state === "active" ? (
        <button type="button" className="button button--subtle" aria-disabled={revoke.isPending ? true : undefined} onClick={() => (revoke.isPending ? undefined : revoke.mutate(undefined))}>
          {revoke.isPending ? "Working…" : revokeLabel}
          <span className="sr-only"> {token.name}</span>
        </button>
      ) : null}
      {revoke.isError ? <Problem error={revoke.error} fallback="Shelfarr could not confirm this. Reload the page to see whether it is still active." /> : null}
    </div>
  );
}

function CreateToken({ settings }: { settings: AccountSettings }) {
  const { api, keys } = useServices();
  const client = useQueryClient();
  const [created, setCreated] = useState<CreatedToken | null>(null);
  const [scopes, setScopes] = useState<string[]>(() => settings.token_scopes.filter((entry) => !entry.scope.endsWith(":admin") && entry.scope !== "users:write").map((entry) => entry.scope));
  const [name, setName] = useState("");
  const ids = { name: useId(), error: useId() };
  const create = useMutation({
    mutationFn: () => api.createApiToken(name.trim() || "API token", scopes),
    onSuccess: (answer) => {
      setCreated(answer);
      setName("");
      void client.invalidateQueries({ queryKey: keys.profile });
    },
  });
  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (create.isPending || scopes.length === 0) return;
    create.mutate();
  };
  return (
    <div>
      {created ? (
        <div className="backup-codes" role="status">
          <p>
            <strong>{created.token.name}</strong> was created. Copy it now; Shelfarr will not show it again.
          </p>
          <p>
            <code className="secret">{created.secret}</code>
          </p>
          <div className="form-actions">
            <CopyButton text={created.secret} label="Copy token" />
            <button type="button" className="button button--subtle" onClick={() => setCreated(null)}>
              Done
            </button>
          </div>
        </div>
      ) : null}
      <form className="account-form" onSubmit={submit} noValidate>
        <div className="field">
          <label htmlFor={ids.name}>Token name</label>
          <input id={ids.name} type="text" autoComplete="off" maxLength={100} value={name} placeholder="API token" onChange={(event) => setName(event.target.value)} />
        </div>
        <fieldset aria-describedby={scopes.length === 0 ? ids.error : undefined}>
          <legend>It may</legend>
          {settings.token_scopes.map((entry) => (
            <label key={entry.scope} className="check">
              <input
                type="checkbox"
                checked={scopes.includes(entry.scope)}
                onChange={(event) => setScopes((current) => (event.target.checked ? [...current, entry.scope] : current.filter((scope) => scope !== entry.scope)))}
              />{" "}
              {entry.label}
            </label>
          ))}
        </fieldset>
        {scopes.length === 0 ? (
          <p id={ids.error} className="field-error">
            <span aria-hidden="true">⚠ </span>Choose at least one thing the token may do.
          </p>
        ) : null}
        <div className="form-actions">
          <button type="submit" className="button button--primary" aria-disabled={create.isPending || scopes.length === 0 ? true : undefined}>
            {create.isPending ? "Creating…" : "Create token"}
          </button>
        </div>
        {create.isError ? <Problem error={create.error} fallback="Shelfarr could not confirm whether the token was created. Reload the page; revoke any token you did not keep." /> : null}
      </form>
    </div>
  );
}

export function DevicesSection({ settings }: { settings: AccountSettings }) {
  return (
    <>
      <Card title="Phone app" description="Use Shelfarr's app on your phone. It asks for a code that you approve here in the browser.">
        <ul className="link-list">
          <li>
            <a href={settings.links.phone_app}>Approve a code from the app</a>
          </li>
          {settings.links.android_app ? (
            <li>
              <a href={settings.links.android_app}>Get the Android app</a>
            </li>
          ) : null}
        </ul>
      </Card>
      <Card title="This browser" description="Shelfarr can open from its own icon on your home screen. Install it from your reading library, which keeps the books you save for offline reading.">
        <p>
          <a href={settings.links.reading_library}>Open your reading library to install it</a>
        </p>
      </Card>
      <Card title="Kobo" description="Kobo readers and Kobo accounts still open on their current pages while they move here.">
        <ul className="link-list">
          <li>
            <a href={settings.links.kobo_readers}>Kobo readers</a>
          </li>
          <li>
            <a href={settings.links.kobo_accounts}>Kobo accounts</a>
          </li>
          {settings.links.kobo_shared ? (
            <li>
              <a href={settings.links.kobo_shared}>Kobo books shared with you</a>
            </li>
          ) : null}
        </ul>
      </Card>
    </>
  );
}

export function ConnectionsSection({ settings }: { settings: AccountSettings }) {
  return (
    <Card title="Hardcover" description="Connect your Hardcover account to follow reading lists and authors. Connecting still opens on its current page while it moves here.">
      <p>
        <a href={settings.links.hardcover}>Manage the Hardcover connection</a>
      </p>
    </Card>
  );
}

export function AboutSection({ settings }: { settings: AccountSettings }) {
  return (
    <Card title="About this server">
      <p>
        This server runs <strong>{settings.server.release}</strong>.
      </p>
      {settings.server.beta ? <p className="muted">Beta builds are ready to use, but some screens may still change before Shelfarr {settings.server.series} is final. Your administrator decides when the server is updated and keeps its backups.</p> : null}
      {settings.links.admin ? (
        <p>
          <a href={settings.links.admin}>Release, updates and backups</a>
        </p>
      ) : null}
    </Card>
  );
}
