import { Link } from "@tanstack/react-router";
import type { UseQueryResult } from "@tanstack/react-query";
import { useRef, useState, type FormEvent } from "react";
import { Time } from "../components/requestText";
import type { LibraryInventory, RoleRow, SettingGroup, SettingNotes, TelegramChat } from "./contract";
import { RemoveZone, useScope } from "./primitives";
import { useLibrarySync, useTelegramChatCommand, useTelegramChats } from "./queries";

export type Said = { tone: "success" | "error"; text: string; serial: number };

export function useSay() {
  const [said, setSaid] = useState<Said | null>(null);
  const serial = useRef(0);
  const say = (tone: Said["tone"], text: string) => {
    serial.current += 1;
    setSaid({ tone, text, serial: serial.current });
  };
  return { said, say };
}

export function Said({ said }: { said: Said | null }) {
  return (
    <div className="settings-card-status" role="status">
      {said ? (
        <p key={said.serial} className={said.tone === "error" ? "form-error" : "form-success"}>
          {said.text}
        </p>
      ) : null}
    </div>
  );
}

const ACTION_FAILED = "That did not reach the server. Check your connection and try again.";

export function CardNotes({ group, notes }: { group: SettingGroup; notes: SettingNotes }) {
  return (
    <>
      {group.notes.includes("path_variables") ? (
        <details className="settings-note">
          <summary>Name pattern variables</summary>
          <p>{notes.path_variables}</p>
        </details>
      ) : null}
      {group.notes.includes("hardcover_app") ? <HardcoverAppGuide app={notes.hardcover_app} /> : null}
    </>
  );
}

function HardcoverAppGuide({ app }: { app: SettingNotes["hardcover_app"] }) {
  return (
    <details className="settings-note">
      <summary>How to create the Hardcover app</summary>
      <p>
        Shelfarr does not ship a shared Hardcover client. Create one at{" "}
        <a href={app.create_url} target="_blank" rel="noopener noreferrer">
          hardcover.app developer apps
        </a>{" "}
        with the scopes <code>{app.scopes}</code>, then enter its client ID above.
      </p>
      <ul className="settings-note-list">
        <li>
          <strong>With an HTTPS address:</strong> choose “Web app (server-side)”, register this exact redirect address and enter the client secret: <code className="settings-note-code">{app.redirect_uri}</code>
          {app.redirect_uri_acceptable ? null : (
            <span className="field-warning">
              {" "}
              <span aria-hidden="true">⚠ </span>Hardcover only accepts HTTPS or localhost redirect addresses. Set the redirect address under Advanced to your public HTTPS address, or use sign-in with a code.
            </span>
          )}
        </li>
        <li>
          <strong>Without an HTTPS address:</strong> choose “Mobile, desktop, or CLI”, turn on Device Authorization Grant, leave the client secret blank and turn on “Allow Sign-in With a Code”.
        </li>
      </ul>
      <p>Hardcover rate limits are per Hardcover account, so each connected person's automatic syncs use their own allowance.</p>
    </details>
  );
}

export function LibraryInventoryPanel({ inventory }: { inventory: UseQueryResult<LibraryInventory> }) {
  const sync = useLibrarySync();
  const { said, say } = useSay();
  const scope = useScope();
  const data = inventory.data;
  const start = () =>
    sync.mutate(undefined, {
      onSuccess: (outcome) => say(outcome.tone, outcome.message),
      onError: () => say("error", ACTION_FAILED),
    });
  return (
    <section className="settings-extra" aria-labelledby={`${scope}-inventory`}>
      <h4 id={`${scope}-inventory`}>{data ? `${data.platform} inventory` : "Library inventory"}</h4>
      <p className="field-hint">Shelfarr keeps a copy of the library app's contents to spot books you already have. This is separate from Shelfarr's own Library.</p>
      {inventory.isError ? (
        <p className="field-error">
          <span aria-hidden="true">⚠ </span>The inventory could not be loaded.{" "}
          <button type="button" className="button button--subtle" onClick={() => void inventory.refetch()}>
            Try again
          </button>
        </p>
      ) : !data ? (
        <p className="field-hint">Loading the inventory…</p>
      ) : (
        <>
          {data.configured && data.libraries === null ? (
            <p className="field-warning">
              <span aria-hidden="true">⚠ </span>
              {data.platform} did not answer, so its libraries cannot be listed. Enter library IDs by hand or test the connection.
            </p>
          ) : null}
          {data.inventory.count > 0 ? (
            <dl className="inventory-counts">
              <div>
                <dt>Cached</dt>
                <dd>{data.inventory.count.toLocaleString("en")}</dd>
              </div>
              <div>
                <dt>Available</dt>
                <dd>{data.inventory.available.toLocaleString("en")}</dd>
              </div>
              <div>
                <dt>Missing</dt>
                <dd>{data.inventory.missing.toLocaleString("en")}</dd>
              </div>
              <div>
                <dt>Last synced</dt>
                <dd>{data.inventory.last_synced_at ? <Time iso={data.inventory.last_synced_at} relative /> : "Never"}</dd>
              </div>
            </dl>
          ) : (
            <p className="field-hint">Nothing is cached yet. Sync to fill it.</p>
          )}
          {data.inventory.recent.length > 0 ? (
            <details className="settings-note">
              <summary>Recently synced ({data.inventory.recent.length})</summary>
              <ul className="inventory-list">
                {data.inventory.recent.map((item) => (
                  <li key={item.id}>
                    {item.url ? (
                      <a href={item.url} target="_blank" rel="noopener noreferrer">
                        {item.title}
                      </a>
                    ) : (
                      <span>{item.title}</span>
                    )}
                    {item.missing ? <span className="badge badge--down">Missing</span> : null}
                    {item.author ? <span className="field-hint"> {item.author}</span> : null}
                    {item.details.length > 0 ? <span className="inventory-details">{item.details.join(" · ")}</span> : null}
                  </li>
                ))}
              </ul>
            </details>
          ) : null}
        </>
      )}
      <div className="settings-card-actions">
        <button type="button" className="button" onClick={start} disabled={sync.isPending} aria-busy={sync.isPending}>
          {sync.isPending ? "Starting…" : "Sync now"}
        </button>
      </div>
      <Said said={said} />
    </section>
  );
}

const CHAT_STATES: Record<TelegramChat["state"], string> = { authorized: "Authorized", paused: "Paused", expired: "Code expired", pending: "Waiting for approval" };

export function TelegramChatsPanel() {
  const chats = useTelegramChats(true);
  const command = useTelegramChatCommand();
  const { said, say } = useSay();
  const scope = useScope();
  const [code, setCode] = useState("");
  const run = (input: Parameters<typeof command.mutate>[0], after?: () => void) =>
    command.mutate(input, {
      onSuccess: (answer) => {
        say(answer.outcome.tone, answer.outcome.message);
        after?.();
      },
      onError: () => say("error", ACTION_FAILED),
    });
  const approve = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    run({ kind: "approve", code: code.trim() }, () => setCode(""));
  };
  return (
    <section className="settings-extra" aria-labelledby={`${scope}-groups`}>
      <h4 id={`${scope}-groups`}>Telegram groups</h4>
      <form className="settings-inline-form" onSubmit={approve} noValidate aria-labelledby={`${scope}-groups`}>
        <div className="field">
          <label htmlFor={`${scope}-code`}>Approval code</label>
          <input
            id={`${scope}-code`}
            name="code"
            type="text"
            inputMode="numeric"
            autoComplete="one-time-code"
            maxLength={6}
            value={code}
            aria-describedby={`${scope}-code-hint`}
            onChange={(event) => setCode(event.target.value.replace(/\D/g, ""))}
          />
          <p id={`${scope}-code-hint`} className="field-hint">
            When an unknown group messages the bot, it replies with a six-digit code that lasts two minutes.
          </p>
        </div>
        <button type="submit" className="button" disabled={command.isPending}>
          Approve group
        </button>
      </form>
      {chats.isError ? (
        <p className="field-error">
          <span aria-hidden="true">⚠ </span>The groups could not be loaded.{" "}
          <button type="button" className="button button--subtle" onClick={() => void chats.refetch()}>
            Try again
          </button>
        </p>
      ) : chats.data && chats.data.length > 0 ? (
        <ul className="chat-list">
          {chats.data.map((chat) => (
            <li key={chat.id} className="chat-row">
              <span className="chat-name">
                {chat.label}
                <span className="field-hint"> {chat.chat_id}</span>
              </span>
              <span className={`badge chat-state chat-state--${chat.state}`}>{CHAT_STATES[chat.state]}</span>
              {chat.state === "authorized" || chat.state === "paused" ? (
                <span className="chat-actions">
                  {chat.state === "paused" ? (
                    <button type="button" className="button button--subtle" disabled={command.isPending} onClick={() => run({ kind: "resume", id: chat.id })}>
                      Resume<span className="sr-only"> {chat.label}</span>
                    </button>
                  ) : (
                    <button type="button" className="button button--subtle" disabled={command.isPending} onClick={() => run({ kind: "pause", id: chat.id })}>
                      Pause<span className="sr-only"> {chat.label}</span>
                    </button>
                  )}
                  <RemoveZone label={`Remove ${chat.label}`} confirmLabel="Remove group" question={`Remove ${chat.label} from Shelfarr?`} busy={command.isPending} onRemove={() => run({ kind: "remove", id: chat.id })} />
                </span>
              ) : null}
            </li>
          ))}
        </ul>
      ) : chats.data ? (
        <p className="field-hint">No groups have been approved yet.</p>
      ) : (
        <p className="field-hint">Loading groups…</p>
      )}
      <Said said={said} />
    </section>
  );
}

export function RolesReadout({ roles }: { roles: RoleRow[] }) {
  const scope = useScope();
  return (
    <section className="settings-extra" aria-labelledby={`${scope}-roles`}>
      <h4 id={`${scope}-roles`}>Members and administrators</h4>
      <div className="table-wrap">
        <table className="roles-table">
          <thead>
            <tr>
              <th scope="col">Action</th>
              <th scope="col">Member</th>
              <th scope="col">Administrator</th>
            </tr>
          </thead>
          <tbody>
            {roles.map((row) => (
              <tr key={row.action}>
                <th scope="row">{row.action}</th>
                <td>
                  {row.member}
                  {row.setting ? (
                    <>
                      {" "}
                      <Link to="/server/$category" params={{ category: row.setting.category }} hash={row.setting.group} className="roles-link">
                        Change<span className="sr-only"> who can {row.action.toLowerCase()}</span>
                      </Link>
                    </>
                  ) : null}
                </td>
                <td>{row.administrator}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}
