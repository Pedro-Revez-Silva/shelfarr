import { Link, useBlocker, useNavigate, useSearch } from "@tanstack/react-router";
import { useEffect, useRef, useState, type FormEvent, type ReactNode } from "react";
import { failureKind, isApiError, unconfirmed } from "../../api/errors";
import { ErrorPanel, Loading } from "../../components/States";
import { useSession } from "../../queries";
import { useServices } from "../../services";
import { useDocumentTitle } from "../../title";
import type { SettingField } from "../contract";
import { initialDraft, same, type DraftValue, type Drafts } from "../draft";
import { CardActions, SettingControl, SettingsCard, useScope } from "../primitives";
import { useIsAdministrator } from "../queries";
import { AdministratorsOnly, LeaveDialog, NotInThisRuntime } from "../ServerCategoryPage";
import { ServerShell } from "../ServerShell";
import type { SetupSaveAnswer, SetupValues } from "./api";
import type { SetupCard, SetupState, SetupStepId } from "./contract";
import { useSaveSetupStep, useSetupMoves, useSetupState, useSkipSetup } from "./queries";

type Said = { state: SetupState; notice: string; alert: string | null };
type DirtyCards = { has: () => boolean; set: (id: string, dirty: boolean) => void; clear: () => void };

export function setupFailureText(error: unknown): string {
  if (unconfirmed(error)) return "Shelfarr could not confirm whether this step was saved. Reload the page to see what the server has, and try again if needed.";
  if (!isApiError(error)) return "Shelfarr could not confirm whether this step was saved. Reload the page to check.";
  switch (error.kind) {
    case "csrf":
      return "This page was out of date. Nothing was changed; try again.";
    case "not_found":
      return "Only administrators can run setup. Nothing was changed.";
    default:
      return "The server did not accept this. Nothing was changed; reload the page and try again.";
  }
}

export function ServerSetupPage() {
  const { mode } = useServices();
  if (mode !== "rails") return <NotInThisRuntime />;
  return <SetupView />;
}

function SetupView() {
  useDocumentTitle("Set up Shelfarr · Server");
  const { step } = useSearch({ from: "/server/setup" });
  const session = useSession();
  const admin = useIsAdministrator();
  const setup = useSetupState(step);
  const [said, setSaid] = useState<Said | null>(null);
  const shown = useRef(false);
  useEffect(() => {
    if (setup.data) shown.current = true;
  });

  const body =
    session.isError && !session.data ? (
      <ErrorPanel error={session.error} onRetry={() => void session.refetch()} />
    ) : !session.data ? (
      <Loading label="Loading setup…" />
    ) : !admin || (setup.isError && failureKind(setup.error) === "not_found") ? (
      <AdministratorsOnly />
    ) : setup.data ? (
      <SetupStep key={setup.data.step} state={setup.data} version={setup.dataUpdatedAt} moveFocus={shown.current} said={said?.state === setup.data ? said : null} onSaid={setSaid} />
    ) : setup.isError ? (
      <ErrorPanel error={setup.error} onRetry={() => void setup.refetch()} />
    ) : (
      <Loading label="Loading setup…" />
    );

  return (
    <ServerShell
      current="setup"
      settings={undefined}
      headingId="server-setup-heading"
      title="Set up Shelfarr"
      summary="Connect Prowlarr, qBittorrent and Audiobookshelf, then choose how requests start. Every step can be skipped, and everything here can be changed later in Server."
      rail={false}
    >
      {body}
    </ServerShell>
  );
}

function stepOf(search: object): unknown {
  return "step" in search ? search.step : undefined;
}

function useDirtyCards(): DirtyCards {
  const [cards] = useState(() => {
    const dirty = new Set<string>();
    return {
      has: () => dirty.size > 0,
      set: (id: string, isDirty: boolean) => void (isDirty ? dirty.add(id) : dirty.delete(id)),
      clear: () => dirty.clear(),
    };
  });
  return cards;
}

function SetupStep({ state, version, moveFocus, said, onSaid }: { state: SetupState; version: number; moveFocus: boolean; said: Said | null; onSaid: (said: Said | null) => void }) {
  const navigate = useNavigate();
  const moved = useSetupMoves();
  const skip = useSkipSetup();
  const dirty = useDirtyCards();
  const [skipError, setSkipError] = useState<string | null>(null);
  const heading = useRef<HTMLHeadingElement>(null);
  const position = state.steps.findIndex((entry) => entry.id === state.step) + 1;
  const blocker = useBlocker({
    shouldBlockFn: ({ current, next }) => dirty.has() && (current.pathname !== next.pathname || stepOf(current.search) !== stepOf(next.search)),
    enableBeforeUnload: () => dirty.has(),
    withResolver: true,
  });

  const arrived = useRef(moveFocus);
  useEffect(() => {
    const active = document.activeElement;
    if (arrived.current && (!active || active === document.body || active.closest(".server-content"))) heading.current?.focus();
    arrived.current = true;
  }, [version]);

  const go = (next: SetupState | null) => {
    dirty.clear();
    moved(next);
    if (next) void navigate({ to: "/server/setup", search: { step: next.step } });
    else void navigate({ to: "/library" });
  };

  const saved = (answer: Extract<SetupSaveAnswer, { kind: "saved" }>) => {
    const next = answer.saved.setup;
    onSaid(next ? { state: next, notice: answer.saved.outcome.message, alert: answer.saved.alert } : null);
    go(next);
  };

  const skipStep = (exit: boolean) => {
    if (skip.isPending) return;
    setSkipError(null);
    skip.mutate(
      { step: state.step, exit },
      {
        onSuccess: (answer) => {
          onSaid(null);
          go(answer.setup);
        },
        onError: (error) => setSkipError(setupFailureText(error)),
      },
    );
  };

  return (
    <div className="setup">
      <nav className="setup-steps" aria-label="Setup steps">
        <ol>
          {state.steps.map((entry, index) => (
            <li key={entry.id}>
              {entry.id === state.step ? (
                <span aria-current="step" className="setup-step-link">
                  <StepName index={index} label={entry.label} />
                </span>
              ) : (
                <Link to="/server/setup" search={{ step: entry.id }} className="setup-step-link">
                  <StepName index={index} label={entry.label} />
                </Link>
              )}
            </li>
          ))}
        </ol>
      </nav>
      <header className="setup-step-header">
        <p className="eyebrow">
          Step {position} of {state.steps.length}
        </p>
        <h2 ref={heading} tabIndex={-1} className="setup-step-title">
          {state.title}
        </h2>
        <p className="settings-card-summary">{state.summary}</p>
        <div role="status" className="setup-said">
          {said ? <p className="form-success">{said.notice}</p> : null}
          {said?.alert ? <p className="warning">{said.alert}</p> : null}
        </div>
      </header>
      <Warnings state={state} />
      {state.library_error ? (
        <p className="form-error" role="alert">
          <span aria-hidden="true">⚠ </span>The saved connection did not list libraries: {state.library_error}
        </p>
      ) : null}
      {state.cards.map((card) => (
        <SetupStepCard key={`${card.id}-${version}`} step={state.step} card={card} dirty={dirty} onSaved={saved} />
      ))}
      <div className="setup-moves">
        {state.previous ? (
          <Link to="/server/setup" search={{ step: state.previous }} className="button">
            Back
          </Link>
        ) : null}
        {state.last ? null : (
          <button type="button" className="button" disabled={skip.isPending} onClick={() => skipStep(false)}>
            Skip this step
          </button>
        )}
        <button type="button" className="button button--subtle" disabled={skip.isPending} onClick={() => skipStep(true)}>
          Skip setup
        </button>
      </div>
      <div role="status">{skipError ? <p className="form-error">{skipError}</p> : null}</div>
      <p className="field-hint setup-elsewhere">
        Jackett, Newznab, other download clients and other library platforms are in <Link to="/server/$category" params={{ category: "sources" }}>Catalogues and sources</Link>,{" "}
        <Link to="/server/$category" params={{ category: "downloads" }}>Downloads</Link> and <Link to="/server/$category" params={{ category: "library" }}>Library and files</Link>.
      </p>
      {blocker.status === "blocked" ? <LeaveDialog count={1} onStay={blocker.reset} onLeave={() => { dirty.clear(); blocker.proceed(); }} /> : null}
    </div>
  );
}

function StepName({ index, label }: { index: number; label: string }) {
  return (
    <>
      <span className="setup-step-number" aria-hidden="true">
        {index + 1}
      </span>
      {label}
    </>
  );
}

function Warnings({ state }: { state: SetupState }) {
  if (state.warnings.length === 0) return null;
  return (
    <div className="setup-warnings">
      {state.warnings.map((warning) => (
        <p key={warning} className="warning" role="status">
          <span aria-hidden="true">⚠ </span>
          {warning}
        </p>
      ))}
      {state.step === "folders" ? (
        <p className="field-hint">This does not block setup. Mount the same directory at the same path in every container, or change the paths below.</p>
      ) : (
        <p className="field-hint">
          This does not block Finish. Mount the same directory at the same path in every container, or{" "}
          <Link to="/server/setup" search={{ step: "folders" }}>
            review the folders
          </Link>
          .
        </p>
      )}
    </div>
  );
}

function draftChanged(field: SettingField, draft: DraftValue | undefined): boolean {
  if (draft === undefined) return false;
  if (field.input === "secret") return typeof draft === "string" && draft !== "";
  return !same(draft, initialDraft(field));
}

function submittedValue(draft: DraftValue): string | boolean {
  if (typeof draft === "boolean" || typeof draft === "string") return draft;
  return Array.isArray(draft) ? draft.join(",") : "";
}

function SetupStepCard({ step, card, dirty, onSaved }: { step: SetupStepId; card: SetupCard; dirty: DirtyCards; onSaved: (answer: Extract<SetupSaveAnswer, { kind: "saved" }>) => void }) {
  const scope = useScope();
  const [edits, setEdits] = useState<Drafts>({});
  const [error, setError] = useState<{ text: string; serial: number } | null>(null);
  const errorRef = useRef<HTMLParagraphElement>(null);
  const save = useSaveSetupStep(step);
  const drafts = Object.fromEntries(card.fields.map((field) => [field.key, edits[field.key] ?? initialDraft(field)])) as Drafts;
  const changed = card.fields.some((field) => draftChanged(field, edits[field.key]));
  const headingId = `${scope}-heading`;

  useEffect(() => dirty.set(card.id, changed), [card.id, changed, dirty]);
  useEffect(() => () => dirty.set(card.id, false), [card.id, dirty]);
  useEffect(() => {
    if (error) errorRef.current?.focus();
  }, [error]);

  const fail = (text: string) => setError((current) => ({ text, serial: (current?.serial ?? 0) + 1 }));

  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (save.isPending) return;
    setError(null);
    const values: SetupValues = Object.fromEntries(card.fields.map((field) => [field.key, submittedValue(drafts[field.key] ?? "")]));
    if (card.phase) values.phase = card.phase;
    save.mutate(values, {
      onSuccess: (answer) => (answer.kind === "saved" ? onSaved(answer) : fail(answer.message)),
      onError: (failure) => fail(setupFailureText(failure)),
    });
  };

  const form = (
    <form className="settings-form" method="post" noValidate aria-labelledby={headingId} onSubmit={submit}>
      {error ? (
        <p key={error.serial} ref={errorRef} className="form-error" role="alert" tabIndex={-1}>
          <span aria-hidden="true">⚠ </span>
          {error.text}
        </p>
      ) : null}
      {card.fields.map((field) => (
        <SettingControl
          key={field.key}
          scope={scope}
          field={field}
          value={drafts[field.key] ?? ""}
          onChange={(value) => {
            setEdits((current) => ({ ...current, [field.key]: value }));
          }}
          libraries={card.libraries}
        />
      ))}
      <CardActions unsaved={changed}>
        <button type="submit" className={card.collapsed ? "button" : "button button--primary"} disabled={save.isPending} aria-busy={save.isPending}>
          {save.isPending ? (card.submit.startsWith("Test") ? "Testing…" : "Saving…") : card.submit}
        </button>
      </CardActions>
    </form>
  );

  if (card.collapsed) return <CollapsedCard id={card.id} headingId={headingId} title={card.title} open={changed || error !== null}>{form}</CollapsedCard>;
  return (
    <SettingsCard id={card.id} headingId={headingId} title={card.title} summary={card.summary ?? undefined}>
      {form}
    </SettingsCard>
  );
}

function CollapsedCard({ id, headingId, title, open, children }: { id: string; headingId: string; title: string; open: boolean; children: ReactNode }) {
  return (
    <details id={id} className="settings-card setup-collapsed" open={open || undefined}>
      <summary>
        <h3 id={headingId}>{title}</h3>
      </summary>
      {children}
    </details>
  );
}
