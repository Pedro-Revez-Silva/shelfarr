import { QueryClientProvider, useQuery } from "@tanstack/react-query";
import { useCallback, useEffect, useRef, useState, useSyncExternalStore, type MouseEvent, type ReactNode } from "react";
import type { ProgressPlace, ReaderPublication, StoredProgress } from "../contract";
import { LockedScreen } from "../components/LockedScreen";
import { ErrorPanel, Loading } from "../components/States";
import { useAccountRevalidation } from "../revalidation";
import { useGuardState, useServices } from "../services";
import { useDocumentTitle } from "../title";
import { AudioPlayer } from "./AudioPlayer";
import { EpubReader } from "./EpubReader";
import { ProgressSession } from "./progress";
import { SaveStatus } from "./SaveStatus";

const READER_PATH = /^\/library\/([1-9]\d{0,18})\/read$/;

export function readerPublicationId(pathname: string, mount: string): string | null {
  if (!pathname.startsWith(`${mount}/`)) return null;
  return READER_PATH.exec(pathname.slice(mount.length))?.[1] ?? null;
}

export function ReaderApp({ engine }: { engine: string | undefined }) {
  const services = useServices();
  const guard = useGuardState();
  const id = readerPublicationId(window.location.pathname, services.boot.mount);
  if (guard.status !== "active") return <LockedScreen reason={guard.status} classicLibrary={null} />;
  return (
    <QueryClientProvider client={services.queryClient}>
      {id && engine ? <ActiveReader id={id} engine={engine} /> : <MissingReader mount={services.boot.mount} />}
    </QueryClientProvider>
  );
}

function MissingReader({ mount }: { mount: string }) {
  useDocumentTitle("Reader unavailable");
  return (
    <main id="main" className="reader-missing">
      <h1>This reader is not available</h1>
      <p>The address does not name a book this server can open.</p>
      <p className="state-actions">
        <a className="button button--primary" href={`${mount}/library`}>
          Back to the library
        </a>
      </p>
    </main>
  );
}

function ActiveReader({ id, engine }: { id: string; engine: string }) {
  const { api, keys } = useServices();
  useAccountRevalidation();
  const reader = useQuery({
    queryKey: [...keys.root, "reader", id],
    queryFn: ({ signal }) => api.reader(id, signal),
    staleTime: Number.POSITIVE_INFINITY,
    gcTime: 0,
    refetchOnWindowFocus: false,
    refetchOnReconnect: false,
  });
  useDocumentTitle(reader.data?.title ?? (reader.isError ? "Book unavailable" : "Opening book"));
  if (reader.isPending) {
    return (
      <ReaderFrame id={id} title="Opening book" author={null}>
        <Loading label="Opening your book…" />
      </ReaderFrame>
    );
  }
  if (reader.isError) {
    return (
      <ReaderFrame id={id} title="This book could not be opened" author={null}>
        <ErrorPanel error={reader.error} onRetry={() => void reader.refetch()} />
      </ReaderFrame>
    );
  }
  return <OpenReader key={reader.data.id} publication={reader.data} engine={engine} />;
}

export type BackTarget = { href: string; label: string; returns: boolean };

export function backTarget(referrer: string, id: string, mount: string, origin: string): BackTarget {
  const details = `${mount}/library/${id}`;
  let from: URL | null = null;
  try {
    from = referrer ? new URL(referrer) : null;
  } catch {
    from = null;
  }
  if (from && from.origin === origin && from.pathname === `${mount}/library`) return { href: `${mount}/library${from.search}`, label: "Back to the library", returns: true };
  return { href: details, label: "Back to the book", returns: from !== null && from.origin === origin && from.pathname === details };
}

const LEAVE_WAIT_MS = 4000;

async function goBack(event: MouseEvent<HTMLAnchorElement>, target: BackTarget, beforeLeave: (() => Promise<void>) | undefined) {
  if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
  event.preventDefault();
  await beforeLeave?.();
  if (target.returns && window.history.length > 1) window.history.back();
  else window.location.assign(target.href);
}

type FrameProps = { id: string; title: string; author: string | null; kind?: string; children: ReactNode; footer?: ReactNode; beforeLeave?: () => Promise<void> };

function ReaderFrame({ id, title, author, kind, children, footer, beforeLeave }: FrameProps) {
  const { boot } = useServices();
  const [target] = useState(() => backTarget(document.referrer, id, boot.mount, window.location.origin));
  return (
    <div className="reader">
      <header className="reader-header">
        <a className="back-link reader-back" href={target.href} onClick={(event) => void goBack(event, target, beforeLeave)}>
          <span aria-hidden="true">←</span>
          {target.label}
        </a>
        <div className="reader-title">
          {kind ? <p className="eyebrow">{kind}</p> : null}
          <h1 id="reader-heading">{title}</h1>
          {author ? <p className="reader-author">{author}</p> : null}
        </div>
      </header>
      <main id="main" className="reader-main" aria-labelledby="reader-heading">
        {children}
      </main>
      {footer ? <footer className="reader-footer">{footer}</footer> : null}
    </div>
  );
}

function OpenReader({ publication, engine }: { publication: ReaderPublication; engine: string }) {
  const { api, guard } = useServices();
  const [session] = useState(
    () =>
      new ProgressSession({
        write: (body, options) => api.saveProgress(publication.id, body, options),
        guard,
        assets: new Set(publication.assets.map((asset) => asset.id)),
        saved: publication.progress,
      }),
  );
  const showPlace = useRef<((progress: StoredProgress) => void) | null>(null);
  const leaving = useRef<(() => void) | null>(null);
  const state = useSyncExternalStore(session.subscribe, session.getState, session.getState);

  useEffect(() => {
    const leave = () => session.flush({ keepalive: true });
    window.addEventListener("pagehide", leave);
    return () => {
      window.removeEventListener("pagehide", leave);
      session.flush({ keepalive: true });
      session.stop();
    };
  }, [session]);

  useEffect(() => guard.subscribe(() => session.stop()), [guard, session]);

  useEffect(() => {
    const warn = (event: BeforeUnloadEvent) => {
      if (session.unsaved) event.preventDefault();
    };
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [session]);

  const record = useCallback((place: ProgressPlace, at?: number) => session.record(place, at), [session]);
  const flush = useCallback(() => session.flush(), [session]);
  const registerPlace = useCallback((show: ((progress: StoredProgress) => void) | null) => {
    showPlace.current = show;
  }, []);
  const registerLeave = useCallback((leave: (() => void) | null) => {
    leaving.current = leave;
  }, []);
  const beforeLeave = useCallback(async () => {
    leaving.current?.();
    await session.drain(LEAVE_WAIT_MS);
  }, [session]);
  const goToRemotePlace = () => {
    const remote = session.useRemote();
    if (remote) showPlace.current?.(remote);
  };

  const listening = publication.book_type === "audiobook";
  const footer = <SaveStatus state={state} onRetry={() => session.retry()} onKeep={() => session.keepLocal()} onUseRemote={goToRemotePlace} onDismiss={() => session.dismissRemote()} />;
  const body =
    publication.assets.length === 0 ? (
      <Unreadable publication={publication} />
    ) : listening ? (
      <AudioPlayer publication={publication} record={record} flush={flush} registerPlace={registerPlace} registerLeave={registerLeave} />
    ) : (
      <EpubReader publication={publication} engine={engine} record={record} registerPlace={registerPlace} />
    );
  return (
    <ReaderFrame id={publication.id} title={publication.title} author={publication.author} kind={listening ? "Listening" : "Reading"} footer={footer} beforeLeave={beforeLeave}>
      {body}
    </ReaderFrame>
  );
}

const FORMAT_NAMES: Record<string, string> = { pdf: "PDF", cbz: "comic (CBZ)", epub: "EPUB" };

function Unreadable({ publication }: { publication: ReaderPublication }) {
  const formats = publication.other_formats.map((format) => FORMAT_NAMES[format] ?? format.toUpperCase());
  return (
    <div className="state state--empty" role="note">
      <h2>This book can't be opened in this browser yet</h2>
      <p>
        {formats.length > 0
          ? `Its ${formats.join(" and ")} file is kept on the server and still works in the native Shelfarr apps; this experimental reader opens EPUBs and audiobooks only.`
          : "Its files are not available on the server right now."}{" "}
        Your saved place is kept.
      </p>
    </div>
  );
}
