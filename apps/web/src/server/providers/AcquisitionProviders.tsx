import { useLocation } from "@tanstack/react-router";
import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
import { failureKind } from "../../api/errors";
import { Said, useSay } from "../extras";
import { AdvancedSection, CardActions, RemoveZone, SettingControl, SettingsCard, TestResult, useScope, type TestOutcome } from "../primitives";
import {
  CHANGED_ELSEWHERE,
  CardBody,
  FormProblem,
  REMOVED_ELSEWHERE,
  commandFailureText,
  focusSoon,
  useEditVersion,
  useLostDraftNotice,
  useRecordForm,
  useRevalidateAccessWhenDenied,
  type DirtyReporter,
  type RemovalMarker,
  type Say,
} from "../downloads/DownloadManagement";
import { useProviders, useProvidersCommand, type ProvidersCommand } from "./api";
import type { AcquisitionProvider, Providers } from "./contract";
import { PROVIDER_KEYS, initialProviderDraft, mediaLabels, providerErrors, providerFields, providerSubmission } from "./forms";

const CARD_ID = "acquisition_providers";

export const PROVIDER_CARDS = [{ id: CARD_ID, title: "Custom providers" }] as const;
const NEW_HASH = `${CARD_ID}-new`;
const RECORD_HASH = /^acquisition-provider-([1-9]\d{0,18})(-edit)?$/;

type Arrival = { id: string; edit: boolean } | null;

function rowId(provider: AcquisitionProvider): string {
  return `acquisition-provider-${provider.id}`;
}

function focusStillUnclaimed(target: HTMLElement): boolean {
  const active = document.activeElement;
  return active === null || active === document.body || active === target || active === document.getElementById(CARD_ID);
}

function focusWithinCardOrUnclaimed(): boolean {
  const active = document.activeElement;
  return active === null || active === document.body || Boolean(document.getElementById(CARD_ID)?.contains(active));
}

function bringIntoView(id: string) {
  const target = document.getElementById(id);
  if (!target || !focusStillUnclaimed(target)) return;
  target.scrollIntoView({ block: "start" });
  target.focus({ preventScroll: true });
}

function useArrival(ready: boolean, onNew: () => void): Arrival {
  const hash = useLocation({ select: (location) => location.hash });
  const handled = useRef<string | null>(null);
  const [arrival, setArrival] = useState<Arrival>(null);
  useEffect(() => {
    if (!ready || !hash || handled.current === hash) return;
    handled.current = hash;
    if (hash === CARD_ID) {
      bringIntoView(CARD_ID);
      return;
    }
    if (hash === NEW_HASH) {
      onNew();
      return;
    }
    const match = RECORD_HASH.exec(hash);
    if (match?.[1]) setArrival({ id: match[1], edit: Boolean(match[2]) });
  }, [ready, hash, onNew]);
  return arrival;
}

export function AcquisitionProviders({ onDirtyChange }: { onDirtyChange: DirtyReporter }) {
  const query = useProviders();
  const scope = useScope();
  const headingId = `${scope}-heading`;
  const { said, say } = useSay();
  const [adding, setAdding] = useState(false);
  const addButton = useRef<HTMLButtonElement>(null);
  const denied = query.isError && failureKind(query.error) === "not_found";
  useRevalidateAccessWhenDenied(denied);
  const { track, markRemoving } = useLostDraftNotice(query.data?.providers, "provider", say, onDirtyChange);
  const openNew = useCallback(() => setAdding(true), []);
  const arrival = useArrival(query.data !== undefined, openNew);
  return (
    <SettingsCard
      id={CARD_ID}
      headingId={headingId}
      title="Custom providers"
      summary="Your own search services. For each request Shelfarr asks every enabled provider that takes its book type, in priority order, alongside the other sources. New providers go last."
    >
      <CardBody query={query} label="Loading the custom providers…" denied="Only administrators can manage custom providers.">
        {(data) => (
          <>
            {data.providers.length === 0 ? <p className="field-hint">No custom providers yet.</p> : (
              <ul className="record-list" aria-label="Custom providers in priority order">
                {data.providers.map((provider) => (
                  <ProviderRow
                    key={provider.id}
                    provider={provider}
                    providers={data}
                    arrival={arrival?.id === provider.id ? arrival : null}
                    say={say}
                    onDirtyChange={track}
                    onRemoving={markRemoving}
                    onRemoved={() => focusSoon(() => document.getElementById(CARD_ID))}
                  />
                ))}
              </ul>
            )}
            {adding ? (
              <ProviderForm
                provider={null}
                version={null}
                providers={data}
                say={say}
                onDirtyChange={onDirtyChange}
                onClose={(created) => {
                  setAdding(false);
                  focusSoon(() => (created ? document.getElementById(`acquisition-provider-${created}`) : addButton.current));
                }}
              />
            ) : (
              <p>
                <button ref={addButton} type="button" className="button" onClick={() => setAdding(true)}>
                  Add a provider
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

function ProviderRow({
  provider,
  providers,
  arrival,
  say,
  onDirtyChange,
  onRemoving,
  onRemoved,
}: {
  provider: AcquisitionProvider;
  providers: Providers;
  arrival: Arrival;
  say: Say;
  onDirtyChange: DirtyReporter;
  onRemoving: RemovalMarker;
  onRemoved: () => void;
}) {
  const [editing, setEditing] = useState(false);
  const { version, restart, adoptOnceShown } = useEditVersion(provider.version);
  const [test, setTest] = useState<TestOutcome | null>(null);
  const [formDirty, setFormDirty] = useState(false);
  const command = useProvidersCommand();
  const id = rowId(provider);
  const reportDirty = useCallback<DirtyReporter>(
    (key, dirty) => {
      setFormDirty(dirty);
      onDirtyChange(key, dirty);
    },
    [onDirtyChange],
  );

  useEffect(() => {
    if (!arrival) return;
    if (arrival.edit && !editing) {
      restart();
      setEditing(true);
    } else if (!arrival.edit) {
      bringIntoView(id);
    }
  }, [arrival]);

  const toggle = () => {
    if (!editing) {
      restart();
      setEditing(true);
    } else if (formDirty) {
      say("error", `Save or discard the changes to ${provider.name} before closing it.`);
    } else {
      setEditing(false);
    }
  };

  const runTest = () => {
    if (command.isPending) return;
    command.mutate(
      { kind: "test", id: provider.id },
      {
        onSuccess: (answer) => {
          if (answer.kind !== "done") return;
          setTest({ tone: answer.action.outcome.tone, message: answer.action.outcome.message, at: new Date(), note: editing && formDirty ? "This tested the saved settings, not your unsaved changes." : undefined });
        },
        onError: (error) => setTest({ tone: "error", message: commandFailureText(error), at: new Date() }),
      },
    );
  };

  const testing = command.isPending && command.variables?.kind === "test";
  const media = mediaLabels(provider);

  return (
    <li className="record" aria-labelledby={`${id}-name`}>
      <div className="record-summary">
        <h5 id={`${id}-name`} className="record-name">
          <span id={id} tabIndex={-1}>
            {provider.name}
          </span>
        </h5>
        <p className="record-facts">
          {media.map((label) => (
            <span key={label} className="badge">
              {label}
            </span>
          ))}
          {provider.enabled ? null : <span className="badge record-off">Turned off</span>}
          {provider.allow_private_network ? <span className="badge">Private network allowed</span> : null}
          <span>Priority {provider.priority + 1}</span>
          <span>Timeout {provider.timeout_seconds} s</span>
          {provider.api_key_saved ? <span>Bearer token saved</span> : null}
        </p>
        <p className="record-address">{provider.url}</p>
      </div>
      <div className="record-actions">
        <button id={`${id}-edit`} type="button" className="button" aria-expanded={editing} aria-controls={`${id}-form`} aria-describedby={`${id}-name`} onClick={toggle}>
          Edit
        </button>
        <button type="button" className="button" aria-busy={testing} aria-describedby={`${id}-name`} onClick={runTest}>
          {testing ? "Testing…" : "Test"}
        </button>
      </div>
      <div className="record-status" role="status">
        <TestResult result={test} />
      </div>
      {editing ? (
        <div id={`${id}-form`} className="record-editor">
          <ProviderForm
            provider={provider}
            version={version}
            providers={providers}
            say={say}
            labelledBy={`${id}-name`}
            onVersion={adoptOnceShown}
            onDirtyChange={reportDirty}
            onRemoving={onRemoving}
            onClose={(_, removed) => {
              setEditing(false);
              if (removed) onRemoved();
              else focusSoon(() => document.getElementById(`${id}-edit`));
            }}
          />
        </div>
      ) : null}
    </li>
  );
}

function ProviderForm({
  provider,
  version,
  providers,
  say,
  labelledBy,
  onVersion,
  onDirtyChange,
  onRemoving,
  onClose,
}: {
  provider: AcquisitionProvider | null;
  version: string | null;
  providers: Providers;
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
  const [removalVersion] = useState(version);
  const command = useProvidersCommand();
  const initial = initialProviderDraft(provider, providers.defaults);
  const form = useRecordForm(provider ? `provider-${provider.id}` : "provider-new", () => PROVIDER_KEYS, initial, onDirtyChange);
  const { basic, advanced } = providerFields(provider);
  const headingId = labelledBy ?? `${scope}-heading`;

  useEffect(() => {
    if (focusWithinCardOrUnclaimed()) formRef.current?.querySelector<HTMLElement>("input, select")?.focus();
  }, []);

  const focusField = (key: string) => {
    if (advanced.some((entry) => entry.key === key)) setAdvancedOpen(true);
    focusSoon(() => {
      const target = `${scope}-${key}`;
      return formRef.current?.querySelector<HTMLElement>(`#${CSS.escape(target)}`) ?? formRef.current?.querySelector<HTMLElement>(`input[id^="${CSS.escape(target)}-"]`);
    });
  };

  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (command.isPending) return;
    form.clear();
    if (provider && !form.dirty) {
      form.say("success", "There are no changes to save.");
      return;
    }
    const values = providerSubmission(provider, form.drafts, initial);
    const request: ProvidersCommand = provider && version ? { kind: "update", id: provider.id, version, values } : { kind: "create", values };
    command.mutate(request, {
      onSuccess: (answer) => {
        if (answer.kind === "rejected") return form.reject({ errors: providerErrors(answer.errors) }, PROVIDER_KEYS, focusField);
        if (answer.kind === "changed") {
          const fresh = provider ? answer.providers.providers.find((entry) => entry.id === provider.id) : undefined;
          if (fresh) onVersion?.(fresh.version);
          form.setGeneral(fresh ? CHANGED_ELSEWHERE : "This provider was removed somewhere else. Nothing was saved.");
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
    if (!provider || !removalVersion || command.isPending) return;
    const dirtyId = `provider-${provider.id}`;
    onRemoving?.(dirtyId, true);
    command.mutate(
      { kind: "remove", id: provider.id, version: removalVersion },
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
          if (failureKind(error) === "not_found") say("error", `${provider.name} was not removed here. ${commandFailureText(error)}`);
        },
      },
    );
  };

  const control = (field: (typeof basic)[number]) => (
    <SettingControl key={field.key} scope={scope} field={field} value={form.drafts[field.key] ?? ""} onChange={(value) => form.edit(field.key, value)} error={form.errors[field.key]} />
  );
  const advancedChanged = advanced.filter((entry) => form.changed.includes(entry.key)).length;
  const saving = command.isPending && (command.variables?.kind === "create" || command.variables?.kind === "update");

  return (
    <form ref={formRef} className="settings-form record-form" method="post" noValidate aria-labelledby={headingId} onSubmit={submit}>
      {provider ? null : <h4 id={headingId}>New custom provider</h4>}
      <fieldset className="record-fields" disabled={command.isPending}>
        {basic.map(control)}
        {provider?.url_hidden ? <p className="field-hint">The saved address has parts that are not shown. Leave the address unchanged to keep them.</p> : null}
        <AdvancedSection count={advanced.length} changed={advancedChanged} open={advancedOpen || advanced.some((entry) => form.errors[entry.key])} onToggle={setAdvancedOpen}>
          {advanced.map(control)}
        </AdvancedSection>
      </fieldset>
      <FormProblem text={form.general} />
      <CardActions unsaved={form.dirty}>
        <button type="submit" className="button button--primary" aria-busy={saving}>
          {saving ? "Saving…" : provider ? "Save" : "Add provider"}
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
      {provider ? (
        <div className="record-remove">
          <RemoveZone
            label="Remove provider"
            confirmLabel="Remove"
            question={`Remove ${provider.name}? Copies it already found can no longer be downloaded.`}
            busy={command.isPending}
            onRemove={remove}
          />
        </div>
      ) : null}
    </form>
  );
}
