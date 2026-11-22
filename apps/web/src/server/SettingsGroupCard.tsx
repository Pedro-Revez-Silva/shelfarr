import { useQueryClient } from "@tanstack/react-query";
import { useEffect, useRef, useState, type FormEvent } from "react";
import { isApiError, unconfirmed } from "../api/errors";
import type { SubmittedValues } from "./api";
import type { SettingField, SettingGroup } from "./contract";
import { changedKeys, groupFields, initialDraft, isVisible, probeValues, submission, type DraftValue, type Drafts } from "./draft";
import { CardNotes, LibraryInventoryPanel, RolesReadout, TelegramChatsPanel } from "./extras";
import { AdvancedSection, CardActions, HealthStatus, SettingControl, SettingsCard, TestResult, controlId, useScope, type TestOutcome } from "./primitives";
import { useLibraryInventory, useProbe, useSaveGroup, useServerKeys } from "./queries";
import type { ServerSettings } from "./contract";

type Outcome = { tone: "success" | "error"; text: string; serial: number };

export function saveFailureText(error: unknown): string {
  if (unconfirmed(error)) return "Shelfarr could not confirm whether these settings were saved. Reload the page to see what the server has, and save again if needed.";
  if (!isApiError(error)) return "Shelfarr could not confirm whether these settings were saved. Reload the page to check.";
  switch (error.kind) {
    case "csrf":
      return "This page was out of date. Nothing was changed; save again.";
    case "not_found":
      return "Only administrators can change server settings. Nothing was changed.";
    case "invalid":
      return `The server did not accept this change: ${error.message} Nothing was changed.`;
    default:
      return "The server did not accept this change. Nothing was changed; reload the page and try again.";
  }
}

function probeFailureText(error: unknown): string {
  if (isApiError(error) && error.kind === "csrf") return "This page was out of date. Try the test again.";
  return "The test could not be run. Check your connection and try again.";
}

const LIBRARY_INPUTS = new Set(["library", "libraries"]);

export function SettingsGroupCard({ group, settings, onDirtyChange }: { group: SettingGroup; settings: ServerSettings; onDirtyChange: (id: string, dirty: boolean) => void }) {
  const scope = useScope();
  const [edits, setEdits] = useState<Drafts>({});
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [cardError, setCardError] = useState<string | null>(null);
  const [outcome, setOutcome] = useState<Outcome | null>(null);
  const [test, setTest] = useState<TestOutcome | null>(null);
  const [advancedOpen, setAdvancedOpen] = useState(false);
  const serial = useRef(0);
  const form = useRef<HTMLFormElement>(null);
  const save = useSaveGroup(group.id);
  const probe = useProbe();
  const keys = useServerKeys();
  const client = useQueryClient();
  const fields = groupFields(group);
  const drafts = Object.fromEntries(fields.map((field) => [field.key, edits[field.key] ?? initialDraft(field)])) as Drafts;
  const changed = changedKeys(group, drafts);
  const dirty = changed.length > 0;
  const wantsLibraries = fields.some((field) => LIBRARY_INPUTS.has(field.input)) || group.extras.includes("library_inventory");
  const inventory = useLibraryInventory(wantsLibraries);
  const libraries = inventory.data?.libraries ?? null;

  useEffect(() => onDirtyChange(group.id, dirty), [group.id, dirty, onDirtyChange]);
  useEffect(() => () => onDirtyChange(group.id, false), [group.id, onDirtyChange]);

  const say = (tone: Outcome["tone"], text: string) => {
    serial.current += 1;
    setOutcome({ tone, text, serial: serial.current });
  };

  const edit = (key: string, value: DraftValue) => {
    setEdits((current) => ({ ...current, [key]: value }));
    setOutcome(null);
    if (errors[key]) setErrors(({ [key]: _cleared, ...rest }) => rest);
  };

  const discard = () => {
    setEdits({});
    setErrors({});
    setCardError(null);
    say("success", "Your changes were discarded.");
  };

  const focusField = (key: string) => {
    const field = fields.find((entry) => entry.key === key);
    if (!field) return;
    if (group.advanced.some((entry) => entry.key === key)) setAdvancedOpen(true);
    requestAnimationFrame(() => {
      const id = controlId(field, scope);
      const root = form.current;
      const control = root?.querySelector<HTMLElement>(`#${CSS.escape(id)}`) ?? root?.querySelector<HTMLElement>(`input[id^="${CSS.escape(id)}-"], button[aria-describedby^="${CSS.escape(id)}-"]`);
      control?.focus();
    });
  };

  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (save.isPending) return;
    setCardError(null);
    if (!dirty) {
      say("success", "There are no changes to save.");
      return;
    }
    const sent = Object.fromEntries(changed.map((key) => [key, drafts[key]])) as Drafts;
    const values = submission(group, drafts, changed);
    save.mutate(values, {
      onSuccess: (answer) => {
        if (answer.kind === "rejected") {
          const byKey: Record<string, string> = {};
          const general: string[] = [];
          for (const entry of answer.errors) {
            if (entry.key && fields.some((field) => field.key === entry.key)) byKey[entry.key] = entry.message;
            else general.push(entry.message);
          }
          setErrors(byKey);
          setCardError(general.length > 0 ? general.join(" ") : null);
          say("error", "Nothing was saved. Check the marked fields.");
          const first = fields.find((field) => byKey[field.key]);
          if (first) focusField(first.key);
          return;
        }
        setErrors({});
        setEdits((current) => Object.fromEntries(Object.entries(current).filter(([key, value]) => !(key in sent) || !sameDraft(value, sent[key]))));
        say(answer.saved.outcome.tone, answer.saved.outcome.message);
      },
      onError: (error) => say("error", saveFailureText(error)),
    });
  };

  const runTest = (probeId: string, uses: "draft" | "saved", changes: boolean) => {
    const values: SubmittedValues = uses === "draft" ? probeValues(group, drafts) : {};
    const note = uses === "saved" && dirty ? "This tested the saved settings, not your unsaved changes." : undefined;
    probe.mutate(
      { probe: probeId, values },
      {
        onSuccess: (answer) => {
          setTest({ tone: answer.tone, message: answer.message, at: new Date(), note });
          if (changes || group.health) void client.invalidateQueries({ queryKey: keys.settings });
        },
        onError: (error) => setTest({ tone: "error", message: probeFailureText(error), at: new Date() }),
      },
    );
  };

  const visible = (field: SettingField) => Boolean(errors[field.key]) || isVisible(field, group, drafts);
  const basic = group.fields.filter(visible);
  const advanced = group.advanced.filter(visible);
  const advancedChanged = advanced.filter((field) => changed.includes(field.key)).length;
  const advancedHasError = advanced.some((field) => errors[field.key]);
  const headingId = `${scope}-heading`;
  const health = group.health;

  return (
    <SettingsCard
      id={group.id}
      headingId={headingId}
      title={group.title}
      summary={group.summary}
      status={health ? <HealthStatus status={health.status} checkedAt={health.checked_at} message={health.message} /> : undefined}
    >
      <form ref={form} className="settings-form" method="post" noValidate aria-labelledby={headingId} onSubmit={submit}>
        {basic.map((field) => (
          <SettingControl key={field.key} scope={scope} field={field} value={drafts[field.key] ?? ""} onChange={(value) => edit(field.key, value)} error={errors[field.key]} libraries={libraries} />
        ))}
        {group.toggle && basic.length === 1 && group.fields.length + group.advanced.length > 1 ? <p className="field-hint settings-off-note">Turn this on to see its settings.</p> : null}
        <AdvancedSection count={advanced.length} changed={advancedChanged} open={advancedOpen || advancedHasError} onToggle={setAdvancedOpen}>
          {advanced.map((field) => (
            <SettingControl key={field.key} scope={scope} field={field} value={drafts[field.key] ?? ""} onChange={(value) => edit(field.key, value)} error={errors[field.key]} libraries={libraries} />
          ))}
        </AdvancedSection>
        <CardNotes group={group} notes={settings.notes} />
        {cardError ? (
          <p className="field-error" role="alert">
            <span aria-hidden="true">⚠ </span>
            {cardError}
          </p>
        ) : null}
        <CardActions unsaved={dirty}>
          <button type="submit" className="button button--primary" disabled={save.isPending} aria-busy={save.isPending}>
            {save.isPending ? "Saving…" : "Save"}
          </button>
          {dirty ? (
            <button type="button" className="button button--subtle" onClick={discard} disabled={save.isPending}>
              Discard changes
            </button>
          ) : null}
          {group.probes.map((entry) => (
            <button key={entry.id} type="button" className="button" disabled={probe.isPending} aria-busy={probe.isPending && probe.variables?.probe === entry.id} onClick={() => runTest(entry.id, entry.uses, entry.changes)}>
              {probe.isPending && probe.variables?.probe === entry.id ? "Testing…" : entry.label}
            </button>
          ))}
        </CardActions>
        <div className="settings-card-status" role="status">
          {outcome ? (
            <p key={outcome.serial} className={outcome.tone === "error" ? "form-error" : "form-success"}>
              {outcome.text}
            </p>
          ) : null}
          <TestResult result={test} />
        </div>
      </form>
      {group.extras.includes("library_inventory") ? <LibraryInventoryPanel inventory={inventory} /> : null}
      {group.extras.includes("telegram_chats") ? <TelegramChatsPanel /> : null}
      {group.extras.includes("roles") ? <RolesReadout roles={settings.roles} /> : null}
    </SettingsCard>
  );
}

function sameDraft(left: DraftValue | undefined, right: DraftValue | undefined): boolean {
  if (Array.isArray(left) && Array.isArray(right)) return left.length === right.length && left.every((entry, index) => entry === right[index]);
  return left === right;
}
