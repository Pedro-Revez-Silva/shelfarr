import { QueryClientProvider, useQuery } from "@tanstack/react-query";
import { useCallback, useEffect, useRef, useState, useSyncExternalStore } from "react";
import type { Locator, PageEngine, ProgressPlace, ReaderAsset, ReaderPublication, StoredProgress } from "../contract";
import { failureKind } from "../api/errors";
import { LockedScreen } from "../components/LockedScreen";
import { ErrorPanel, Loading } from "../components/States";
import { useAccountRevalidation } from "../revalidation";
import { useGuardState, useServices } from "../services";
import { useDocumentTitle } from "../title";
import { AudioPlayer } from "./AudioPlayer";
import { EpubReader } from "./EpubReader";
import { isPageFormat } from "./pages";
import { PagesReader } from "./PagesReader";
import { ProgressSession } from "./progress";
import { ReaderFrame } from "./ReaderFrame";
import { readerPublicationId } from "./links";
import { SaveStatus } from "./SaveStatus";
import { useOffline } from "../offline/context";
import { savedEpub } from "../offline/model";
import { useRememberedPlace } from "../offline/remembered";
import { OfflineNotSavable, SaveForOffline } from "../offline/SaveForOffline";

type Engines = { engine: string; pageEngine: PageEngine | undefined };

export function ReaderApp({ engine, pageEngine }: { engine: string | undefined; pageEngine?: PageEngine | undefined }) {
  const services = useServices();
  const guard = useGuardState();
  const id = readerPublicationId(window.location.pathname, services.boot.mount, services.mode);
  if (guard.status !== "active") return <LockedScreen reason={guard.status} classicLibrary={null} />;
  return (
    <QueryClientProvider client={services.queryClient}>
      {id && engine ? <ActiveReader id={id} engine={engine} pageEngine={pageEngine} /> : <MissingReader mount={services.boot.mount} />}
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

function ActiveReader({ id, engine, pageEngine }: { id: string } & Engines) {
  const { api, keys, revalidate } = useServices();
  useAccountRevalidation();
  const reader = useQuery({
    queryKey: [...keys.root, "reader", id],
    queryFn: ({ signal }) => api.reader(id, signal),
    staleTime: Number.POSITIVE_INFINITY,
    gcTime: 0,
    refetchOnWindowFocus: false,
    refetchOnReconnect: false,
  });
  const refused = reader.isError && failureKind(reader.error) === "not_found";
  useEffect(() => {
    if (refused) revalidate();
  }, [refused, revalidate]);
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
  return <OpenReader key={reader.data.id} publication={reader.data} engine={engine} pageEngine={pageEngine} />;
}

const LEAVE_WAIT_MS = 4000;

const OPENING_ORDER: Record<ReaderPublication["content_kind"], readonly string[]> = { graphic: ["cbz", "pdf", "epub"], book: ["epub", "pdf", "cbz"] };

export function chosenAsset(publication: ReaderPublication): ReaderAsset | null {
  const saved = publication.assets.find((asset) => asset.id === publication.progress?.asset_id);
  if (saved) return saved;
  for (const format of OPENING_ORDER[publication.content_kind]) {
    const found = publication.assets.find((asset) => asset.format === format);
    if (found) return found;
  }
  return null;
}

export type Opening = { asset: ReaderAsset | null; start: Locator | null; savedElsewhere: boolean };

export function firstOpening(publication: ReaderPublication): Opening {
  const asset = chosenAsset(publication);
  const saved = publication.progress;
  const here = asset !== null && saved?.asset_id === asset.id;
  return { asset, start: here ? (saved?.locator ?? null) : null, savedElsewhere: saved !== null && !here };
}

export type RemoteOpening = { kind: "show" } | { kind: "open"; opening: Opening } | { kind: "unavailable" };

export function remoteOpening(publication: ReaderPublication, current: ReaderAsset | null, remote: StoredProgress): RemoteOpening {
  const asset = publication.assets.find((candidate) => candidate.id === remote.asset_id);
  if (!asset) return { kind: "unavailable" };
  if (asset.id === current?.id) return { kind: "show" };
  return { kind: "open", opening: { asset, start: remote.locator, savedElsewhere: false } };
}

const REMOTE_UNAVAILABLE = "The other device's place is in a file this reader doesn't list any more, so it can't be shown here. Your account keeps it until you turn a page.";

function OpenReader({ publication, engine, pageEngine }: { publication: ReaderPublication } & Engines) {
  const { api, guard } = useServices();
  const offline = useOffline();
  const savedCopy = useRememberedPlace(offline, guard.account, publication);
  const [session] = useState(
    () =>
      new ProgressSession({
        write: (body, options) => api.saveProgress(publication.id, body, options),
        guard,
        assets: new Set(publication.assets.map((asset) => asset.id)),
        saved: publication.progress,
        confirmed: (progress) => savedCopy.remember(progress),
      }),
  );
  const showPlace = useRef<((progress: StoredProgress) => void) | null>(null);
  const [opening, setOpening] = useState(() => firstOpening(publication));
  const [remoteNote, setRemoteNote] = useState<string | null>(null);
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
  const listening = publication.book_type === "audiobook";
  const goToRemotePlace = () => {
    const remote = session.useRemote();
    if (!remote) return;
    if (listening) {
      showPlace.current?.(remote);
      return;
    }
    const decision = remoteOpening(publication, opening.asset, remote);
    showPlace.current?.(remote);
    setRemoteNote(decision.kind === "unavailable" ? REMOTE_UNAVAILABLE : null);
    if (decision.kind === "open") setOpening(decision.opening);
  };

  const asset = listening ? null : opening.asset;
  const footer = <SaveStatus state={state} onRetry={() => session.retry()} onKeep={() => session.keepLocal()} onUseRemote={goToRemotePlace} onDismiss={() => session.dismissRemote()} />;
  const body =
    publication.assets.length === 0 ? (
      <Unreadable publication={publication} />
    ) : listening ? (
      <AudioPlayer publication={publication} record={record} flush={flush} registerPlace={registerPlace} registerLeave={registerLeave} />
    ) : asset && isPageAsset(asset) ? (
      <PagesReader key={asset.id} asset={asset} start={opening.start} savedElsewhere={opening.savedElsewhere} pageEngine={pageEngine} record={record} registerPlace={registerPlace} />
    ) : asset?.format === "epub" ? (
      <EpubReader
        key={asset.id}
        asset={asset}
        start={opening.start}
        savedElsewhere={opening.savedElsewhere}
        engine={engine}
        record={record}
        registerPlace={registerPlace}
        offer={savedCopy.offer(asset.id)}
      />
    ) : (
      <Unreadable publication={publication} />
    );
  const epub = savedEpub(publication);
  const tools = epub ? (
    <SaveForOffline id={publication.id} title={publication.title} currentAsset={epub.id} load={async () => publication} compact />
  ) : publication.assets.length > 0 ? (
    <OfflineNotSavable kind={listening ? "listen" : (UNSAVED_FORMATS[asset?.format ?? ""] ?? "")} fallback={publication.classic_reader?.url ?? null} compact />
  ) : null;
  const elsewhere = listening ? null : savedCopy.elsewhere(asset?.id ?? null);
  const openElsewhere = () => {
    const target = publication.assets.find((candidate) => candidate.id === elsewhere?.assetId);
    if (target && elsewhere) setOpening({ asset: target, start: elsewhere.locator, savedElsewhere: false });
  };
  return (
    <ReaderFrame id={publication.id} title={publication.title} author={publication.author} kind={listening ? "Listening" : "Reading"} footer={footer} tools={tools} beforeLeave={beforeLeave}>
      {remoteNote ? (
        <p className="notice reader-notice" role="status">
          {remoteNote}
        </p>
      ) : null}
      {publication.classic_reader?.read_along ? (
        <div className="notice reader-notice reader-offer" role="note">
          <p>This book has read-along narration, which this reader doesn't play yet. Your place is shared, so you can switch at any time.</p>
          <a className="button" href={publication.classic_reader.url}>
            Open with read-along
          </a>
        </div>
      ) : null}
      {publication.classic_reader && !listening && publication.assets.length > 1 ? (
        <div className="notice reader-notice reader-offer" role="note">
          <p>{`This book has ${publication.assets.length} files and this reader opens one. To read another, choose it in the web reader.`}</p>
          <a className="button" href={publication.classic_reader.url}>
            Choose a file
          </a>
        </div>
      ) : null}
      {elsewhere ? (
        <div className="notice reader-notice reader-offer" role="note">
          <p>{elsewhere.text}</p>
          <button type="button" className="button" onClick={openElsewhere}>
            {elsewhere.action}
          </button>
        </div>
      ) : null}
      {body}
    </ReaderFrame>
  );
}

function isPageAsset(asset: ReaderAsset): asset is ReaderAsset & { format: "pdf" | "cbz" } {
  return isPageFormat(asset.format);
}

const UNSAVED_FORMATS: Record<string, string> = { pdf: "PDF", cbz: "Comic" };

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
