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
import type { SetupValues } from "./api";
import type { SetupCard, SetupState } from "./contract";
import { useSaveSetupStep, useSetupState, useSetupWriting, useSkipSetup } from "./queries";

type Said = { step: SetupState["step"]; revision: number; notice: string; alert: string | null };

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
  const [revision, setRevision] = useState(0);
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
      <SetupStep
        key={setup.data.step}
        state={setup.data}
        revision={revision}
        moveFocus={shown.current}
        rereading={setup.isFetching && setup.isStale}
        said={said?.step === setup.data.step && said.revision === revision ? said : null}
        onSaid={setSaid}
        onReplaced={() => setRevision((current) => current + 1)}
      />
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

function draftChanged(field: SettingField, draft: DraftValue | undefined): boolean {
  if (draft === undefined) return false;
  if (field.input === "secret") return typeof draft === "string" && draft !== "";
  return !same(draft, initialDraft(field));
}

function cardChanged(card: SetupCard | undefined, edits: Drafts): boolean {
  if (!card) return Object.keys(edits).length > 0;
  return card.fields.some((field) => draftChanged(field, edits[field.key]));
}

function submittedValue(draft: DraftValue): string | boolean {
  if (typeof draft === "boolean" || typeof draft === "string") return draft;
  return Array.isArray(draft) ? draft.join(",") : "";
}

type CardError = { text: string; serial: number };
type StepProps = { state: SetupState; revision: number; moveFocus: boolean; rereading: boolean; said: Said | null; onSaid: (said: Said | null) => void; onReplaced: () => void };

function SetupStep({ state, revision, moveFocus, rereading, said, onSaid, onReplaced }: StepProps) {
  const navigate = useNavigate();
  const save = useSaveSetupStep(state.step);
  const skip = useSkipSetup();
  const writing = useSetupWriting() || rereading;
  const [edits, setEdits] = useState<Record<string, Drafts>>({});
  const [errors, setErrors] = useState<Record<string, CardError>>({});
  const [skipError, setSkipError] = useState<string | null>(null);
  const [confirming, setConfirming] = useState<{ count: number; action: () => void } | null>(null);
  const heading = useRef<HTMLHeadingElement>(null);
  const stepList = useRef<HTMLOListElement>(null);
  const position = state.steps.findIndex((entry) => entry.id === state.step) + 1;
  const changedCards = Object.keys(edits).filter((id) => cardChanged(state.cards.find((card) => card.id === id), edits[id] ?? {}));
  const dirty = useRef(false);
  dirty.current = changedCards.length > 0;
  const blocker = useBlocker({
    shouldBlockFn: ({ current, next }) => dirty.current && (current.pathname !== next.pathname || stepOf(current.search) !== stepOf(next.search)),
    enableBeforeUnload: () => dirty.current,
    withResolver: true,
  });

  const arrived = useRef(moveFocus);
  useEffect(() => {
    const active = document.activeElement;
    if (arrived.current && (!active || active === document.body || active.closest(".server-content"))) heading.current?.focus();
    arrived.current = true;
  }, [revision]);

  useEffect(() => {
    const list = stepList.current;
    const current = list?.querySelector<HTMLElement>('[aria-current="step"]');
    if (list && current && list.scrollWidth > list.clientWidth) list.scrollLeft = current.offsetLeft - list.offsetLeft - 16;
  }, []);

  const go = (next: SetupState | null) => {
    dirty.current = false;
    setEdits({});
    setErrors({});
    onReplaced();
    if (next) void navigate({ to: "/server/setup", search: { step: next.step } });
    else void navigate({ to: "/library" });
  };

  const confirmFirst = (others: string[], action: () => void) => {
    if (others.length > 0) setConfirming({ count: others.length, action });
    else action();
  };

  const fail = (cardId: string, text: string) => setErrors((current) => ({ ...current, [cardId]: { text, serial: (current[cardId]?.serial ?? 0) + 1 } }));

  const submit = (card: SetupCard, drafts: Drafts) => {
    if (writing) return;
    confirmFirst(
      changedCards.filter((id) => id !== card.id),
      () => {
        setErrors(({ [card.id]: _cleared, ...rest }) => rest);
        const values: SetupValues = Object.fromEntries(card.fields.map((field) => [field.key, submittedValue(drafts[field.key] ?? "")]));
        if (card.phase) values.phase = card.phase;
        save.mutate(values, {
          onSuccess: (answer) => {
            if (answer.kind === "rejected") return fail(card.id, answer.message);
            const next = answer.saved.setup;
            onSaid(next ? { step: next.step, revision: revision + 1, notice: answer.saved.outcome.message, alert: answer.saved.alert } : null);
            go(next);
          },
          onError: (failure) => fail(card.id, setupFailureText(failure)),
        });
      },
    );
  };

  const skipStep = (exit: boolean) => {
    if (writing) return;
    confirmFirst(changedCards, () => {
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
    });
  };

  return (
    <div className="setup">
      <nav className="setup-steps" aria-label="Setup steps">
        <ol ref={stepList}>
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
        <SetupStepCard
          key={card.id}
          card={card}
          edits={edits[card.id] ?? {}}
          error={errors[card.id] ?? null}
          writing={writing}
          saving={save.isPending && save.variables?.phase === (card.phase ?? undefined)}
          onEdit={(key, value) => setEdits((current) => ({ ...current, [card.id]: { ...current[card.id], [key]: value } }))}
          onSubmit={(drafts) => submit(card, drafts)}
        />
      ))}
      <div className="setup-moves">
        {state.previous ? (
          <Link to="/server/setup" search={{ step: state.previous }} className="button">
            Back
          </Link>
        ) : null}
        {state.last ? null : (
          <button type="button" className="button" disabled={writing} onClick={() => skipStep(false)}>
            Skip this step
          </button>
        )}
        <button type="button" className="button button--subtle" disabled={writing} onClick={() => skipStep(true)}>
          Skip setup
        </button>
      </div>
      <div role="status">{skipError ? <p className="form-error">{skipError}</p> : null}</div>
      <p className="field-hint setup-elsewhere">
        Jackett, Newznab, other download clients and other library platforms are in <Link to="/server/$category" params={{ category: "sources" }}>Catalogues and sources</Link>,{" "}
        <Link to="/server/$category" params={{ category: "downloads" }}>Downloads</Link> and <Link to="/server/$category" params={{ category: "library" }}>Library and files</Link>.
      </p>
      {blocker.status === "blocked" ? (
        <LeaveDialog
          count={changedCards.length}
          onStay={blocker.reset}
          onLeave={() => {
            dirty.current = false;
            blocker.proceed();
          }}
        />
      ) : null}
      {confirming ? (
        <LeaveDialog
          count={confirming.count}
          onStay={() => setConfirming(null)}
          onLeave={() => {
            setConfirming(null);
            confirming.action();
          }}
        />
      ) : null}
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

type CardProps = {
  card: SetupCard;
  edits: Drafts;
  error: CardError | null;
  writing: boolean;
  saving: boolean;
  onEdit: (key: string, value: DraftValue) => void;
  onSubmit: (drafts: Drafts) => void;
};

function SetupStepCard({ card, edits, error, writing, saving, onEdit, onSubmit }: CardProps) {
  const scope = useScope();
  const errorRef = useRef<HTMLParagraphElement>(null);
  const drafts = Object.fromEntries(card.fields.map((field) => [field.key, edits[field.key] ?? initialDraft(field)])) as Drafts;
  const changed = cardChanged(card, edits);
  const headingId = `${scope}-heading`;

  useEffect(() => {
    if (error) errorRef.current?.focus();
  }, [error]);

  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    onSubmit(drafts);
  };

  const form = (
    <form className="settings-form" method="post" noValidate aria-labelledby={headingId} onSubmit={submit}>
      {error ? (
        <p key={error.serial} ref={errorRef} className="form-error" role="alert" tabIndex={-1}>
          <span aria-hidden="true">⚠ </span>
          {error.text}
        </p>
      ) : null}
      <fieldset className="setup-fields" disabled={writing}>
        {card.fields.map((field) => (
          <SettingControl key={field.key} scope={scope} field={field} value={drafts[field.key] ?? ""} onChange={(value) => onEdit(field.key, value)} libraries={card.libraries} />
        ))}
        <CardActions unsaved={changed}>
          <button type="submit" className={card.collapsed ? "button" : "button button--primary"} aria-busy={saving}>
            {saving ? (card.submit.startsWith("Test") ? "Testing…" : "Saving…") : card.submit}
          </button>
        </CardActions>
      </fieldset>
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
