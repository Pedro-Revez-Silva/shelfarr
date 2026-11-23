import type { UseQueryResult } from "@tanstack/react-query";
import { useQueryClient } from "@tanstack/react-query";
import { useCallback, useEffect, useRef, useState, type FormEvent, type ReactNode } from "react";
import { useServices } from "../../services";
import { useServerKeys } from "../queries";
import { failureKind, isApiError, unconfirmed } from "../../api/errors";
import { ErrorPanel, Loading } from "../../components/States";
import { same, type DraftValue, type Drafts } from "../draft";
import { Said, useSay } from "../extras";
import { AdvancedSection, CardActions, HealthStatus, RemoveZone, SettingControl, SettingsCard, TestResult, useScope, type TestOutcome } from "../primitives";
import { useDownloads, useDownloadsCommand, type DownloadsCommand } from "./api";
import type { DownloadClient, Downloads, RoutingRule } from "./contract";
import {
  NAME_FIELD,
  RULE_KEYS,
  changedKeys,
  clientFields,
  clientKeys,
  clientSubmission,
  clientsOfKind,
  fieldErrors,
  fieldLabel,
  initialClientDraft,
  initialRuleDraft,
  kindLabel,
  ruleTypeChange,
  sameTypeNeighbours,
  submission,
} from "./forms";

export const DOWNLOAD_CARDS = [
  { id: "download_clients", title: "Download clients" },
  { id: "routing_rules", title: "Routing rules" },
] as const;

export type DirtyReporter = (id: string, dirty: boolean) => void;
export type RemovalMarker = (id: string, removing: boolean) => void;
export type Say = ReturnType<typeof useSay>["say"];

export const CHANGED_ELSEWHERE = "Nothing was saved: this was changed somewhere else after you opened it. Your edits are kept; once the latest values are shown here, check them and save again.";
export const REMOVED_ELSEWHERE = "Nothing was removed: this was changed somewhere else after you opened it. Close it and open it again to see what removing it would remove now.";
const ONLY_HIDDEN_EDITS = "There is nothing to save: your changes are only to fields this type does not use.";

export function commandFailureText(error: unknown): string {
  if (unconfirmed(error)) return "Shelfarr could not confirm whether this went through. The list has been read again; check it before trying again.";
  if (!isApiError(error)) return "Shelfarr could not confirm whether this went through. Reload the page to check.";
  switch (error.kind) {
    case "csrf":
      return "This page was out of date. Nothing was changed; try again.";
    case "not_found":
      return "It is no longer there, or you are no longer an administrator. Nothing was changed; the list has been read again.";
    case "invalid":
      return `The server did not accept this: ${error.message} Nothing was changed.`;
    default:
      return "The server did not accept this. Nothing was changed; reload the page and try again.";
  }
}

const FOCUS_WAIT_MS = 2_000;

export function focusSoon(find: () => HTMLElement | null | undefined, deadline = Date.now() + FOCUS_WAIT_MS) {
  requestAnimationFrame(() => {
    const target = find();
    if (target && !target.matches(":disabled")) target.focus();
    else if (Date.now() < deadline) focusSoon(find, deadline);
  });
}

export function DownloadManagement({ onDirtyChange }: { onDirtyChange: DirtyReporter }) {
  const downloads = useDownloads();
  return (
    <>
      <ClientsCard query={downloads} onDirtyChange={onDirtyChange} />
      <RulesCard query={downloads} onDirtyChange={onDirtyChange} />
    </>
  );
}

export function useEditVersion(live: string) {
  const [version, setVersion] = useState(live);
  const [awaiting, setAwaiting] = useState<string | null>(null);
  useEffect(() => {
    if (awaiting !== null && live === awaiting) {
      setVersion(live);
      setAwaiting(null);
    }
  }, [awaiting, live]);
  const restart = () => {
    setVersion(live);
    setAwaiting(null);
  };
  return { version, restart, adoptOnceShown: setAwaiting };
}

export function useLostDraftNotice(records: { id: string; name: string }[] | undefined, prefix: string, say: Say, onDirtyChange: DirtyReporter) {
  const dirty = useRef(new Set<string>());
  const removing = useRef(new Set<string>());
  const seen = useRef<{ id: string; name: string }[] | undefined>(undefined);
  const lost = useRef<string[]>([]);
  if (records && records !== seen.current) {
    const present = new Set(records.map((record) => record.id));
    for (const record of seen.current ?? []) {
      const id = `${prefix}-${record.id}`;
      if (!present.has(record.id) && dirty.current.has(id) && !removing.current.has(id)) lost.current.push(record.name);
    }
    seen.current = records;
  }
  useEffect(() => {
    if (lost.current.length === 0) return;
    say("error", `${lost.current.join(", ")} ${lost.current.length === 1 ? "was" : "were"} removed somewhere else, so your unsaved changes to ${lost.current.length === 1 ? "it were" : "them were"} discarded.`);
    lost.current = [];
  });
  const track = useCallback<DirtyReporter>(
    (id, isDirty) => {
      if (isDirty) dirty.current.add(id);
      else dirty.current.delete(id);
      onDirtyChange(id, isDirty);
    },
    [onDirtyChange],
  );
  const markRemoving = useCallback<RemovalMarker>((id, isRemoving) => {
    if (isRemoving) removing.current.add(id);
    else removing.current.delete(id);
  }, []);
  return { track, markRemoving };
}

export function useRevalidateAccessWhenDenied(denied: boolean) {
  const { keys } = useServices();
  const settingsKey = useServerKeys().settings;
  const client = useQueryClient();
  const revalidate = useRef(() => {});
  revalidate.current = () => {
    void client.invalidateQueries({ queryKey: settingsKey });
    void client.invalidateQueries({ queryKey: keys.session });
  };
  useEffect(() => {
    if (denied) revalidate.current();
  }, [denied]);
}

export function CardBody<T>({ query, label, denied = "Only administrators can manage download clients.", children }: { query: UseQueryResult<T>; label: string; denied?: string; children: (data: T) => ReactNode }) {
  if (query.isError && failureKind(query.error) === "not_found") return <p className="field-hint">{denied}</p>;
  if (query.data) {
    return (
      <>
        {query.isError ? (
          <p className="refresh-problem" role="alert">
            <span aria-hidden="true">⚠ </span>The latest list could not be loaded. This shows what was last read.{" "}
            <button type="button" className="button button--subtle" onClick={() => void query.refetch()}>
              Try again
            </button>
          </p>
        ) : null}
        {children(query.data)}
      </>
    );
  }
  if (query.isError) return <ErrorPanel error={query.error} onRetry={() => void query.refetch()} />;
  return <Loading label={label} />;
}

function ClientsCard({ query, onDirtyChange }: { query: UseQueryResult<Downloads>; onDirtyChange: DirtyReporter }) {
  const scope = useScope();
  const headingId = `${scope}-heading`;
  const { said, say } = useSay();
  const [adding, setAdding] = useState(false);
  const addButton = useRef<HTMLButtonElement>(null);
  const denied = query.isError && failureKind(query.error) === "not_found";
  const health = denied ? undefined : query.data?.health;
  useRevalidateAccessWhenDenied(denied);
  const { track: trackDirty, markRemoving } = useLostDraftNotice(query.data?.clients, "client", say, onDirtyChange);
  return (
    <SettingsCard
      id="download_clients"
      headingId={headingId}
      title="Download clients"
      summary="Shelfarr sends each download to the first enabled client of the right kind that answers, lowest priority first. Move changes the order among clients of the same type."
      status={health ? <HealthStatus status={health.status} checkedAt={health.checked_at ?? undefined} message={health.message ?? undefined} /> : undefined}
    >
      <CardBody query={query} label="Loading the download clients…">
        {(data) => (
          <>
            {data.clients.length === 0 ? <p className="field-hint">No download clients yet. Add one so Shelfarr can fetch the books it finds.</p> : null}
            {data.clients.length > 0 ? (
              <ul className="record-list" aria-label="Download clients, torrent first, then usenet">
                {[...clientsOfKind(data, "torrent"), ...clientsOfKind(data, "usenet")].map((client) => (
                  <ClientRow key={client.id} client={client} downloads={data} say={say} onDirtyChange={trackDirty} onRemoving={markRemoving} onRemoved={() => focusSoon(() => document.getElementById("download_clients"))} />
                ))}
              </ul>
            ) : null}
            {adding ? (
              <ClientForm
                client={null}
                version={null}
                downloads={data}
                say={say}
                onDirtyChange={onDirtyChange}
                onClose={(created) => {
                  setAdding(false);
                  focusSoon(() => (created ? document.getElementById(`download-client-${created}`) : addButton.current));
                }}
              />
            ) : (
              <p>
                <button ref={addButton} type="button" className="button" onClick={() => setAdding(true)}>
                  Add a download client
                </button>
              </p>
            )}
          </>
        )}
      </CardBody>
      {denied ? null : <Said said={said} />}
    </SettingsCard>
  );
}

function typeLabel(downloads: Downloads, value: string): string {
  return downloads.client_types.find((type) => type.value === value)?.label ?? value;
}

function ClientRow({ client, downloads, say, onDirtyChange, onRemoving, onRemoved }: { client: DownloadClient; downloads: Downloads; say: Say; onDirtyChange: DirtyReporter; onRemoving: RemovalMarker; onRemoved: () => void }) {
  const [editing, setEditing] = useState(false);
  const { version, restart, adoptOnceShown } = useEditVersion(client.version);
  const [test, setTest] = useState<TestOutcome | null>(null);
  const [formDirty, setFormDirty] = useState(false);
  const command = useDownloadsCommand();
  const moveButtons = useRef(new Map<string, HTMLButtonElement>());
  const neighbours = sameTypeNeighbours(downloads.clients, client);
  const label = typeLabel(downloads, client.client_type);
  const rowId = `download-client-${client.id}`;
  const reportDirty = useCallback<DirtyReporter>(
    (id, dirty) => {
      setFormDirty(dirty);
      onDirtyChange(id, dirty);
    },
    [onDirtyChange],
  );

  const toggle = () => {
    if (!editing) {
      restart();
      setEditing(true);
    } else if (formDirty) {
      say("error", `Save or discard the changes to ${client.name} before closing it.`);
    } else {
      setEditing(false);
    }
  };

  const move = (direction: "up" | "down") => {
    const neighbour = direction === "up" ? neighbours.above : neighbours.below;
    if (command.isPending || !neighbour) return;
    command.mutate(
      { kind: "move_client", id: client.id, version: client.version, neighbour, direction },
      {
        onSuccess: (answer) => {
          if (answer.kind === "changed") {
            say("error", `${client.name} or the client next to it was changed somewhere else, so nothing was moved. Check the order shown, then move it again.`);
            return;
          }
          if (answer.kind !== "done") return;
          if (!answer.action.moved) {
            say(answer.action.outcome.tone, answer.action.outcome.message);
            return;
          }
          const moved = answer.action.clients.find((entry) => entry.id === client.id);
          if (moved) {
            const place = sameTypeNeighbours(answer.action.clients, moved);
            say("success", `${client.name} is now ${place.position} of ${place.total} ${label} clients.`);
            const next = place[direction] ? direction : direction === "up" ? "down" : "up";
            focusSoon(() => moveButtons.current.get(next));
          }
        },
        onError: (error) => say("error", commandFailureText(error)),
      },
    );
  };

  const runTest = () => {
    if (command.isPending) return;
    command.mutate(
      { kind: "test_client", id: client.id },
      {
        onSuccess: (answer) => {
          if (answer.kind !== "done") return;
          setTest({ tone: answer.action.outcome.tone, message: answer.action.outcome.message, at: new Date(), note: editing && formDirty ? "This tested the saved settings, not your unsaved changes." : undefined });
        },
        onError: (error) => setTest({ tone: "error", message: commandFailureText(error), at: new Date() }),
      },
    );
  };

  const testing = command.isPending && command.variables?.kind === "test_client";
  const moving = command.isPending && command.variables?.kind === "move_client";

  return (
    <li className="record" aria-labelledby={`${rowId}-name`}>
      <div className="record-summary">
        <h5 id={`${rowId}-name`} className="record-name">
          <span id={rowId} tabIndex={-1}>
            {client.name}
          </span>
        </h5>
        <p className="record-facts">
          <span className="badge">{label}</span>
          <span className="badge">{kindLabel(client.kind)}</span>
          {client.enabled ? null : <span className="badge record-off">Turned off</span>}
          <span>Priority {client.priority + 1}</span>
          {client.rule_count > 0 ? <span>{client.rule_count === 1 ? "1 routing rule" : `${client.rule_count} routing rules`}</span> : null}
        </p>
        <p className="record-address">{client.url}</p>
      </div>
      <div className="record-actions">
        <button id={`${rowId}-edit`} type="button" className="button" aria-expanded={editing} aria-controls={`${rowId}-form`} aria-describedby={`${rowId}-name`} onClick={toggle}>
          Edit
        </button>
        <button type="button" className="button" aria-busy={testing} aria-describedby={`${rowId}-name`} onClick={runTest}>
          {testing ? "Testing…" : "Test"}
        </button>
        <span className="order-buttons">
          {(["up", "down"] as const).map((direction) => (
            <button
              key={direction}
              ref={(element) => void (element ? moveButtons.current.set(direction, element) : moveButtons.current.delete(direction))}
              type="button"
              className="button button--subtle order-button"
              disabled={!neighbours[direction]}
              aria-busy={moving}
              aria-label={`Move ${client.name} ${direction}`}
              onClick={() => move(direction)}
            >
              {direction === "up" ? "↑" : "↓"}
            </button>
          ))}
        </span>
      </div>
      <div className="record-status" role="status">
        <TestResult result={test} />
      </div>
      {editing ? (
        <div id={`${rowId}-form`} className="record-editor">
          <ClientForm
            client={client}
            version={version}
            downloads={downloads}
            say={say}
            labelledBy={`${rowId}-name`}
            onVersion={adoptOnceShown}
            onDirtyChange={reportDirty}
            onRemoving={onRemoving}
            onClose={(_, removed) => {
              setEditing(false);
              if (removed) onRemoved();
              else focusSoon(() => document.getElementById(`${rowId}-edit`));
            }}
          />
        </div>
      ) : null}
    </li>
  );
}

export function useRecordForm(dirtyId: string, keysOf: (drafts: Drafts) => string[], initial: Drafts, onDirtyChange: DirtyReporter) {
  const [edits, setEdits] = useState<Drafts>({});
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [general, setGeneral] = useState<string | null>(null);
  const { said, say } = useSay();
  const drafts: Drafts = { ...initial, ...edits };
  const keys = keysOf(drafts);
  const changed = changedKeys(keys, drafts, initial);
  const stray = Object.keys(edits).filter((key) => !keys.includes(key) && !same(edits[key], initial[key]));
  const dirty = changed.length > 0 || stray.length > 0;
  useEffect(() => onDirtyChange(dirtyId, dirty), [dirtyId, dirty, onDirtyChange]);
  useEffect(() => () => onDirtyChange(dirtyId, false), [dirtyId, onDirtyChange]);
  const edit = (key: string, value: DraftValue) => {
    setEdits((current) => ({ ...current, [key]: value }));
    if (errors[key]) setErrors(({ [key]: _cleared, ...rest }) => rest);
  };
  const replace = (next: Drafts) => setEdits(Object.fromEntries(Object.entries(next).filter(([key, value]) => value !== initial[key])));
  const reject = (answer: { errors: { field: string; message: string }[] }, known: string[], focus: (key: string) => void) => {
    const { byField, general: rest } = fieldErrors(answer.errors, known);
    setErrors(byField);
    setGeneral(rest.length > 0 ? rest.join(" ") : null);
    say("error", "Nothing was saved. Check the marked fields.");
    const first = known.find((key) => byField[key]);
    if (first) focus(first);
  };
  const clear = () => {
    setErrors({});
    setGeneral(null);
  };
  return { drafts, keys, changed, stray, dirty, edits, setEdits, errors, general, setGeneral, edit, replace, reject, clear, said, say };
}

export function FormProblem({ text }: { text: string | null }) {
  if (!text) return null;
  return (
    <p className="field-error" role="alert">
      <span aria-hidden="true">⚠ </span>
      {text}
    </p>
  );
}

function SelectField({ id, label, value, options, hint, error, placeholder, onChange }: { id: string; label: string; value: string; options: { value: string; label: string }[]; hint: string; error?: string | undefined; placeholder?: string; onChange: (value: string) => void }) {
  const known = options.some((option) => option.value === value);
  return (
    <div className="field">
      <label htmlFor={id}>{label}</label>
      <select id={id} name={id} value={value} aria-invalid={error ? true : undefined} aria-describedby={[`${id}-hint`, error ? `${id}-error` : ""].filter(Boolean).join(" ")} onChange={(event) => onChange(event.target.value)}>
        {placeholder !== undefined ? <option value="">{placeholder}</option> : null}
        {!known && value !== "" ? <option value={value}>{value}</option> : null}
        {options.map((option) => (
          <option key={option.value} value={option.value}>
            {option.label}
          </option>
        ))}
      </select>
      <p id={`${id}-hint`} className="field-hint">
        {hint}
      </p>
      {error ? (
        <p id={`${id}-error`} className="field-error">
          <span aria-hidden="true">⚠ </span>
          {error}
        </p>
      ) : null}
    </div>
  );
}

function ClientForm({
  client,
  version,
  downloads,
  say,
  labelledBy,
  onVersion,
  onDirtyChange,
  onRemoving,
  onClose,
}: {
  client: DownloadClient | null;
  version: string | null;
  downloads: Downloads;
  say: Say;
  labelledBy?: string;
  onVersion?: (version: string) => void;
  onDirtyChange: DirtyReporter;
  onRemoving?: RemovalMarker;
  onClose: (created: string | null, removed?: boolean) => void;
}) {
  const scope = useScope();
  const formRef = useRef<HTMLFormElement>(null);
  const [advancedOpen, setAdvancedOpen] = useState(false);
  const [confirmedRules] = useState<string[]>(client?.rule_ids ?? []);
  const [removalVersion] = useState(version);
  const command = useDownloadsCommand();
  const initial = initialClientDraft(client, downloads.defaults);
  const chosenType = (drafts: Drafts) => downloads.client_types.find((type) => type.value === drafts.client_type);
  const form = useRecordForm(client ? `client-${client.id}` : "client-new", (drafts) => clientKeys(chosenType(drafts), client), initial, onDirtyChange);
  const { keys, changed, dirty } = form;
  const type = chosenType(form.drafts);
  const { basic, advanced } = clientFields(type, client);
  const headingId = labelledBy ?? `${scope}-heading`;

  useEffect(() => {
    formRef.current?.querySelector<HTMLElement>("input, select")?.focus();
  }, []);

  const focusField = (key: string) => {
    if (advanced.some((entry) => entry.key === key)) setAdvancedOpen(true);
    focusSoon(() => {
      const id = `${scope}-${key}`;
      return formRef.current?.querySelector<HTMLElement>(`#${CSS.escape(id)}`) ?? formRef.current?.querySelector<HTMLElement>(`[aria-describedby^="${CSS.escape(id)}-"]`);
    });
  };

  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (command.isPending) return;
    form.clear();
    if (client && !dirty) {
      form.say("success", "There are no changes to save.");
      return;
    }
    if (client && changed.length === 0) {
      form.say("error", ONLY_HIDDEN_EDITS);
      return;
    }
    const values = clientSubmission(type, client, form.drafts, initial);
    const request: DownloadsCommand = client && version ? { kind: "update_client", id: client.id, version, values } : { kind: "create_client", values };
    command.mutate(request, {
      onSuccess: (answer) => {
        if (answer.kind === "rejected") return form.reject(answer, keys, focusField);
        if (answer.kind === "changed") {
          const fresh = client ? answer.downloads.clients.find((entry) => entry.id === client.id) : undefined;
          if (fresh) onVersion?.(fresh.version);
          form.setGeneral(fresh ? CHANGED_ELSEWHERE : "This client was removed somewhere else. Nothing was saved.");
          return;
        }
        say(answer.action.outcome.tone, answer.action.outcome.message);
        form.setEdits({});
        onClose(answer.action.created ?? null);
      },
      onError: (error) => form.setGeneral(commandFailureText(error)),
    });
  };

  const remove = () => {
    if (!client || !removalVersion || command.isPending) return;
    const dirtyId = `client-${client.id}`;
    onRemoving?.(dirtyId, true);
    command.mutate(
      { kind: "remove_client", id: client.id, version: removalVersion, rules: confirmedRules },
      {
        onSuccess: (answer) => {
          if (answer.kind === "changed") {
            onRemoving?.(dirtyId, false);
            form.setGeneral(REMOVED_ELSEWHERE);
            return;
          }
          if (answer.kind !== "done") return;
          say(answer.action.outcome.tone, answer.action.outcome.message);
          onClose(null, true);
        },
        onError: (error) => {
          onRemoving?.(dirtyId, false);
          form.setGeneral(commandFailureText(error));
        },
      },
    );
  };

  const control = (field: (typeof basic)[number]) => (
    <SettingControl key={field.key} scope={scope} field={field} value={form.drafts[field.key] ?? ""} onChange={(value) => form.edit(field.key, value)} error={form.errors[field.key]} />
  );
  const advancedChanged = advanced.filter((entry) => changed.includes(entry.key)).length;
  const saving = command.isPending && (command.variables?.kind === "create_client" || command.variables?.kind === "update_client");
  const rules = confirmedRules.length;
  const strandedRules = client && type && client.rule_count > 0 && type.kind !== client.kind ? client.rule_count : 0;

  return (
    <form ref={formRef} className="settings-form record-form" method="post" noValidate aria-labelledby={headingId} onSubmit={submit}>
      {client ? null : <h4 id={headingId}>New download client</h4>}
      <fieldset className="record-fields" disabled={command.isPending}>
      {control(NAME_FIELD)}
      <SelectField
        id={`${scope}-client_type`}
        label="Type"
        value={String(form.drafts.client_type ?? "")}
        options={downloads.client_types.map((entry) => ({ value: entry.value, label: `${entry.label} (${entry.kind})` }))}
        hint={
          strandedRules > 0
            ? `The fields below change with the type. This client has ${strandedRules === 1 ? "a routing rule" : `${strandedRules} routing rules`} for ${client?.kind} downloads, which ${strandedRules === 1 ? "is" : "are"} skipped once it is a ${type?.kind} client.`
            : "The fields below change with the type."
        }
        error={form.errors.client_type}
        onChange={(value) => form.edit("client_type", value)}
      />
      {basic.map(control)}
      {form.stray.length > 0 ? (
        <p className="field-warning">
          <span aria-hidden="true">⚠ </span>
          Your changes to {form.stray.map(fieldLabel).join(", ")} are not used by {type?.label ?? "this type of"} clients and will not be saved.
        </p>
      ) : null}
      {client?.url_hidden ? <p className="field-hint">The saved address has a sign-in or other parts that are not shown. Leave the address unchanged to keep them.</p> : null}
      <AdvancedSection count={advanced.length} changed={advancedChanged} open={advancedOpen || advanced.some((entry) => form.errors[entry.key])} onToggle={setAdvancedOpen}>
        {advanced.map(control)}
      </AdvancedSection>
      </fieldset>
      <FormProblem text={form.general} />
      <CardActions unsaved={dirty}>
        <button type="submit" className="button button--primary" aria-busy={saving}>
          {saving ? "Saving…" : client ? "Save" : "Add client"}
        </button>
        <button type="button" className="button button--subtle" disabled={command.isPending} onClick={() => onClose(null)}>
          {dirty ? "Discard changes" : "Cancel"}
        </button>
      </CardActions>
      <div className="settings-card-status" role="status">
        {form.said ? (
          <p key={form.said.serial} className={form.said.tone === "error" ? "form-error" : "form-success"}>
            {form.said.text}
          </p>
        ) : null}
      </div>
      {client ? (
        <div className="record-remove">
          <RemoveZone
            label="Remove client"
            confirmLabel="Remove"
            question={rules > 0 ? `Remove ${client.name}? Its ${rules === 1 ? "routing rule is" : `${rules} routing rules are`} removed too.` : `Remove ${client.name}?`}
            busy={command.isPending}
            onRemove={remove}
          />
        </div>
      ) : null}
    </form>
  );
}

function RulesCard({ query, onDirtyChange }: { query: UseQueryResult<Downloads>; onDirtyChange: DirtyReporter }) {
  const scope = useScope();
  const headingId = `${scope}-heading`;
  const { said, say } = useSay();
  const [adding, setAdding] = useState(false);
  const addButton = useRef<HTMLButtonElement>(null);
  const denied = query.isError && failureKind(query.error) === "not_found";
  const ruleRecords = useRuleRecords(query.data?.rules);
  const { track: trackDirty, markRemoving } = useLostDraftNotice(ruleRecords, "rule", say, onDirtyChange);
  return (
    <SettingsCard
      id="routing_rules"
      headingId={headingId}
      title="Routing rules"
      summary="When a chosen result comes from this indexer, Shelfarr tries this client first and then the others in priority order. Indexer names match regardless of capitals and spacing. A rule is skipped while it or its client is turned off."
    >
      <CardBody query={query} label="Loading the routing rules…">
        {(data) => (
          <>
            {data.rules.length === 0 ? <p className="field-hint">No routing rules. Every download goes to the clients in priority order.</p> : (
              <ul className="record-list">
                {data.rules.map((rule) => (
                  <RuleRow key={rule.id} rule={rule} downloads={data} say={say} onDirtyChange={trackDirty} onRemoving={markRemoving} onRemoved={() => focusSoon(() => document.getElementById("routing_rules"))} />
                ))}
              </ul>
            )}
            {adding ? (
              <RuleForm
                rule={null}
                version={null}
                downloads={data}
                say={say}
                onDirtyChange={onDirtyChange}
                onClose={(created) => {
                  setAdding(false);
                  focusSoon(() => (created ? document.getElementById(`routing-rule-${created}`) : addButton.current));
                }}
              />
            ) : (
              <p>
                <button ref={addButton} type="button" className="button" disabled={data.clients.length === 0} aria-describedby={data.clients.length === 0 ? `${scope}-none` : undefined} onClick={() => setAdding(true)}>
                  Add a routing rule
                </button>
                {data.clients.length === 0 ? (
                  <span id={`${scope}-none`} className="field-hint">
                    {" "}
                    Add a download client first.
                  </span>
                ) : null}
              </p>
            )}
          </>
        )}
      </CardBody>
      {denied ? null : <Said said={said} />}
    </SettingsCard>
  );
}

function useRuleRecords(rules: RoutingRule[] | undefined) {
  const cache = useRef<{ source: RoutingRule[] | undefined; records: { id: string; name: string }[] | undefined }>({ source: undefined, records: undefined });
  if (rules !== cache.current.source) cache.current = { source: rules, records: rules?.map((rule) => ({ id: rule.id, name: `The rule for ${rule.indexer_name}` })) };
  return cache.current.records;
}

function RuleRow({ rule, downloads, say, onDirtyChange, onRemoving, onRemoved }: { rule: RoutingRule; downloads: Downloads; say: Say; onDirtyChange: DirtyReporter; onRemoving: RemovalMarker; onRemoved: () => void }) {
  const [editing, setEditing] = useState(false);
  const { version, restart, adoptOnceShown } = useEditVersion(rule.version);
  const [formDirty, setFormDirty] = useState(false);
  const rowId = `routing-rule-${rule.id}`;
  const reportDirty = useCallback<DirtyReporter>(
    (id, dirty) => {
      setFormDirty(dirty);
      onDirtyChange(id, dirty);
    },
    [onDirtyChange],
  );
  const toggle = () => {
    if (!editing) {
      restart();
      setEditing(true);
    } else if (formDirty) {
      say("error", `Save or discard the changes to the rule for ${rule.indexer_name} before closing it.`);
    } else {
      setEditing(false);
    }
  };
  const kind = downloads.download_types.find((entry) => entry.value === rule.download_type)?.label ?? rule.download_type;
  return (
    <li className="record" aria-labelledby={`${rowId}-name`}>
      <div className="record-summary">
        <h5 id={`${rowId}-name`} className="record-name">
          <span id={rowId} tabIndex={-1}>
            {rule.indexer_name}
          </span>
        </h5>
        <p className="record-facts">
          <span className="badge">{rule.provider_label}</span>
          <span className="badge">{kind}</span>
          {rule.enabled ? null : <span className="badge record-off">Turned off</span>}
        </p>
        <p className="record-address">
          Sends to {rule.client_name}
          {rule.client_kind !== rule.download_type ? (
            <span className="field-warning">
              {" "}
              <span aria-hidden="true">⚠ </span>That client now takes {rule.client_kind} downloads, so this rule is skipped.
            </span>
          ) : rule.client_enabled ? null : (
            <span className="field-warning">
              {" "}
              <span aria-hidden="true">⚠ </span>That client is turned off, so this rule is skipped.
            </span>
          )}
        </p>
      </div>
      <div className="record-actions">
        <button id={`${rowId}-edit`} type="button" className="button" aria-expanded={editing} aria-controls={`${rowId}-form`} aria-describedby={`${rowId}-name`} onClick={toggle}>
          Edit
        </button>
      </div>
      {editing ? (
        <div id={`${rowId}-form`} className="record-editor">
          <RuleForm
            rule={rule}
            version={version}
            downloads={downloads}
            say={say}
            labelledBy={`${rowId}-name`}
            onVersion={adoptOnceShown}
            onDirtyChange={reportDirty}
            onRemoving={onRemoving}
            onClose={(_, removed) => {
              setEditing(false);
              if (removed) onRemoved();
              else focusSoon(() => document.getElementById(`${rowId}-edit`));
            }}
          />
        </div>
      ) : null}
    </li>
  );
}

function RuleForm({
  rule,
  version,
  downloads,
  say,
  labelledBy,
  onVersion,
  onDirtyChange,
  onRemoving,
  onClose,
}: {
  rule: RoutingRule | null;
  version: string | null;
  downloads: Downloads;
  say: Say;
  labelledBy?: string;
  onVersion?: (version: string) => void;
  onDirtyChange: DirtyReporter;
  onRemoving?: RemovalMarker;
  onClose: (created: string | null, removed?: boolean) => void;
}) {
  const scope = useScope();
  const formRef = useRef<HTMLFormElement>(null);
  const [removalVersion] = useState(version);
  const command = useDownloadsCommand();
  const initial = initialRuleDraft(rule, downloads);
  const form = useRecordForm(rule ? `rule-${rule.id}` : "rule-new", () => RULE_KEYS, initial, onDirtyChange);
  const headingId = labelledBy ?? `${scope}-heading`;
  const kind = String(form.drafts.download_type);
  const chosen = downloads.clients.find((client) => client.id === form.drafts.download_client_id);
  const choices = [
    ...clientsOfKind(downloads, kind).map((client) => ({ value: client.id, label: client.enabled ? client.name : `${client.name} (turned off)` })),
    ...(chosen && chosen.kind !== kind ? [{ value: chosen.id, label: `${chosen.name} (takes ${chosen.kind} downloads)` }] : []),
  ];
  const kindName = downloads.download_types.find((entry) => entry.value === kind)?.label.toLowerCase() ?? kind;

  useEffect(() => {
    formRef.current?.querySelector<HTMLElement>("input, select")?.focus();
  }, []);

  const focusField = (key: string) => focusSoon(() => formRef.current?.querySelector<HTMLElement>(`#${CSS.escape(`${scope}-${key}`)}`) ?? formRef.current?.querySelector<HTMLElement>(`[name="${CSS.escape(`${scope}-${key}`)}"]`));

  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (command.isPending) return;
    form.clear();
    if (rule && !form.dirty) {
      form.say("success", "There are no changes to save.");
      return;
    }
    const values = submission(rule ? form.changed : RULE_KEYS, form.drafts);
    const request: DownloadsCommand = rule && version ? { kind: "update_rule", id: rule.id, version, values } : { kind: "create_rule", values };
    command.mutate(request, {
      onSuccess: (answer) => {
        if (answer.kind === "rejected") return form.reject(answer, RULE_KEYS, focusField);
        if (answer.kind === "changed") {
          const fresh = rule ? answer.downloads.rules.find((entry) => entry.id === rule.id) : undefined;
          if (fresh) onVersion?.(fresh.version);
          form.setGeneral(fresh ? CHANGED_ELSEWHERE : "This rule was removed somewhere else. Nothing was saved.");
          return;
        }
        say(answer.action.outcome.tone, answer.action.outcome.message);
        form.setEdits({});
        onClose(answer.action.created ?? null);
      },
      onError: (error) => form.setGeneral(commandFailureText(error)),
    });
  };

  const remove = () => {
    if (!rule || !removalVersion || command.isPending) return;
    const dirtyId = `rule-${rule.id}`;
    onRemoving?.(dirtyId, true);
    command.mutate(
      { kind: "remove_rule", id: rule.id, version: removalVersion },
      {
        onSuccess: (answer) => {
          if (answer.kind === "changed") {
            onRemoving?.(dirtyId, false);
            form.setGeneral(REMOVED_ELSEWHERE);
            return;
          }
          if (answer.kind !== "done") return;
          say(answer.action.outcome.tone, answer.action.outcome.message);
          onClose(null, true);
        },
        onError: (error) => {
          onRemoving?.(dirtyId, false);
          form.setGeneral(commandFailureText(error));
        },
      },
    );
  };

  const choice = (key: "provider" | "download_type", label: string, options: { value: string; label: string }[]) => (
    <SettingControl
      scope={scope}
      field={{ key, label, input: "choice", description: "", value: "", options }}
      value={form.drafts[key] ?? ""}
      onChange={(value) => (key === "download_type" ? form.replace(ruleTypeChange(form.drafts, downloads, String(value))) : form.edit(key, value))}
      error={form.errors[key]}
    />
  );
  const saving = command.isPending && (command.variables?.kind === "create_rule" || command.variables?.kind === "update_rule");

  return (
    <form ref={formRef} className="settings-form record-form" method="post" noValidate aria-labelledby={headingId} onSubmit={submit}>
      {rule ? null : <h4 id={headingId}>New routing rule</h4>}
      <fieldset className="record-fields" disabled={command.isPending}>
      {choice("provider", "Indexer source", downloads.providers)}
      <SettingControl
        scope={scope}
        field={{ key: "indexer_name", label: "Indexer", input: "code", description: "Use the indexer name as it appears on search results.", value: "", placeholder: "MyAnonaMouse" }}
        value={form.drafts.indexer_name ?? ""}
        onChange={(value) => form.edit("indexer_name", value)}
        error={form.errors.indexer_name}
      />
      {choice("download_type", "Download type", downloads.download_types)}
      <SelectField
        id={`${scope}-download_client_id`}
        label="Send to"
        value={String(form.drafts.download_client_id ?? "")}
        options={choices}
        placeholder="Choose a client"
        hint={choices.length === 0 ? `There is no ${kindName} client yet. Add one above first.` : `Only ${kindName} clients can take these downloads.`}
        error={form.errors.download_client_id}
        onChange={(value) => form.edit("download_client_id", value)}
      />
      <SettingControl
        scope={scope}
        field={{ key: "enabled", label: "Use this rule", input: "toggle", description: "", value: "" }}
        value={form.drafts.enabled ?? true}
        onChange={(value) => form.edit("enabled", value)}
        error={form.errors.enabled}
      />
      </fieldset>
      <FormProblem text={form.general} />
      <CardActions unsaved={form.dirty}>
        <button type="submit" className="button button--primary" aria-busy={saving}>
          {saving ? "Saving…" : rule ? "Save" : "Add rule"}
        </button>
        <button type="button" className="button button--subtle" disabled={command.isPending} onClick={() => onClose(null)}>
          {form.dirty ? "Discard changes" : "Cancel"}
        </button>
      </CardActions>
      <div className="settings-card-status" role="status">
        {form.said ? (
          <p key={form.said.serial} className={form.said.tone === "error" ? "form-error" : "form-success"}>
            {form.said.text}
          </p>
        ) : null}
      </div>
      {rule ? (
        <div className="record-remove">
          <RemoveZone label="Remove rule" confirmLabel="Remove" question={`Remove the rule for ${rule.indexer_name}?`} busy={command.isPending} onRemove={remove} />
        </div>
      ) : null}
    </form>
  );
}
