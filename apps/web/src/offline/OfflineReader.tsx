import { useEffect, useState, useSyncExternalStore } from "react";
import type { ReaderAsset } from "../contract";
import { Loading } from "../components/States";
import { EpubReader } from "../reader/EpubReader";
import { ReaderFrame, readerPublicationId } from "../reader/ReaderApp";
import { useServices } from "../services";
import { useDocumentTitle } from "../title";
import { useOffline, type Offline } from "./context";
import { DevicePlaces, type DeviceSaveState } from "./devicePlaces";
import { openingLocator, type SavedBook } from "./model";

type Opened = { kind: "loading" } | { kind: "missing" } | { kind: "ready"; book: SavedBook; blob: Blob };

const NO_PLACE = () => undefined;

function placeMessage(state: DeviceSaveState): string {
  switch (state.kind) {
    case "idle":
      return "You're reading the copy saved on this device. Places you reach are kept on this device only and aren't sent to your account.";
    case "kept":
      return "Your place is kept on this device only.";
    case "failed":
      return "Couldn't keep your place on this device. Turn the page again to retry.";
    case "stopped":
      return "Stopped keeping places because offline access for this account ended.";
  }
}

export function OfflineReader({ engine }: { engine: string | undefined }) {
  const offline = useOffline();
  const { boot, guard } = useServices();
  const id = readerPublicationId(window.location.pathname, boot.mount);
  const [opened, setOpened] = useState<Opened>({ kind: "loading" });
  useDocumentTitle(opened.kind === "ready" ? opened.book.title : opened.kind === "missing" ? "Not saved on this device" : "Opening saved book");

  useEffect(() => {
    if (!offline || !id) {
      setOpened({ kind: "missing" });
      return;
    }
    let current = true;
    Promise.all([offline.store.book(guard.account, id), offline.store.file(guard.account, id)])
      .then(([book, blob]) => {
        if (current) setOpened(book && blob && guard.isActive() ? { kind: "ready", book, blob } : { kind: "missing" });
      })
      .catch(() => current && setOpened({ kind: "missing" }));
    return () => {
      current = false;
    };
  }, [offline, id, guard]);

  const downloads = offline?.boot.downloads ?? `${boot.mount}/library`;
  const back = { href: downloads, label: "Back to downloads", returns: false };
  if (opened.kind === "loading") {
    return (
      <ReaderFrame id={id ?? ""} title="Opening saved book" author={null} back={back}>
        <Loading label="Opening the copy saved on this device…" />
      </ReaderFrame>
    );
  }
  if (opened.kind === "missing" || !engine || !offline) {
    return (
      <ReaderFrame id={id ?? ""} title="This book isn't saved on this device" author={null} back={back}>
        <div className="state state--empty" role="alert">
          <h2>It can't be opened without a connection</h2>
          <p>Only books saved in this browser for the signed-in account open while the server can't be reached.</p>
          <p className="state-actions">
            <a className="button button--primary" href={downloads}>
              See saved books
            </a>
          </p>
        </div>
      </ReaderFrame>
    );
  }
  return <SavedCopyReader offline={offline} book={opened.book} blob={opened.blob} engine={engine} back={back} />;
}

function SavedCopyReader({ offline, book, blob, engine, back }: { offline: Offline; book: SavedBook; blob: Blob; engine: string; back: { href: string; label: string; returns: boolean } }) {
  const { guard } = useServices();
  const [places] = useState(() => new DevicePlaces(offline.store, book.account, book.id, () => guard.lock("signed_out")));
  const state = useSyncExternalStore(places.subscribe, places.getState, places.getState);
  const [start] = useState(() => openingLocator(book));
  const [source] = useState(() => () => blob.arrayBuffer());
  const asset: ReaderAsset = { id: book.asset.id, filename: book.asset.filename, format: "epub", media_type: book.asset.media_type, size_bytes: book.asset.size_bytes, position: 0, url: back.href };

  useEffect(() => {
    const leave = () => void places.flush();
    window.addEventListener("pagehide", leave);
    const stop = guard.subscribe(() => places.stop());
    return () => {
      window.removeEventListener("pagehide", leave);
      stop();
      void places.flush();
    };
  }, [places, guard]);

  const footer = (
    <div className={`save-status${state.kind === "failed" || state.kind === "stopped" ? " save-status--attention" : ""}`} data-state={state.kind}>
      <p role={state.kind === "failed" ? "alert" : "status"} className="save-status-text">
        {placeMessage(state)}
      </p>
    </div>
  );
  return (
    <ReaderFrame id={book.id} title={book.title} author={book.author} kind="Reading offline" footer={footer} back={back} beforeLeave={() => places.flush()}>
      <EpubReader asset={asset} start={start} savedElsewhere={false} engine={engine} record={places.record} registerPlace={NO_PLACE} source={source} />
    </ReaderFrame>
  );
}
