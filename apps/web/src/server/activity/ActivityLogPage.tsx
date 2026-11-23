import { getRouteApi, Link, useNavigate } from "@tanstack/react-router";
import { useId, useState, type FormEvent, type ReactNode } from "react";
import { failureKind } from "../../api/errors";
import { Time } from "../../components/requestText";
import { EmptyState, ErrorPanel, Loading } from "../../components/States";
import { useSession } from "../../queries";
import { useServices } from "../../services";
import { useDocumentTitle } from "../../title";
import { SettingsCard } from "../primitives";
import { useIsAdministrator } from "../queries";
import { AdministratorsOnly, NotInThisRuntime } from "../ServerCategoryPage";
import { ServerShell } from "../ServerShell";
import type { ActivityDetails, ActivityEntry, ActivityFilters, ActivityLog, ActivityPerson, ActivitySubject } from "./contract";
import { useActivityLog } from "./queries";
import "./activity.css";

const routeApi = getRouteApi("/server/system/activity");

export const ACTIVITY_CARDS = [{ id: "activity", title: "Activity log" }] as const;

const ORIGINS: Record<NonNullable<ActivityDetails["via"]>, string> = {
  web: "Requested on the web",
  api: "Requested through the API",
  telegram: "Requested from Telegram",
  hardcover: "Requested from Hardcover",
};

const MATCHES: Record<NonNullable<ActivityDetails["match"]>, string> = {
  existing: "Matched to a book already on the server",
  created: "Matched to a new book",
};

const GOOD_OUTCOMES = new Set(["login", "created", "completed"]);
const BAD_OUTCOMES = new Set(["failed", "deleted"]);

function actionTone(action: string): string {
  const outcome = action.split(".").at(-1) ?? "";
  if (GOOD_OUTCOMES.has(outcome)) return " badge--completed";
  if (BAD_OUTCOMES.has(outcome)) return " badge--failed";
  return "";
}

function filtering(filters: ActivityFilters): boolean {
  return Boolean(filters.user || filters.action || filters.from);
}

export function ActivityLogCard() {
  return (
    <SettingsCard id="activity" headingId="activity-card-heading" title="Activity log" summary="Sign-ins, requests, uploads and account changes on this server, newest first.">
      <div className="settings-card-actions">
        <Link to="/server/system/activity" className="button">
          Open the activity log
        </Link>
      </div>
    </SettingsCard>
  );
}

export function ActivityLogPage() {
  const { mode } = useServices();
  if (mode !== "rails") return <NotInThisRuntime />;
  return <ActivityView />;
}

function ActivityView() {
  const filters = routeApi.useSearch();
  const session = useSession();
  const admin = useIsAdministrator();
  const activity = useActivityLog(filters);
  const fresh = activity.isPlaceholderData ? undefined : activity.data;
  const [known, setKnown] = useState(fresh);
  if (fresh && fresh !== known) setKnown(fresh);
  const shown = activity.data ?? known;
  useDocumentTitle("Activity log · Server");

  const body =
    session.isError && !session.data ? (
      <ErrorPanel error={session.error} onRetry={() => void session.refetch()} />
    ) : !session.data ? (
      <Loading label="Loading the activity log…" />
    ) : !admin || (activity.isError && failureKind(activity.error) === "not_found") ? (
      <AdministratorsOnly />
    ) : shown ? (
      <ActivityBody log={shown} filters={filters} current={Boolean(fresh)} failure={activity.isError ? activity.error : null} onRetry={() => void activity.refetch()} />
    ) : activity.isError ? (
      <ErrorPanel error={activity.error} onRetry={() => void activity.refetch()} />
    ) : (
      <Loading label="Loading the activity log…" />
    );

  return (
    <ServerShell current="system" settings={undefined} headingId="activity-heading" title="Activity log" summary="Sign-ins, requests, uploads and account changes on this server, newest first." rail={admin}>
      <p className="activity-back">
        <Link to="/server/$category" params={{ category: "system" }}>
          <span aria-hidden="true">← </span>System
        </Link>
      </p>
      {body}
    </ServerShell>
  );
}

function ActivityBody({ log, filters, current, failure, onRetry }: { log: ActivityLog; filters: ActivityFilters; current: boolean; failure: unknown; onRetry: () => void }) {
  return (
    <>
      <FilterForm key={`${filters.user ?? ""}|${filters.action ?? ""}|${filters.from ?? ""}`} log={log} filters={filters} />
      <p className="result-count activity-count" role="status">
        {failure ? "The activity log could not be loaded." : current ? countText(log) : ""}
      </p>
      {failure ? (
        <ErrorPanel error={failure} onRetry={onRetry} />
      ) : !current ? (
        <Loading label="Loading the activity log…" />
      ) : log.entries.length === 0 ? (
        <NoEntries filtered={filtering(filters)} />
      ) : (
        <EntryTable entries={log.entries} />
      )}
    </>
  );
}

function countText(log: ActivityLog): string {
  if (log.entries.length === 0) return "No entries";
  if (log.more) return `Showing the ${log.limit} most recent entries. Narrow the filters to see older ones.`;
  return log.entries.length === 1 ? "1 entry" : `${log.entries.length} entries`;
}

function NoEntries({ filtered }: { filtered: boolean }) {
  if (!filtered) {
    return (
      <EmptyState title="No activity yet">
        <p>Activity will appear here as people use the server.</p>
      </EmptyState>
    );
  }
  return (
    <EmptyState title="No activity matches these filters">
      <p>
        <Link to="/server/system/activity">Show all activity</Link>
      </p>
    </EmptyState>
  );
}

function personLabel(person: ActivityPerson): string {
  return person.removed ? `${person.name} (removed)` : person.name;
}

function FilterForm({ log, filters }: { log: ActivityLog; filters: ActivityFilters }) {
  const navigate = useNavigate();
  const id = useId();
  const [user, setUser] = useState(filters.user ?? "");
  const [action, setAction] = useState(filters.action ?? "");
  const [from, setFrom] = useState(filters.from ?? "");
  const knownUser = !filters.user || log.people.some((person) => person.id === filters.user);
  const actions = filters.action && !log.actions.includes(filters.action) ? [...log.actions, filters.action] : log.actions;

  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const next: ActivityFilters = {};
    if (user) next.user = user;
    if (action) next.action = action;
    if (from) next.from = from;
    void navigate({ to: "/server/system/activity", search: next });
  };

  return (
    <search className="activity-filters">
      <form onSubmit={submit} aria-labelledby={`${id}-legend`}>
        <h2 id={`${id}-legend`} className="sr-only">
          Filter the activity log
        </h2>
        <div className="activity-fields">
          <div className="field">
            <label htmlFor={`${id}-user`}>Person</label>
            <select id={`${id}-user`} name="user" value={user} onChange={(event) => setUser(event.target.value)}>
              <option value="">Everyone</option>
              {log.people.map((person) => (
                <option key={person.id} value={person.id}>
                  {personLabel(person)}
                </option>
              ))}
              {knownUser ? null : <option value={filters.user}>Someone no longer on this server</option>}
            </select>
          </div>
          <div className="field">
            <label htmlFor={`${id}-action`}>Action</label>
            <select id={`${id}-action`} name="action" value={action} onChange={(event) => setAction(event.target.value)}>
              <option value="">All actions</option>
              {actions.map((entry) => (
                <option key={entry} value={entry}>
                  {entry}
                </option>
              ))}
            </select>
          </div>
          <div className="field">
            <label htmlFor={`${id}-from`}>From</label>
            <input id={`${id}-from`} name="from" type="date" value={from} aria-describedby={`${id}-from-hint`} onChange={(event) => setFrom(event.target.value)} />
            <p id={`${id}-from-hint`} className="field-hint">
              Entries from the start of this day, in UTC.
            </p>
          </div>
        </div>
        <div className="settings-card-actions">
          <button type="submit" className="button button--primary">
            Filter
          </button>
          {filtering(filters) ? (
            <Link to="/server/system/activity" className="button button--subtle" activeOptions={{ exact: true, includeSearch: true }}>
              Clear filters
            </Link>
          ) : null}
        </div>
      </form>
    </search>
  );
}

function EntryTable({ entries }: { entries: ActivityEntry[] }) {
  const captionId = useId();
  return (
    <div className="activity-table" role="region" aria-labelledby={captionId} tabIndex={0}>
      <table>
        <caption id={captionId} className="sr-only">
          Activity, newest first
        </caption>
        <thead>
          <tr>
            <th scope="col">Time</th>
            <th scope="col">Person</th>
            <th scope="col">Action</th>
            <th scope="col">Details</th>
          </tr>
        </thead>
        <tbody>
          {entries.map((entry) => (
            <tr key={entry.id}>
              <th scope="row" data-label="Time">
                <Time iso={entry.at} />
              </th>
              <td data-label="Person">{entry.actor ? <PersonName person={entry.actor} /> : "System"}</td>
              <td data-label="Action">
                <span className={`badge activity-action${actionTone(entry.action)}`}>{entry.action}</span>
              </td>
              <td data-label="Details">
                <Details entry={entry} />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function PersonName({ person }: { person: ActivityPerson }) {
  if (person.removed) return <>{personLabel(person)}</>;
  return (
    <Link to="/server/people/users/$userId" params={{ userId: person.id }}>
      {person.name}
    </Link>
  );
}

function Subject({ subject }: { subject: ActivitySubject }): ReactNode {
  switch (subject.kind) {
    case "request":
      return (
        <Link to="/requests/$requestId" params={{ requestId: subject.id }}>
          {subject.title}
        </Link>
      );
    case "person":
      return <PersonName person={subject} />;
    case "book":
      return subject.in_library ? (
        <Link to="/library/$publicationId" params={{ publicationId: subject.id }}>
          {subject.title}
        </Link>
      ) : (
        subject.title
      );
    case "other":
      return subject.title;
  }
}

function facts(details: ActivityDetails): string[] {
  const lines: string[] = [];
  if (details.via) lines.push(ORIGINS[details.via]);
  if (details.match) lines.push(MATCHES[details.match]);
  if (details.scopes?.length) lines.push(`Scopes: ${details.scopes.join(", ")}`);
  return lines;
}

function Details({ entry }: { entry: ActivityEntry }) {
  const lines = facts(entry.details);
  if (!entry.subject && lines.length === 0) return null;
  return (
    <span className="activity-details">
      {entry.subject ? (
        <span className="activity-subject">
          <Subject subject={entry.subject} />
        </span>
      ) : null}
      {lines.map((line) => (
        <span key={line} className="activity-fact">
          {line}
        </span>
      ))}
    </span>
  );
}
