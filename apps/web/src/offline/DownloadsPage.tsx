import { useCallback, useEffect, useState } from "react";
import { formatBytes } from "../components/DetailsPage";
import { useServices } from "../services";
import { useDocumentTitle } from "../title";
import { announceChange, onChange, useOffline, type Offline } from "./context";
import { ACCOUNT_LIMIT_BYTES, describeLocator, laterDevicePlace, offlineUntil, type Attempt, type SavedBook } from "./model";
import { FAILURES, formatDay, formatMoment } from "./text";

type Listing = { books: SavedBook[]; unfinished: Attempt[]; others: { books: number; bytes: number }; persisted: boolean | null };

async function list(offline: Offline, account: string): Promise<Listing> {
  const [books, attempts, others, persisted] = await Promise.all([
    offline.store.books(account),
    offline.store.attempts(account),
    offline.store.others(account),
    navigator.storage?.persisted?.().catch(() => null) ?? Promise.resolve(null),
  ]);
  const saved = new Set(books.map((book) => book.key));
  return { books, unfinished: attempts.filter((attempt) => !saved.has(attempt.key)), others, persisted };
}

function placeText(book: SavedBook): string {
  const device = laterDevicePlace(book);
  if (device) return `On this device: ${describeLocator(device.locator)} (${formatMoment(device.recordedAt)}), kept here only and not in your account.`;
  if (book.accountPlace?.asset_id === book.asset.id) return `Opens at your account's place when this device last connected: ${describeLocator(book.accountPlace.locator)}.`;
  return "Opens at the beginning.";
}

export function DownloadsPage() {
  const offline = useOffline();
  const { guard, boot } = useServices();
  useDocumentTitle("Downloads");
  const [listing, setListing] = useState<Listing | null>(null);
  const [failed, setFailed] = useState(false);
  const [removing, setRemoving] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const account = guard.account;

  const refresh = useCallback(async () => {
    if (!offline) return;
    try {
      const next = await list(offline, account);
      if (guard.isActive()) {
        setListing(next);
        setFailed(false);
      }
    } catch {
      setFailed(true);
    }
  }, [offline, account, guard]);

  useEffect(() => {
    void refresh();
    const stop = onChange(() => void refresh());
    return stop;
  }, [refresh]);

  if (!offline) return null;
  const confirmation = offline.confirmation;

  const remove = async (book: SavedBook | Attempt) => {
    setRemoving(null);
    const removed = await offline.store.remove(account, book.id).then(
      () => true,
      () => false,
    );
    setNotice(removed ? `Removed “${book.title}” from this browser.` : `This browser couldn't remove “${book.title}”. Reload the page and try again.`);
    announceChange();
    await refresh();
    document.getElementById("downloads-heading")?.focus();
  };

  const removeOthers = async () => {
    const removed = await offline.store.removeOthers(account).then(
      () => true,
      () => false,
    );
    setNotice(removed ? "Removed the books other accounts saved in this browser." : "This browser couldn't remove the other accounts' books. Reload the page and try again.");
    announceChange();
    await refresh();
  };

  const used = listing?.books.reduce((sum, book) => sum + book.asset.size_bytes, 0) ?? 0;
  return (
    <main id="main" className="downloads" aria-labelledby="downloads-heading">
      <header className="downloads-header">
        {offline.connected ? (
          <a className="back-link" href={`${boot.mount}/library`}>
            <span aria-hidden="true">← </span>Library
          </a>
        ) : null}
        <h1 id="downloads-heading" tabIndex={-1}>
          Downloads
        </h1>
        <p className="lede">EPUBs saved in this browser for the signed-in account. They open here even when the server can't be reached.</p>
      </header>
      {offline.connected ? null : (
        <p className="notice downloads-offline" role="status">
          You're offline. Saved books open from this list, and the places you reach are kept on this device only until you connect again.
          {confirmation ? ` Offline access for this account lasts until ${formatMoment(offlineUntil(confirmation))}.` : ""}
        </p>
      )}
      <p className={notice?.startsWith("This browser couldn't") ? "form-error" : "sr-only"} role="status">
        {notice ?? ""}
      </p>
      {failed ? (
        <p className="form-error" role="alert">
          This browser couldn't read its saved books. Reload the page to try again.
        </p>
      ) : null}
      {listing === null && !failed ? (
        <p className="state state--loading" role="status">
          <span className="spinner" aria-hidden="true" />
          Reading this browser's saved books…
        </p>
      ) : null}
      {listing && listing.books.length === 0 && listing.unfinished.length === 0 ? (
        <div className="state state--empty">
          <h2>No books are saved in this browser</h2>
          <p>While connected, open an EPUB's details or the reader and choose Save for offline reading.</p>
        </div>
      ) : null}
      {listing && listing.books.length > 0 ? (
        <ul className="downloads-list" aria-label="Saved books">
          {listing.books.map((book) => (
            <li key={book.key} className="downloads-item">
              <h2 className="downloads-title">{book.title}</h2>
              {book.author ? <p className="downloads-author">{book.author}</p> : null}
              <p className="downloads-meta">{`EPUB · ${formatBytes(book.asset.size_bytes)} · saved ${formatDay(book.savedAt)}`}</p>
              <p className="downloads-place">{placeText(book)}</p>
              <div className="downloads-actions">
                <a className="button button--primary" href={`${boot.mount}/library/${book.id}/read`}>
                  Read<span className="sr-only"> {book.title}</span>
                </a>
                {removing === book.key ? (
                  <span className="downloads-confirm" role="group" aria-label={`Remove ${book.title}`}>
                    <span>Remove it from this browser?</span>
                    <button type="button" className="button button--danger" onClick={() => void remove(book)} autoFocus>
                      Remove
                    </button>
                    <button type="button" className="button" onClick={() => setRemoving(null)}>
                      Keep it
                    </button>
                  </span>
                ) : (
                  <button type="button" className="button button--subtle" onClick={() => setRemoving(book.key)}>
                    Remove<span className="sr-only"> {book.title}</span>
                  </button>
                )}
              </div>
            </li>
          ))}
        </ul>
      ) : null}
      {listing && listing.unfinished.length > 0 ? (
        <section className="downloads-unfinished" aria-labelledby="unfinished-heading">
          <h2 id="unfinished-heading">Not saved</h2>
          <ul className="downloads-list">
            {listing.unfinished.map((attempt) => (
              <li key={attempt.key} className="downloads-item">
                <h3 className="downloads-title">{attempt.title}</h3>
                <p>{attempt.failure ? FAILURES[attempt.failure] : "Saving stopped before it finished, so nothing was stored."}</p>
                <div className="downloads-actions">
                  {offline.connected ? (
                    <a className="button" href={`${boot.mount}/library/${attempt.id}`}>
                      Open details to try again<span className="sr-only"> for {attempt.title}</span>
                    </a>
                  ) : null}
                  <button type="button" className="button button--subtle" onClick={() => void remove(attempt)}>
                    Dismiss<span className="sr-only"> {attempt.title}</span>
                  </button>
                </div>
              </li>
            ))}
          </ul>
        </section>
      ) : null}
      {listing ? (
        <section className="downloads-storage" aria-labelledby="storage-heading">
          <h2 id="storage-heading">Storage in this browser</h2>
          <p>{`Saved books for this account use ${formatBytes(used)} of the ${formatBytes(ACCOUNT_LIMIT_BYTES)} this reader allows.`}</p>
          <p>
            {listing.persisted
              ? "This browser has agreed to keep them until you remove them or clear this site's data."
              : "Your browser may remove them if the device runs low on space; Shelfarr checks each book before opening it."}
          </p>
          {listing.others.books > 0 ? (
            <p className="downloads-others">
              {`This browser also keeps ${listing.others.books} saved ${listing.others.books === 1 ? "book" : "books"} (${formatBytes(listing.others.bytes)}) for another account. They aren't shown here.`}{" "}
              <button type="button" className="button button--subtle" onClick={() => void removeOthers()}>
                Remove them
              </button>
            </p>
          ) : null}
        </section>
      ) : null}
    </main>
  );
}
