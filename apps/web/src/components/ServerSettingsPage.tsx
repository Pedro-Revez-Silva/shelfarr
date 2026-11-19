import { Link } from "@tanstack/react-router";
import { useId, useRef, useState, useSyncExternalStore, type FormEvent } from "react";
import { ApiError, failureKind } from "../api/errors";
import type { MetadataChange, MetadataReach, MetadataSettings } from "../contract";
import { useMetadataSettings, useSaveMetadataSettings, useSession } from "../queries";
import { useServices } from "../services";
import { usePageTitle } from "../title";
import type { FormOutcome } from "./accountFields";
import { PageHeading } from "./PageHeading";
import { EmptyState, ErrorPanel, Loading } from "./States";

type Field = "enabled" | "search_limit";
type Problems = Partial<Record<Field, string>>;

export function ServerSettingsPage() {
  const { mode } = useServices();
  if (mode !== "go") {
    return (
      <EmptyState title="That page is not part of this preview">
        <p>Use the navigation to return to your library.</p>
      </EmptyState>
    );
  }
  return <ServerSettings />;
}

function ServerSettings() {
  usePageTitle("Server settings");
  const { guard, queryClient, keys } = useServices();
  const [cachedAtEntry] = useState(() => queryClient.getQueryState(keys.metadataSettings)?.dataUpdatedAt ?? 0);
  const session = useSession();
  const settings = useMetadataSettings();
  const trust = useSyncExternalStore(guard.subscribeTrust, guard.getTrust, guard.getTrust);
  const admin = session.data?.admin !== undefined;
  const current = trust === "trusted" && settings.dataUpdatedAt > cachedAtEntry ? settings.data : undefined;
  const editor = useMetadataEditor();

  return (
    <section className="settings" aria-labelledby="settings-heading">
      <header className="page-heading">
        <p className="eyebrow">Admin</p>
        <PageHeading id="settings-heading">Server settings</PageHeading>
        <p className="lede">
          These apply to everyone on this server and to the classic Shelfarr app. Your own name and password are in <Link to="/account">Account</Link>.
        </p>
        {admin ? (
          <p className="settings-back">
            <Link to="/admin" activeOptions={{ exact: true }}>
              Server overview
            </Link>
          </p>
        ) : null}
      </header>
      {session.isError && !session.data ? (
        <ErrorPanel error={session.error} onRetry={() => void session.refetch()} />
      ) : !session.data ? (
        <Loading label="Loading the server settings…" />
      ) : !admin || (settings.isError && failureKind(settings.error) === "not_found") ? (
        <EmptyState title="Only administrators can see this page">
          <p>Use the navigation to return to your library.</p>
        </EmptyState>
      ) : settings.isError ? (
        <ErrorPanel error={settings.error} onRetry={() => void settings.refetch()} />
      ) : current ? (
        <MetadataForm settings={current} editor={editor} />
      ) : (
        <Loading label="Loading the server settings…" />
      )}
    </section>
  );
}

function useOutcome() {
  const [outcome, setOutcome] = useState<FormOutcome>(null);
  const serial = useRef(0);
  const say = (tone: "success" | "error", text: string) => {
    serial.current += 1;
    setOutcome({ tone, text, serial: serial.current });
  };
  return { outcome, say, clear: () => setOutcome(null) };
}

type Draft = { enabled: boolean | null; limit: string | null; base: string | null };

const NO_DRAFT: Draft = { enabled: null, limit: null, base: null };

function useMetadataEditor() {
  const [draft, setDraft] = useState<Draft>(NO_DRAFT);
  const [problems, setProblems] = useState<Problems>({});
  const edits = useRef(0);
  const saving = useRef(false);
  const mutation = useSaveMetadataSettings();
  return { draft, setDraft, problems, setProblems, edits, saving, mutation, ...useOutcome() };
}

type MetadataEditor = ReturnType<typeof useMetadataEditor>;

function limitProblem(text: string, min: number, max: number): string | null {
  const trimmed = text.trim();
  const value = /^[0-9]+$/.test(trimmed) ? Number(trimmed) : Number.NaN;
  return Number.isInteger(value) && value >= min && value <= max ? null : `Enter a whole number from ${min} to ${max}.`;
}

function failureText(error: unknown): string {
  const uncertain = "Shelfarr could not confirm whether the settings were saved. Reload the page to see what the server has, and save again if needed.";
  if (!(error instanceof ApiError)) return uncertain;
  switch (error.kind) {
    case "network":
    case "server":
      return uncertain;
    case "csrf":
      return "This page was out of date and has been refreshed. Nothing was changed; save again.";
    case "busy":
      return "The server is busy. Nothing was changed; try again in a moment.";
    case "not_found":
      return "Only administrators can change server settings. Nothing was changed.";
    default:
      return "The server did not accept this change. Nothing was changed; reload the page and try again.";
  }
}

function MetadataForm({ settings, editor }: { settings: MetadataSettings; editor: MetadataEditor }) {
  const ids = { heading: useId(), enabled: useId(), enabledHint: useId(), limit: useId(), limitHint: useId(), limitError: useId(), reach: useId() };
  const form = useRef<HTMLFormElement>(null);
  const { queryClient, keys } = useServices();
  const { draft, setDraft, problems, setProblems, edits, saving, mutation, outcome, say, clear } = editor;
  const saved = settings.open_library;
  const range = settings.search_limit_range;
  const enabled = draft.enabled ?? saved.enabled ?? false;
  const limitText = draft.limit ?? (saved.search_limit === null ? "" : String(saved.search_limit));

  function edit(change: Partial<Draft>) {
    edits.current += 1;
    clear();
    setDraft((current) => ({ ...current, ...change, base: current.base ?? settings.revision }));
  }

  function reset() {
    setDraft(NO_DRAFT);
    setProblems({});
  }

  function refuse(found: Problems, text: string) {
    setProblems(found);
    say("error", text);
    const field = found.search_limit ? "search_limit" : found.enabled ? "enabled" : null;
    const control = field ? form.current?.elements.namedItem(field) : null;
    if (control instanceof HTMLInputElement) control.focus();
  }

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (saving.current) return;
    clear();
    const change: MetadataChange = {};
    if (draft.enabled !== null && draft.enabled !== saved.enabled) change.enabled = draft.enabled;
    if (draft.limit !== null && draft.limit.trim() !== (saved.search_limit === null ? "" : String(saved.search_limit))) {
      const problem = limitProblem(draft.limit, range.min, range.max);
      if (problem) {
        refuse({ search_limit: problem }, "Nothing was saved. Check the marked field.");
        return;
      }
      change.search_limit = Number(draft.limit.trim());
    }
    setProblems({});
    if (change.enabled === undefined && change.search_limit === undefined) {
      reset();
      say("success", "There are no changes to save.");
      return;
    }
    saving.current = true;
    const revision = edits.current;
    mutation.mutate(
      { revision: draft.base ?? settings.revision, change },
      {
        onSettled: () => {
          saving.current = false;
        },
        onSuccess: (answer) => {
          const current = edits.current === revision;
          if (answer.kind === "saved") {
            if (current) reset();
            say("success", current ? "Metadata settings saved." : "The earlier change was saved. Your newer change is not saved yet.");
            return;
          }
          if (answer.kind === "conflict") {
            reset();
            say("error", "These settings were changed somewhere else while you were editing. Nothing was saved. The page now shows the saved values; make your change again.");
            return;
          }
          refuse(
            { ...(answer.errors.enabled ? { enabled: "Choose on or off." } : {}), ...(answer.errors.search_limit ? { search_limit: `Enter a whole number from ${range.min} to ${range.max}.` } : {}) },
            "Nothing was saved. Check the marked field.",
          );
        },
        onError: (error) => {
          void queryClient.invalidateQueries({ queryKey: keys.metadataSettings });
          say("error", failureText(error));
        },
      },
    );
  }

  const limitInvalid = Boolean(problems.search_limit);
  return (
    <section className="account-card settings-section" aria-labelledby={ids.heading}>
      <h2 id={ids.heading}>Metadata</h2>
      <p className="field-hint">Where Shelfarr looks up books when someone searches.</p>
      <form ref={form} className="account-form" method="post" noValidate aria-labelledby={ids.heading} onSubmit={submit}>
        <div className="check-field">
          <input
            id={ids.enabled}
            name="enabled"
            type="checkbox"
            checked={enabled}
            aria-describedby={ids.enabledHint}
            onChange={(event) => edit({ enabled: event.target.checked })}
          />
          <label htmlFor={ids.enabled}>Use Open Library</label>
          <p id={ids.enabledHint} className="field-hint">
            {saved.enabled === null ? (
              <span className="field-error">
                <span aria-hidden="true">⚠ </span>The saved choice cannot be read. Tick or clear this box and save to replace it.{" "}
              </span>
            ) : null}
            Searches openlibrary.org for book details. Default: {settings.defaults.enabled ? "on" : "off"}.
          </p>
        </div>
        <div className="field">
          <label htmlFor={ids.limit}>Results per search</label>
          <input
            id={ids.limit}
            name="search_limit"
            className="count-input"
            type="text"
            inputMode="numeric"
            autoComplete="off"
            spellCheck={false}
            enterKeyHint="done"
            value={limitText}
            aria-invalid={limitInvalid}
            aria-describedby={[ids.limitHint, limitInvalid ? ids.limitError : ""].filter(Boolean).join(" ")}
            onChange={(event) => {
              edit({ limit: event.target.value });
              if (limitInvalid) setProblems(({ search_limit: _cleared, ...rest }) => rest);
            }}
          />
          <p id={ids.limitHint} className="field-hint">
            {saved.search_limit === null ? (
              <span className="field-error">
                <span aria-hidden="true">⚠ </span>The saved number cannot be read. Enter a number and save to replace it.{" "}
              </span>
            ) : null}
            {range.min} to {range.max}. Default: {settings.defaults.search_limit}. Discover in this preview shows at most {settings.discover.max_results}.
          </p>
          {limitInvalid ? (
            <p id={ids.limitError} className="field-error">
              <span aria-hidden="true">⚠ </span>
              {problems.search_limit}
            </p>
          ) : null}
        </div>
        <Reach id={ids.reach} settings={settings} />
        <div className="form-actions">
          <button type="submit" className="button button--primary" disabled={mutation.isPending} aria-busy={mutation.isPending}>
            {mutation.isPending ? "Saving…" : "Save metadata settings"}
          </button>
        </div>
        <div className="form-outcome" role="status">
          {outcome ? (
            <p key={outcome.serial} className={outcome.tone === "error" ? "form-error" : "form-success"}>
              {outcome.text}
            </p>
          ) : null}
        </div>
      </form>
    </section>
  );
}

const REACH: Record<Exclude<MetadataReach, "available" | "provider_paused">, string> = {
  server_off: "Discover search is switched off for this server when it starts, so Discover sends nothing to Open Library whatever is saved here.",
  provider_disabled: "Discover does not search, because Open Library is off.",
  provider_not_selected: "Discover does not search, because the classic settings choose a different metadata source.",
  settings_unreadable: "Discover cannot search until the saved values above can be read.",
};

function minutes(seconds: number): string {
  if (seconds < 90) return `${Math.max(1, seconds)} ${seconds === 1 ? "second" : "seconds"}`;
  return `${Math.ceil(seconds / 60)} minutes`;
}

function reachText(discover: MetadataSettings["discover"]): string {
  switch (discover.search) {
    case "available":
      return discover.result_limit === 0 ? "Discover finds nothing, because the saved number is 0 or less." : `Discover searches Open Library and shows up to ${discover.result_limit ?? discover.max_results} results.`;
    case "provider_paused":
      return `Open Library is paused after errors or too many requests${discover.retry_after !== undefined && discover.retry_after > 0 ? `, for about ${minutes(discover.retry_after)}` : ""}. Saving here does not end the pause.`;
    default:
      return REACH[discover.search];
  }
}

function Reach({ id, settings }: { id: string; settings: MetadataSettings }) {
  return (
    <p id={id} className="settings-reach">
      <strong>Discover now: </strong>
      {reachText(settings.discover)}
    </p>
  );
}
