import { useEffect, useId, useRef, useState, type FormEvent } from "react";
import type { Locator, PageEngine, ProgressPlace, ReaderAsset, StoredProgress } from "../contract";
import { Loading } from "../components/States";
import { useServices } from "../services";
import { guardedFetch, PageEngineError, PageSession, pageResources, pdfEngineLoader, type PageView } from "./pages";
import { PageError, type PageFormat } from "./shared";

type Props = {
  asset: ReaderAsset & { format: PageFormat };
  start: Locator | null;
  savedElsewhere: boolean;
  pageEngine: PageEngine | undefined;
  record: (place: ProgressPlace, at?: number) => void;
  registerPlace: (show: ((progress: StoredProgress) => void) | null) => void;
};

const NAMES: Record<PageFormat, string> = { pdf: "PDF", cbz: "comic" };

function failureText(error: unknown, format: PageFormat): string {
  if (error instanceof PageError || error instanceof PageEngineError) return error.message;
  return `This ${NAMES[format]} couldn't be opened.`;
}

function openingNotice(savedElsewhere: boolean, asset: ReaderAsset): string | null {
  if (!savedElsewhere) return null;
  return `Your saved place is in another file or an earlier edition of this book, so this ${NAMES[asset.format as PageFormat]} opens at its first page. That place is kept until you turn a page here.`;
}

function zoomLabel(view: PageView | null): string {
  return view?.zoomed ? `${Math.round(view.zoom * 100)}%` : "Fit";
}

export function PagesReader({ asset, start, savedElsewhere, pageEngine, record, registerPlace }: Props) {
  const { guard, revalidate } = useServices();
  const shownPosition = useRef(0);
  const stage = useRef<HTMLDivElement>(null);
  const session = useRef<PageSession | null>(null);
  const [phase, setPhase] = useState<"opening" | "ready" | "failed">("opening");
  const [view, setView] = useState<PageView | null>(null);
  const [draft, setDraft] = useState("");
  const [failure, setFailure] = useState<string | null>(null);
  const [restoreNote, setRestoreNote] = useState<string | null>(null);
  const inputId = useId();
  const [initial] = useState(() => start);
  const assetId = asset.id;
  const format = asset.format;
  const engineAddress = pageEngine?.engine;
  const [resources] = useState(() => (pageEngine ? pageResources(pageEngine) : null));
  const [target] = useState(() => asset);

  useEffect(() => {
    const element = stage.current;
    if (!element) return;
    if (format === "pdf" && (!engineAddress || !resources)) {
      setFailure("This server's reader has no PDF renderer, so this PDF can't be opened here.");
      setPhase("failed");
      return;
    }
    const opened = new PageSession(
      element,
      target,
      { resources, fetch: guardedFetch(guard), loadEngine: engineAddress ? pdfEngineLoader(engineAddress) : undefined },
      {
        view: (next) => {
          setView(next);
          if (next.position !== shownPosition.current) setDraft(String(next.position));
          shownPosition.current = next.position;
        },
        moved: record,
        failed: (message) => {
          setFailure(message);
          if (message) revalidate();
        },
      },
    );
    session.current = opened;
    let cancelled = false;
    opened
      .open(initial)
      .then((opening) => {
        if (cancelled) return;
        if (initial && !opening.exact) setRestoreNote(`Your saved page isn't in this file any more, so page ${opening.position} is shown. Your saved place is kept until you turn a page.`);
        setPhase("ready");
      })
      .catch((error: unknown) => {
        if (cancelled || (error instanceof DOMException && error.name === "AbortError")) return;
        setFailure(failureText(error, format));
        setPhase("failed");
        revalidate();
      });
    return () => {
      cancelled = true;
      opened.destroy();
      session.current = null;
    };
  }, [assetId, format, engineAddress, resources, target, guard, initial, record, revalidate]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => session.current?.key(event);
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, []);

  useEffect(() => {
    registerPlace((progress) => {
      if (progress.asset_id !== assetId || !progress.locator) return;
      session.current?.showRemote(progress.locator).catch(() => setFailure("Couldn't open the other device's page."));
    });
    return () => registerPlace(null);
  }, [registerPlace, assetId]);

  const ready = phase === "ready";
  const count = view?.count ?? asset.page_count ?? 0;
  const position = view?.position ?? 0;
  const notice = openingNotice(savedElsewhere, asset) ?? restoreNote;
  const jump = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const value = Number(draft);
    if (Number.isInteger(value) && value >= 1 && value <= count) session.current?.go(value);
    else setDraft(String(position));
  };
  const zoom = (step: (current: PageSession) => Promise<void>) => {
    const current = session.current;
    if (current) step(current).catch(() => setFailure("This page couldn't be zoomed. Try again."));
  };
  return (
    <section className="pages" aria-label={format === "pdf" ? "PDF pages" : "Comic pages"}>
      <div className="reader-toolbar">
        <form className="page-jump" onSubmit={jump}>
          <label htmlFor={inputId}>Page</label>
          <input
            id={inputId}
            type="number"
            inputMode="numeric"
            min={1}
            max={count || undefined}
            step={1}
            required
            value={draft}
            disabled={!ready}
            onChange={(event) => setDraft(event.currentTarget.value)}
          />
          <span className="page-total">{count > 0 ? `of ${count}` : ""}</span>
          <button type="submit" className="button" disabled={!ready}>
            Go to page
          </button>
        </form>
        <div className="zoom-controls" role="group" aria-label="Zoom">
          <button type="button" className="button" disabled={!ready} aria-disabled={!view?.zoomed} onClick={() => zoom((current) => current.zoomOut())}>
            Zoom out
          </button>
          <button type="button" className="button" disabled={!ready} aria-disabled={!view?.zoomed} onClick={() => zoom((current) => current.fitPage())}>
            Fit page
          </button>
          <button type="button" className="button" disabled={!ready} aria-disabled={(view?.zoom ?? 1) >= 4} onClick={() => zoom((current) => current.zoomIn())}>
            Zoom in
          </button>
          <span className="zoom-value" aria-live="polite">
            {zoomLabel(view)}
          </span>
        </div>
      </div>
      {notice ? (
        <p className="notice reader-notice" role="note">
          {notice}
        </p>
      ) : null}
      {failure ? (
        <p className="form-error reader-error" role="alert">
          {failure}
        </p>
      ) : null}
      <div className="pages-stage">
        <div className="pages-view" ref={stage} />
        {phase === "opening" ? (
          <div className="epub-opening">
            <Loading label={`Opening your ${NAMES[format]}…`} />
          </div>
        ) : null}
      </div>
      <div className="page-controls">
        <button type="button" className="button" disabled={!ready} aria-disabled={position <= 1} onClick={() => session.current?.previous()}>
          <span aria-hidden="true">←</span> Previous page
        </button>
        <p className="epub-location" aria-live="polite">
          {position > 0 ? `Page ${position} of ${count}` : phase === "opening" ? "Opening…" : ""}
        </p>
        <button type="button" className="button" disabled={!ready} aria-disabled={position >= count} onClick={() => session.current?.next()}>
          Next page <span aria-hidden="true">→</span>
        </button>
      </div>
    </section>
  );
}
