import { useCallback, useEffect, useId, useRef, useState } from "react";
import { formatBytes } from "../components/DetailsPage";
import type { ReaderPublication } from "../contract";
import { useServices } from "../services";
import { announceChange, onChange, useOffline, type Offline } from "./context";
import { bookKey, type FailureKind, type SavedBook } from "./model";
import { keepStorage, saveCopy, SaveFailure, saveLockName } from "./save";
import { FAILURES, RETRYABLE, formatDay } from "./text";
import { ensureWorker } from "./worker";

type CopyState =
  | { kind: "checking" }
  | { kind: "none" }
  | { kind: "saving"; received: number; total: number; here: boolean }
  | { kind: "saved"; book: SavedBook }
  | { kind: "unfinished"; previous: SavedBook | null }
  | { kind: "failed"; failure: FailureKind; previous: SavedBook | null };

type Props = { id: string; title: string; currentAsset: string | null; load: (signal: AbortSignal) => Promise<ReaderPublication>; compact?: boolean };

const PROGRESS_INTERVAL_MS = 250;

async function lockHeld(account: string, id: string): Promise<boolean> {
  const held = await navigator.locks?.query?.().catch(() => null);
  return Boolean(held?.held?.some((lock) => lock.name === saveLockName(account, id)));
}

async function readState(offline: Offline, account: string, id: string): Promise<CopyState> {
  const [book, attempts, busy] = await Promise.all([offline.store.book(account, id), offline.store.attempts(account), lockHeld(account, id)]);
  const attempt = attempts.find((candidate) => candidate.key === bookKey(account, id));
  if (busy) return { kind: "saving", received: 0, total: 0, here: false };
  if (attempt?.failure) return { kind: "failed", failure: attempt.failure, previous: book };
  if (attempt) return { kind: "unfinished", previous: book };
  return book ? { kind: "saved", book } : { kind: "none" };
}

export function SaveForOffline(props: Props) {
  const offline = useOffline();
  if (!offline?.confirmation) return null;
  return <SaveControl {...props} offline={offline} />;
}

function SaveControl({ id, title, currentAsset, load, compact, offline }: Props & { offline: Offline }) {
  const { guard } = useServices();
  const account = guard.account;
  const heading = useId();
  const [state, setState] = useState<CopyState>({ kind: "checking" });
  const [confirmingRemoval, setConfirmingRemoval] = useState(false);
  const [removalFailed, setRemovalFailed] = useState(false);
  const running = useRef(false);
  const generation = useRef(0);
  const removeButton = useRef<HTMLButtonElement>(null);
  const section = useRef<HTMLElement>(null);
  const status = useRef<HTMLDivElement>(null);
  const keepFocus = () =>
    requestAnimationFrame(() => {
      if (!section.current?.contains(document.activeElement)) status.current?.focus();
    });

  const refresh = useCallback(async () => {
    if (running.current) return;
    const started = generation.current;
    const next = await readState(offline, account, id).catch((): CopyState => ({ kind: "failed", failure: "storage", previous: null }));
    if (!running.current && started === generation.current && guard.isActive()) setState(next);
  }, [offline, account, id, guard]);

  useEffect(() => {
    void refresh();
    const stop = onChange(() => void refresh());
    window.addEventListener("focus", refresh);
    return () => {
      stop();
      window.removeEventListener("focus", refresh);
    };
  }, [refresh]);

  const save = async () => {
    if (running.current) return;
    running.current = true;
    setRemovalFailed(false);
    generation.current += 1;
    setConfirmingRemoval(false);
    const previous = state.kind === "saved" ? state.book : state.kind === "failed" || state.kind === "unfinished" ? state.previous : null;
    setState({ kind: "saving", received: 0, total: 0, here: true });
    let shown = 0;
    const controller = new AbortController();
    try {
      const publication = await load(controller.signal);
      await saveCopy({
        publication,
        account,
        confirm: offline.confirm,
        offline: offline.boot,
        store: offline.store,
        guard,
        ensureWorker,
        estimate: async () => (await navigator.storage?.estimate?.()) ?? {},
        locks: navigator.locks,
        onProgress: (received, total) => {
          const now = Date.now();
          if (received !== total && now - shown < PROGRESS_INTERVAL_MS) return;
          shown = now;
          setState({ kind: "saving", received, total, here: true });
        },
      });
      await keepStorage();
      running.current = false;
      generation.current += 1;
      announceChange();
      await refresh();
    } catch (error) {
      running.current = false;
      generation.current += 1;
      const failure = error instanceof SaveFailure ? error.kind : "network";
      announceChange();
      if (failure === "busy") await refresh();
      else setState({ kind: "failed", failure, previous });
    }
    keepFocus();
  };

  const remove = async () => {
    setConfirmingRemoval(false);
    generation.current += 1;
    const removed = await offline.store.remove(account, id).then(
      () => true,
      () => false,
    );
    setRemovalFailed(!removed);
    announceChange();
    await refresh();
    keepFocus();
  };

  const outdated = state.kind === "saved" && currentAsset !== null && state.book.asset.id !== currentAsset;
  return (
    <section ref={section} className={`offline-copy${compact ? " offline-copy--compact" : ""}`} aria-labelledby={heading} data-state={state.kind}>
      <h2 id={heading} className={compact ? "sr-only" : "offline-copy-heading"}>
        Offline reading
      </h2>
      <div ref={status} role="status" className="offline-copy-status" tabIndex={-1}>
        <StatusText state={state} outdated={outdated} compact={compact ?? false} />
        {removalFailed ? <p className="form-error">This browser couldn't remove the saved copy. Try again.</p> : null}
      </div>
      {state.kind === "saving" && state.here ? (
        <div className="offline-copy-transfer">
          <progress className="offline-copy-progress" max={state.total || 1} value={state.total ? state.received : undefined} aria-label={`Saving ${title} for offline reading`} />
          <p className="offline-copy-bytes">{state.total ? `${formatBytes(state.received)} of ${formatBytes(state.total)}` : "Starting…"}</p>
        </div>
      ) : null}
      <div className="offline-copy-actions">
        {state.kind === "none" ? (
          <button type="button" className="button button--primary" onClick={() => void save()}>
            Save for offline reading
          </button>
        ) : null}
        {state.kind === "unfinished" || (state.kind === "failed" && RETRYABLE.has(state.failure)) ? (
          <button type="button" className="button button--primary" onClick={() => void save()}>
            Try again
          </button>
        ) : null}
        {outdated ? (
          <button type="button" className="button" onClick={() => void save()}>
            Update saved copy
          </button>
        ) : null}
        {state.kind === "saved" && !confirmingRemoval ? (
          <button ref={removeButton} type="button" className="button button--subtle" onClick={() => setConfirmingRemoval(true)}>
            Remove saved copy
          </button>
        ) : null}
        {state.kind === "saved" || state.kind === "failed" || state.kind === "unfinished" ? (
          <a className="button button--subtle" href={offline.boot.downloads}>
            Downloads
          </a>
        ) : null}
      </div>
      {state.kind === "saved" && confirmingRemoval ? (
        <div className="offline-copy-confirm" role="group" aria-label="Remove the saved copy">
          <p>Remove the saved copy from this browser? A place you reached while offline is removed with it.</p>
          <button type="button" className="button button--danger" onClick={() => void remove()} autoFocus>
            Remove
          </button>
          <button
            type="button"
            className="button"
            onClick={() => {
              setConfirmingRemoval(false);
              requestAnimationFrame(() => removeButton.current?.focus());
            }}
          >
            Keep it
          </button>
        </div>
      ) : null}
    </section>
  );
}

function StatusText({ state, outdated, compact }: { state: CopyState; outdated: boolean; compact: boolean }) {
  switch (state.kind) {
    case "checking":
      return <p>Checking this browser for a saved copy…</p>;
    case "none":
      return <p>{compact ? "Not saved on this device." : "Keep this EPUB in this browser to read it without a connection. Places you reach offline stay on this device."}</p>;
    case "saving":
      return <p>{state.here ? "Saving for offline reading…" : "Saving in another tab…"}</p>;
    case "saved":
      return (
        <p>
          {`Saved on this device on ${formatDay(state.book.savedAt)} · ${formatBytes(state.book.asset.size_bytes)}.`}
          {outdated ? " The server now has a different edition; your saved copy still opens offline until you update it." : compact ? "" : " It opens from Downloads even when the server can't be reached."}
        </p>
      );
    case "unfinished":
      return <p>{`The last save didn't finish, so nothing new was stored.${state.previous ? " Your earlier saved copy is unchanged." : ""}`}</p>;
    case "failed":
      return <p>{`${FAILURES[state.failure]}${state.previous ? " Your earlier saved copy is unchanged." : ""}`}</p>;
  }
}
