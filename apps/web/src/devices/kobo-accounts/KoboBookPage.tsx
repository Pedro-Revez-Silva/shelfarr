import { getRouteApi, Link } from "@tanstack/react-router";
import { useId, useState } from "react";
import { PageHeading } from "../../components/PageHeading";
import { AccountRail } from "../../components/PersonalSettings";
import { Time } from "../../components/requestText";
import { EmptyState, ErrorPanel, Loading } from "../../components/States";
import { Said, useSay } from "../../server/extras";
import { useServices } from "../../services";
import { useDocumentTitle } from "../../title";
import { ToneLine } from "../kobo/KoboParts";
import * as api from "./api";
import type { KoboBook } from "./contract";
import { DevicesBackLink } from "./KoboAccountPage";
import { isMissing, koboAccountFailure, useBookWrite, useKoboBook } from "./queries";
import "./kobo-accounts.css";

const routeApi = getRouteApi("/account/devices/kobo-books/$bookId");

export function KoboBookPage() {
  const { bookId } = routeApi.useParams();
  return <BookPage key={bookId} bookId={bookId} />;
}

function BookPage({ bookId }: { bookId: string }) {
  const { mode } = useServices();
  const book = useKoboBook(bookId);
  const missing = book.isError && isMissing(book.error);
  const shown = missing ? undefined : book.data;
  useDocumentTitle(shown ? `${shown.title} · Devices` : "Kobo book · Devices");
  return (
    <section className="account kobo-account" aria-labelledby="kobo-book-heading">
      {shown ? <CatalogueBackLink book={shown} /> : <DevicesBackLink hash="kobo-accounts" />}
      <PageHeading id="kobo-book-heading">{shown?.title ?? "Kobo book"}</PageHeading>
      <p className="lede">Only you see and change these.</p>
      <AccountRail current="devices" />
      {mode !== "rails" ? (
        <EmptyState title="Kobo books are not available here">
          <p>This server does not manage Kobo accounts. Nothing was changed.</p>
        </EmptyState>
      ) : missing ? (
        <EmptyState title="This Kobo book is not available to you">
          <p>Its catalogue may have stopped being shared with you, or its owner disconnected it. Copies already downloaded stay on your Kobo.</p>
          <Link to="/account/$section" params={{ section: "devices" }} hash="kobo-shared" className="button">
            Your devices
          </Link>
        </EmptyState>
      ) : book.data ? (
        <BookView book={book.data} />
      ) : book.isError ? (
        <ErrorPanel error={book.error} onRetry={() => void book.refetch()} />
      ) : (
        <Loading label="Loading this Kobo book…" />
      )}
    </section>
  );
}

function CatalogueBackLink({ book }: { book: KoboBook }) {
  const route = book.kobo_account.owner ? "/account/devices/kobo-accounts/$accountId" : "/account/devices/kobo-shared/$accountId";
  return (
    <p className="people-back">
      <Link to={route} params={{ accountId: book.kobo_account.id }}>
        <span aria-hidden="true">← </span>
        {book.kobo_account.name}
      </Link>
    </p>
  );
}

function BookView({ book }: { book: KoboBook }) {
  const { said, say } = useSay();
  return (
    <div className="account-sections">
      <div className="kobo-book-summary">
        <Cover book={book} />
        <div className="kobo-delivery-text">
          <p>{book.author ?? "Unknown author"}</p>
          <p className="muted">From {book.from}</p>
        </div>
      </div>
      <Eligibility book={book} />
      {book.deliverable && book.copy ? (
        <>
          <PrivateCopy book={book} say={say} />
          <SendToReaders book={book} say={say} />
        </>
      ) : null}
      <Said said={said} />
    </div>
  );
}

function Cover({ book }: { book: KoboBook }) {
  const [failed, setFailed] = useState<string | null>(null);
  if (!book.cover || failed === book.cover) return null;
  const cover = book.cover;
  return <img className="kobo-book-cover" src={cover} alt="" loading="lazy" decoding="async" onError={() => setFailed(cover)} />;
}

function Eligibility({ book }: { book: KoboBook }) {
  const headingId = useId();
  return (
    <section className="account-card" aria-labelledby={headingId}>
      <h2 id={headingId}>Can it be sent?</h2>
      <ToneLine notice={{ tone: book.eligibility.tone, text: book.eligibility.label, choosable: false }} testId="kobo-eligibility" />
      <p className="muted">{book.eligibility.detail}</p>
      {book.offered ? <p className="muted">{book.offered}</p> : null}
    </section>
  );
}

type Say = (tone: "success" | "error", text: string) => void;

function settle(say: Say, fallback: string) {
  return {
    onSuccess: (answer: api.BookAnswer) => say(answer.kind === "done" ? "success" : "error", answer.kind === "done" ? (answer.notice ?? fallback) : answer.message),
    onError: (error: unknown) => say("error", koboAccountFailure(error, "Shelfarr could not confirm the change. The page shows the current state.")),
  };
}

function PrivateCopy({ book, say }: { book: KoboBook; say: Say }) {
  const headingId = useId();
  const { api: client } = useServices();
  const prepare = useBookWrite(book.id, (copy: string | null) => api.prepare(client, book.id, copy));
  const copy = book.copy;
  if (!copy) return null;
  const start = () => {
    if (!prepare.isPending) prepare.mutate(copy.version, settle(say, "Preparing a private copy."));
  };
  const button = (label: string, primary: boolean) => (
    <div className="form-actions">
      <button type="button" className={primary ? "button button--primary" : "button"} aria-disabled={prepare.isPending ? true : undefined} aria-busy={prepare.isPending} onClick={start}>
        {prepare.isPending ? "Asking for a copy…" : label}
      </button>
    </div>
  );
  return (
    <section className="account-card" aria-labelledby={headingId}>
      <h2 id={headingId}>Private copy</h2>
      {copy.failure ? (
        <p role="alert" className="kobo-tone kobo-tone--warning" data-testid="kobo-copy-error">
          {copy.failure}
        </p>
      ) : null}
      {copy.preparing ? (
        <p role="status" className="kobo-progress">
          Preparing a private copy from Kobo… This page updates when it finishes.
        </p>
      ) : null}
      {copy.preparing ? null : copy.ready ? (
        <>
          <p data-testid="kobo-copy-status">
            Ready · {copy.ready.summary}, prepared <Time iso={copy.ready.prepared_at} relative />
          </p>
          {copy.ready.stale ? (
            <>
              <p className="kobo-tone kobo-tone--warning" data-testid="kobo-copy-stale">
                Kobo now lists a newer edition of this book. Readers that already received this copy keep it; prepare again to send the newer one.
              </p>
              {button("Prepare newer edition", false)}
            </>
          ) : null}
        </>
      ) : copy.unavailable ? (
        <p className="kobo-tone kobo-tone--warning">{copy.unavailable}</p>
      ) : (
        <>
          {copy.explanation ? <p className="muted">{copy.explanation}</p> : null}
          {button(copy.failure ? "Try again" : "Prepare copy", true)}
        </>
      )}
    </section>
  );
}

function SendToReaders({ book, say }: { book: KoboBook; say: Say }) {
  const headingId = useId();
  const { api: client } = useServices();
  const deliver = useBookWrite(book.id, ({ readerId, copy }: { readerId: string; copy: string | null }) => api.deliver(client, book.id, readerId, copy));
  const ready = Boolean(book.copy?.ready);
  const owner = book.kobo_account.owner;
  return (
    <section className="account-card" aria-labelledby={headingId}>
      <h2 id={headingId}>Send to your Kobo</h2>
      {book.readers.length === 0 ? (
        <>
          <p data-testid="kobo-no-reader">You haven't connected a Kobo reader to Shelfarr yet.</p>
          <p className="muted">
            Set up your reader in{" "}
            <Link to="/account/$section" params={{ section: "devices" }} hash="kobo-readers">
              Kobo readers
            </Link>
            . It keeps its own Kobo sign-in; this account is never added to it.
          </p>
        </>
      ) : (
        <>
          {ready ? null : <p className="muted">You can send it to these readers once the private copy is ready.</p>}
          <ul className="kobo-reader-list">
            {book.readers.map((reader) => (
              <li key={reader.id} data-testid="kobo-send-target" className="kobo-row">
                <div className="kobo-delivery-text">
                  <p>{reader.name}</p>
                  <p className="request-meta">
                    {reader.status}
                    {reader.older_copy ? " · an older copy" : ""}
                  </p>
                </div>
                {ready ? (
                  <button
                    type="button"
                    className={reader.sent ? "button" : "button button--primary"}
                    aria-disabled={deliver.isPending ? true : undefined}
                    aria-busy={deliver.isPending}
                    onClick={() => (deliver.isPending ? undefined : deliver.mutate({ readerId: reader.id, copy: book.copy?.version ?? null }, settle(say, `Queued for ${reader.name}.`)))}
                  >
                    {reader.sent ? "Send again" : "Send"}
                    <span className="sr-only"> to {reader.name}</span>
                  </button>
                ) : null}
              </li>
            ))}
          </ul>
          <p className="muted">
            The book arrives beside your own books at the reader's next Wi-Fi sync. Reading places stay on that reader.{" "}
            {owner ? "A reader signed in to this same Kobo account may also show the Store's own copy." : `If ${book.kobo_account.owner_name} stops sharing, Shelfarr stops offering this book, but a copy already downloaded stays on your Kobo.`}
          </p>
        </>
      )}
    </section>
  );
}
