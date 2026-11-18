import { useEffect, useRef, useState } from "react";
import type { Locator, ProgressPlace, ReaderAsset, StoredProgress } from "../contract";
import { Loading } from "../components/States";
import { useServices } from "../services";
import { EngineError, loadEngine } from "./engine";
import { EpubSession, FONT_SIZES, type Chapter, type EpubPosition } from "./epub";
import { pageKey } from "./keys";
import { fetchBook, ReaderFailure } from "./media";

export const WEB_EBOOK_LIMIT = 32 * 1024 * 1024;

type Props = {
  asset: ReaderAsset;
  start: Locator | null;
  savedElsewhere: boolean;
  engine: string;
  record: (place: ProgressPlace, at?: number) => void;
  registerPlace: (show: ((progress: StoredProgress) => void) | null) => void;
};

function openingNotice(savedElsewhere: boolean): string | null {
  if (!savedElsewhere) return null;
  return "Your saved place is in another file or an earlier edition of this book, so this EPUB opens at its beginning. That place is kept until you turn a page here.";
}

function themeColors(): { ink: string; surface: string } {
  const style = getComputedStyle(document.body);
  return { ink: style.getPropertyValue("--ink").trim(), surface: style.getPropertyValue("--surface").trim() };
}

function failureText(error: unknown): string {
  if (error instanceof ReaderFailure || error instanceof EngineError) return error.message;
  return "This EPUB couldn't be opened.";
}

function currentChapter(chapters: Chapter[], position: EpubPosition | null): string {
  if (!position) return "";
  return chapters.find((chapter) => chapter.href.split("#")[0] === position.href)?.href ?? "";
}

export function EpubReader({ asset, start, savedElsewhere, engine, record, registerPlace }: Props) {
  const { guard } = useServices();
  const viewport = useRef<HTMLDivElement>(null);
  const session = useRef<EpubSession | null>(null);
  const [phase, setPhase] = useState<"opening" | "ready" | "failed">("opening");
  const [chapters, setChapters] = useState<Chapter[]>([]);
  const [position, setPosition] = useState<EpubPosition | null>(null);
  const [failure, setFailure] = useState<string | null>(null);
  const [textSize, setTextSize] = useState<number>(FONT_SIZES.initial);
  const assetId = asset.id;
  const assetUrl = asset.url;
  const assetSize = asset.size_bytes;
  const [initial] = useState(() => start);

  useEffect(() => {
    const element = viewport.current;
    if (!element) return;
    const controller = new AbortController();
    let opened: EpubSession | null = null;
    let cancelled = false;
    const open = async () => {
      if (assetSize > WEB_EBOOK_LIMIT) throw new ReaderFailure("This ebook is larger than the web reader's 32 MiB limit. Use a native Shelfarr app to read it.");
      const [loaded, buffer] = await Promise.all([loadEngine(engine), fetchBook(assetUrl, guard, controller.signal)]);
      if (cancelled) return;
      opened = new EpubSession(loaded, element, assetId, {
        position: setPosition,
        moved: record,
        key: (event) => turnWithKey(event, opened),
        failed: setFailure,
      });
      session.current = opened;
      const list = await opened.open(buffer, initial, themeColors());
      if (cancelled) return;
      setChapters(list);
      setPhase("ready");
    };
    open().catch((error: unknown) => {
      if (cancelled || (error instanceof DOMException && error.name === "AbortError")) return;
      setFailure(failureText(error));
      setPhase("failed");
    });
    return () => {
      cancelled = true;
      controller.abort();
      opened?.destroy();
      session.current = null;
    };
  }, [assetId, assetUrl, assetSize, engine, guard, initial, record]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => turnWithKey(event, session.current);
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, []);

  useEffect(() => {
    registerPlace((progress) => {
      session.current?.forgetMoves();
      if (progress.asset_id !== assetId || !progress.locator) return;
      session.current?.showRemote(progress.locator).catch(() => setFailure("Couldn't open the other device's place."));
    });
    return () => registerPlace(null);
  }, [registerPlace, assetId]);

  const ready = phase === "ready";
  const notice = openingNotice(savedElsewhere);
  const changeSize = (delta: number) => {
    void session.current?.changeTextSize(delta).then(setTextSize, () => setFailure("Text size couldn't be changed. Try again."));
  };
  return (
    <section className="epub" aria-label="Book">
      <div className="reader-toolbar">
        <label className="reader-field">
          <span>Chapter</span>
          <select value={currentChapter(chapters, position)} disabled={!ready || chapters.length === 0} onChange={(event) => session.current?.chooseChapter(event.currentTarget.value)}>
            {currentChapter(chapters, position) === "" ? <option value="">—</option> : null}
            {chapters.map((chapter) => (
              <option key={`${chapter.href}-${chapter.depth}-${chapter.label}`} value={chapter.href}>
                {`${"— ".repeat(chapter.depth)}${chapter.label}`}
              </option>
            ))}
          </select>
        </label>
        <div className="text-size" role="group" aria-label="Text size">
          <button type="button" className="button" disabled={!ready || textSize <= FONT_SIZES.min} onClick={() => changeSize(-FONT_SIZES.step)}>
            Smaller
          </button>
          <span className="text-size-value">{textSize}%</span>
          <button type="button" className="button" disabled={!ready || textSize >= FONT_SIZES.max} onClick={() => changeSize(FONT_SIZES.step)}>
            Larger
          </button>
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
      <div className="epub-stage">
        <div className="epub-viewport" ref={viewport} />
        {phase === "opening" ? (
          <div className="epub-opening">
            <Loading label="Opening your book…" />
          </div>
        ) : null}
      </div>
      <div className="page-controls">
        <button type="button" className="button" disabled={!ready} onClick={() => session.current?.previous()}>
          <span aria-hidden="true">←</span> Previous page
        </button>
        <p className="epub-location" aria-live="polite">
          {position ? `Page ${position.page} of ${position.total} · Chapter ${position.chapter}` : ready ? "" : "Opening…"}
        </p>
        <button type="button" className="button" disabled={!ready} onClick={() => session.current?.next()}>
          Next page <span aria-hidden="true">→</span>
        </button>
      </div>
    </section>
  );
}

function turnWithKey(event: KeyboardEvent, session: EpubSession | null) {
  if (!session) return;
  const direction = pageKey(event);
  if (!direction) return;
  event.preventDefault();
  if (direction === "next") session.next();
  else session.previous();
}
