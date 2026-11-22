import { getRouteApi, Link, useRouter } from "@tanstack/react-router";
import { useEffect, useRef, useState, type MouseEvent } from "react";
import { failureKind } from "../api/errors";
import type { BookLocation } from "../api/client";
import { workSources, type Book, type BookCopy, type BookFormat, type BookRequest, type PublicationSummary, type Session } from "../contract";
import { useBook, useCancelRequest, useChooseCopy, useRequestBook, useSearchAgain, useSession } from "../queries";
import { useServices } from "../services";
import { usePageTitle } from "../title";
import { Cover } from "./Cover";
import { PageHeading } from "./PageHeading";
import { CopyTable } from "./CopyTable";
import { actionFailure, Time } from "./requestText";
import { choiceFor, FALLBACK_OPTIONS, NO_EXTRAS, offered, RejectedFormats, RequestExtrasFields, requestLabel, requestPlan, type RequestFormat } from "./RequestChoices";
import { EmptyState, ErrorPanel, Loading } from "./States";

const routeApi = getRouteApi("/books/$source/$sourceId");

function isWorkSource(value: string): value is BookLocation["source"] {
  return (workSources as readonly string[]).includes(value);
}

export function BookPage() {
  const { mode } = useServices();
  const { source, sourceId } = routeApi.useParams();
  if (mode !== "rails" || !isWorkSource(source) || !/^[A-Za-z0-9_-]{1,64}$/.test(sourceId)) {
    return (
      <EmptyState title="That page is not part of this preview">
        <p>Use the navigation to return to your library.</p>
      </EmptyState>
    );
  }
  return <BookLoader location={{ source, id: sourceId }} />;
}

function BookLoader({ location: { source, id } }: { location: Pick<BookLocation, "source" | "id"> }) {
  const search = routeApi.useSearch();
  const location: BookLocation = { source, id, metadata: search.metadata };
  const book = useBook(location);
  const session = useSession();
  usePageTitle(book.data?.title ?? (book.isError ? "Book not found" : "Loading book"));

  if (book.isPending) {
    return (
      <section className="book-page" aria-busy="true">
        <BackLink query={search.q} />
        <Loading label="Loading this book…" />
      </section>
    );
  }
  if (book.isError) {
    return (
      <section className="book-page">
        <BackLink query={search.q} />
        {failureKind(book.error) === "not_found" ? (
          <EmptyState title="This book page is not available">
            <p>The address may be incomplete. Search for the book again from Discover.</p>
          </EmptyState>
        ) : (
          <ErrorPanel error={book.error} onRetry={() => void book.refetch()} />
        )}
      </section>
    );
  }
  return <BookView book={book.data} location={location} session={session.data} query={search.q} />;
}

function BackLink({ query }: { query: string | undefined }) {
  const router = useRouter();
  const fromDiscover = query !== undefined;
  const goBack = (event: MouseEvent<HTMLAnchorElement>) => {
    if (!router.history.canGoBack()) return;
    event.preventDefault();
    router.history.back();
  };
  return fromDiscover ? (
    <Link to="/find" search={{ q: query }} className="back-link" onClick={goBack}>
      <span aria-hidden="true">← </span>Find<span className="sr-only">: results for “{query}”</span>
    </Link>
  ) : (
    <Link to="/library" className="back-link" onClick={goBack}>
      <span aria-hidden="true">← </span>Library
    </Link>
  );
}

const FORMAT_NAMES: Record<BookFormat["book_type"], string> = { ebook: "Ebook", audiobook: "Audiobook" };

function panelId(bookType: BookFormat["book_type"]): string {
  return bookType === "ebook" ? "choose-copy" : `choose-copy-${bookType}`;
}

function BookView({ book, location, session, query }: { book: Book; location: BookLocation; session: Session | undefined; query: string | undefined }) {
  const admin = session?.admin !== undefined;
  const title = book.title ?? "Details not available";
  return (
    <article className="book-page" aria-labelledby="book-heading">
      <BackLink query={query} />
      <div className="book-hero">
        <Cover publication={{ title, author: book.author, book_type: "ebook", cover: book.cover }} large />
        <div className="book-title-block">
          {book.year !== null ? <p className="eyebrow">First published {book.year}</p> : null}
          <PageHeading id="book-heading">{title}</PageHeading>
          {book.author ? <p className="book-author-line">{book.author}</p> : null}
          <p className="book-source">
            {book.details === "library" ? "Details from your library · " : "Details from "}
            {book.source.url ? (
              <a href={book.source.url} target="_blank" rel="noopener noreferrer">
                {book.source.name}
                <span className="sr-only"> (opens in a new tab)</span>
              </a>
            ) : (
              book.source.name
            )}
          </p>
          {book.details === "missing" ? (
            <p className="notice" role="note">
              {book.source.name} could not be reached for this book's details. Try again later; nothing was requested.
            </p>
          ) : null}
          {book.description ? <p className="book-blurb">{firstParagraph(book.description)}</p> : null}
        </div>
        <ServerCard book={book} location={location} />
      </div>

      {book.formats.map((format) => (
        <FormatProgress key={format.book_type} format={format} location={location} admin={admin} />
      ))}

      {book.description && book.description !== firstParagraph(book.description) ? (
        <section className="about" aria-labelledby="about-heading">
          <h2 id="about-heading">About this book</h2>
          <p className="description">{book.description}</p>
        </section>
      ) : null}
    </article>
  );
}

function firstParagraph(text: string): string {
  return text.split(/\n\s*\n/)[0] ?? text;
}

function ServerCard({ book, location }: { book: Book; location: BookLocation }) {
  const options = book.request_options ?? FALLBACK_OPTIONS;
  const plan = requestPlan(book.formats, options);
  const request = useRequestBook(location);
  const [pressed, setPressed] = useState<RequestFormat | null>(null);
  const [extras, setExtras] = useState(NO_EXTRAS);
  const [focusTarget, setFocusTarget] = useState<string | null>(null);
  useEffect(() => {
    const target = focusTarget === null ? null : document.getElementById(focusTarget);
    if (!target) return;
    target.focus();
    setFocusTarget(null);
  }, [focusTarget, book]);
  const unavailable = book.title === null;
  const send = (format: RequestFormat) => {
    if (request.isPending || unavailable) return;
    setPressed(format);
    request.mutate(choiceFor(format, extras, options), {
      onSuccess: (answer) => {
        setExtras((current) => ({ ...current, notes: "" }));
        const shown = answer.book.formats.find((entry) => (format === "both" || entry.book_type === format) && entry.state === "requested");
        if (shown) setFocusTarget(panelId(shown.book_type));
      },
    });
  };
  const pressedShown = plan.some((entry) => entry.format === pressed) || (pressed !== "both" && book.formats.some((format) => format.book_type === pressed && offered(format, options)));
  const button = (format: RequestFormat, accent: boolean) => (
    <RequestButton format={format} accent={accent} title={book.title} busy={request.isPending || unavailable} mine={pressed === format} pending={request.isPending} error={request.isError ? request.error : null} onPress={send} />
  );
  return (
    <section className="server-card" aria-labelledby="server-heading">
      <h2 id="server-heading">On this server</h2>
      <ul className="format-rows">
        {book.formats.map((format) => (
          <li key={format.book_type} className="format-row">
            <span className="format-name">{FORMAT_NAMES[format.book_type]}</span>
            <FormatState format={format} />
            <span className="format-action">
              {offered(format, options) ? button(format.book_type, plan.some((entry) => entry.format === format.book_type && entry.accent)) : <FormatAction format={format} />}
            </span>
          </li>
        ))}
      </ul>
      {plan.some((entry) => entry.format === "both") ? <div className="request-both">{button("both", true)}</div> : null}
      {plan.length > 0 ? <RequestExtrasFields options={options} extras={extras} onChange={setExtras} disabled={request.isPending} /> : null}
      {request.isSuccess ? <RejectedFormats results={request.data.results} /> : null}
      {request.isError && !pressedShown ? (
        <p className="field-error" role="alert">
          {actionFailure(request.error, "The request could not be made. Nothing was changed.")}
        </p>
      ) : null}
    </section>
  );
}

function RequestButton({ format, accent, title, busy, mine, pending, error, onPress }: { format: RequestFormat; accent: boolean; title: string | null; busy: boolean; mine: boolean; pending: boolean; error: unknown; onPress: (format: RequestFormat) => void }) {
  const failed = mine && error !== null;
  return (
    <span className="request-format">
      <button type="button" className={accent ? "button button--primary" : "button"} aria-disabled={busy ? true : undefined} onClick={() => onPress(format)}>
        {mine && pending ? "Requesting…" : failed ? "Try requesting again" : requestLabel(format)}
        <span className="sr-only"> of {title ?? "this book"}</span>
      </button>
      {failed ? (
        <span className="field-error" role="alert">
          {actionFailure(error, "The request could not be made. Nothing was changed.")}
        </span>
      ) : null}
    </span>
  );
}

function FormatState({ format }: { format: BookFormat }) {
  const { text, tone } = formatState(format);
  return <span className={`format-state format-state--${tone}`}>{text}</span>;
}

type Tone = "quiet" | "progress" | "attention" | "done";

export function formatState(format: BookFormat): { text: string; tone: Tone } {
  switch (format.state) {
    case "requestable":
      return { text: "Not in library", tone: "quiet" };
    case "requested_by_someone":
      return { text: "Requested by someone here", tone: "progress" };
    case "in_library":
      return format.publication?.availability === "available" ? { text: "In library", tone: "done" } : { text: "In library, can't open here", tone: "attention" };
    case "requested":
      return format.request ? requestState(format.request) : { text: "Requested", tone: "progress" };
  }
}

function requestState(request: BookRequest): { text: string; tone: Tone } {
  if (stalled(request)) return { text: "Needs attention", tone: "attention" };
  switch (request.stage) {
    case "queued":
      return { text: "Requested", tone: "progress" };
    case "searching":
      return request.choice_needed ? { text: "Copies found", tone: "attention" } : { text: "Finding a copy", tone: "progress" };
    case "not_found":
      return { text: "Nothing found yet", tone: "attention" };
    case "awaiting_purchase":
      return { text: "Waiting for a purchase", tone: "attention" };
    case "downloading":
      return { text: request.download_percent === null ? "Getting the file" : `Getting the file · ${request.download_percent}%`, tone: "progress" };
    case "processing":
      return { text: "Adding to library", tone: "progress" };
    case "available":
    case "completed":
      return { text: "In library", tone: "done" };
    case "failed":
      return { text: "Request failed", tone: "attention" };
  }
}

function openLabel(publication: PublicationSummary): string {
  const listening = publication.action === "listen";
  if (publication.reading_status === "finished") return listening ? "Listen again" : "Read again";
  if (publication.progress) {
    const fraction = publication.progress.fraction;
    const verb = listening ? "Continue listening" : "Continue reading";
    return fraction !== null && fraction > 0 ? `${verb} · ${Math.round(fraction * 100)}%` : verb;
  }
  return listening ? "Start listening" : "Start reading";
}

function OpenAction({ format }: { format: BookFormat }) {
  const publication = format.publication;
  if (format.state !== "in_library" || !publication) return null;
  if (publication.availability !== "available") {
    return (
      <Link to="/library/$publicationId" params={{ publicationId: publication.id }} className="button button--subtle">
        Details<span className="sr-only"> of the {FORMAT_NAMES[format.book_type].toLowerCase()} in your library</span>
      </Link>
    );
  }
  return (
    <a className={`button${format.book_type === "ebook" ? " button--primary" : ""}`} href={publication.reader_url}>
      {openLabel(publication)}
      <span className="sr-only"> {publication.title} in the {publication.action === "listen" ? "player" : "reader"}</span>
    </a>
  );
}

function FormatAction({ format }: { format: BookFormat }) {
  if (format.state === "in_library") return <OpenAction format={format} />;
  if (format.state === "requested" && format.request?.copies?.selectable) {
    const reveal = () => {
      const panel = document.getElementById(panelId(format.book_type));
      panel?.scrollIntoView({ block: "start" });
      panel?.focus({ preventScroll: true });
    };
    return (
      <button type="button" className="button" onClick={reveal}>
        Choose a copy
      </button>
    );
  }
  return null;
}


const AUTOMATIC_STEPS = ["Requested", "Finding a copy", "Getting the file", "In library"] as const;
const FALLBACK_STEPS = ["Requested", "Copies found", "Choose a copy", "Getting the file", "In library"] as const;

export type StepState = Pick<BookRequest, "stage" | "choice_needed" | "attention_needed">;

export function requestSteps(request: StepState): { steps: readonly string[]; current: number } {
  if (request.choice_needed) return { steps: FALLBACK_STEPS, current: 2 };
  switch (request.stage) {
    case "queued":
    case "searching":
    case "not_found":
    case "awaiting_purchase":
    case "failed":
      return { steps: AUTOMATIC_STEPS, current: 1 };
    case "downloading":
      return { steps: AUTOMATIC_STEPS, current: 2 };
    case "processing":
    case "available":
    case "completed":
      return { steps: AUTOMATIC_STEPS, current: 3 };
  }
}

export function RequestSteps({ request, label = "Ebook request progress" }: { request: StepState; label?: string }) {
  if (request.stage === "available" || request.stage === "completed") return null;
  const { steps, current } = requestSteps(request);
  const stuck = stalled(request) || request.stage === "not_found" || request.stage === "awaiting_purchase" || request.stage === "failed";
  return (
    <section className="request-steps" aria-label={label}>
      <p className="request-steps-summary">
        Step {current + 1} of {steps.length} · {steps[current]}
      </p>
      <ol>
        {steps.map((step, index) => (
          <li key={step} className={index < current ? "step step--done" : index === current ? `step step--current${stuck ? " step--stuck" : ""}` : "step"} aria-current={index === current ? "step" : undefined}>
            <span className="step-mark" aria-hidden="true">
              {index < current ? "✓" : ""}
            </span>
            {step}
            {index < current ? <span className="sr-only"> (done)</span> : null}
          </li>
        ))}
      </ol>
    </section>
  );
}

function FormatProgress({ format, location, admin }: { format: BookFormat; location: BookLocation; admin: boolean }) {
  const request = format.state === "requested" ? format.request : null;
  return (
    <>
      {request ? <RequestSteps request={request} label={`${FORMAT_NAMES[format.book_type]} request progress`} /> : null}
      <FormatPanel format={format} location={location} admin={admin} />
    </>
  );
}

function FormatPanel({ format, location, admin }: { format: BookFormat; location: BookLocation; admin: boolean }) {
  const headingId = format.book_type === "ebook" ? "copy-panel-heading" : `copy-panel-heading-${format.book_type}`;
  const noun = format.book_type;
  if (format.state === "in_library" && format.publication && format.book_type === "ebook") return <OpenPanel publication={format.publication} />;
  if (format.state === "requested_by_someone") {
    return (
      <section className="copy-panel" aria-labelledby={headingId}>
        <h2 id={headingId}>{format.book_type === "ebook" ? "Already requested" : `${FORMAT_NAMES[format.book_type]} already requested`}</h2>
        <p>Someone on this server has already requested this {noun}. Once it arrives it will be in the library for everyone here.</p>
      </section>
    );
  }
  const request = format.state === "requested" ? format.request : null;
  if (!request) return null;
  return <RequestPanel request={request} location={location} admin={admin} bookType={format.book_type} headingId={headingId} />;
}

function OpenPanel({ publication }: { publication: PublicationSummary }) {
  return (
    <section className="copy-panel" aria-labelledby="copy-panel-heading">
      <h2 id="copy-panel-heading">Open it</h2>
      <ul className="open-list">
        <li>
          <span>This browser</span>
          {publication.availability === "available" ? (
            <a href={publication.reader_url}>
              {openLabel(publication)}
              <span className="sr-only"> {publication.title} in the reader</span>
            </a>
          ) : (
            <span>This ebook is in the library, but there is no file this browser can open right now. Your saved place is kept.</span>
          )}
        </li>
        <li>
          <span>Library</span>
          <Link to="/library/$publicationId" params={{ publicationId: publication.id }}>
            Reading status and files<span className="sr-only"> of {publication.title}</span>
          </Link>
        </li>
      </ul>
    </section>
  );
}

export function stalled(request: Pick<BookRequest, "attention_needed" | "choice_needed">): boolean {
  return request.attention_needed && !request.choice_needed;
}

export function stageSentence(request: Pick<BookRequest, "stage" | "choice_needed" | "attention_needed" | "download_percent">, admin: boolean, noun = "ebook"): string {
  if (stalled(request)) {
    return admin
      ? "Shelfarr stopped working on this request until someone looks at it."
      : "Shelfarr stopped working on this request until an administrator looks at it. This page updates when it moves again.";
  }
  switch (request.stage) {
    case "queued":
      return "Requested. Shelfarr will search for copies shortly.";
    case "searching":
      if (!request.choice_needed) return "Looking for a suitable copy. Shelfarr downloads it and adds it to the library by itself; this page updates as it goes.";
      return admin
        ? "Copies were found, but none was picked automatically. Choose one to download."
        : `Copies were found, but none was picked automatically. An administrator can choose one; this page updates when the ${noun} is in the library.`;
    case "not_found":
      return "No suitable copy has been found yet.";
    case "awaiting_purchase":
      return "Waiting for a purchase. The request details show where to buy it.";
    case "downloading":
      return request.download_percent === null ? "Getting the file. Progress is not known yet." : `Getting the file: ${request.download_percent}% so far.`;
    case "processing":
      return "The download finished and is being added to the library.";
    case "available":
    case "completed":
      return "Completed.";
    case "failed":
      return "This request failed and is no longer being worked on.";
  }
}

function RequestPanel({ request, location, admin, bookType, headingId }: { request: BookRequest; location: BookLocation; admin: boolean; bookType: BookFormat["book_type"]; headingId: string }) {
  const copies = request.copies;
  const choosing = admin && copies?.selectable === true;
  const retrying = request.stage === "not_found" && request.next_retry_at !== null && Date.parse(request.next_retry_at) > Date.now();
  const ebook = bookType === "ebook";
  return (
    <section className="copy-panel" id={panelId(bookType)} aria-labelledby={headingId} tabIndex={-1}>
      <h2 id={headingId}>{choosing ? (ebook ? "Choose a copy" : `Choose a copy of the ${bookType}`) : `${FORMAT_NAMES[bookType]} request`}</h2>
      <div role="status" className="request-stage">
        <p>
          {stageSentence(request, admin, bookType)}
          {retrying && request.next_retry_at ? (
            <>
              {" "}
              Shelfarr searches again <Time iso={request.next_retry_at} relative />.
            </>
          ) : null}
        </p>
        {request.stage === "downloading" && !stalled(request) ? request.download_percent === null ? <progress aria-label="Download progress" /> : <progress max={100} value={request.download_percent} aria-label="Download progress" /> : null}
      </div>
      {admin && request.requested_by !== undefined ? <p className="request-meta">Requested by {request.own ? "you" : request.requested_by || "an account without a name"}</p> : null}
      {admin && request.issue ? <p className="request-meta">{request.issue}</p> : null}
      {choosing && copies ? <BookCopies requestId={request.id} copies={copies.candidates} location={location} /> : null}
      <RequestActions request={request} location={location} admin={admin} />
    </section>
  );
}

function RequestActions({ request, location, admin }: { request: BookRequest; location: BookLocation; admin: boolean }) {
  const searchAgain = useSearchAgain(location, request.id);
  const canSearch = admin && request.copies?.can_search_again === true;
  const canCancel = request.own && request.can_cancel;
  return (
    <div className="copy-actions">
      {canSearch ? (
        <button type="button" className="button button--subtle" aria-disabled={searchAgain.isPending ? true : undefined} onClick={() => (searchAgain.isPending ? undefined : searchAgain.mutate(undefined))}>
          {searchAgain.isPending ? "Searching…" : "Search again"}
        </button>
      ) : null}
      <Link to="/requests/$requestId" params={{ requestId: request.id }} className="button button--subtle">
        {admin ? "Request details and tools" : "Request details"}
      </Link>
      {canCancel ? <CancelRequest request={request} location={location} /> : null}
      {searchAgain.isError ? (
        <p className="field-error" role="alert">
          {actionFailure(searchAgain.error, "The search could not be started. Nothing was changed.")}
        </p>
      ) : null}
    </div>
  );
}

function CancelRequest({ request, location }: { request: BookRequest; location: BookLocation }) {
  const cancel = useCancelRequest(location, request.id);
  const [asking, setAsking] = useState(false);
  const confirm = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    if (asking) confirm.current?.focus();
  }, [asking]);
  if (!asking) {
    return (
      <button type="button" className="button button--subtle" onClick={() => setAsking(true)}>
        Cancel request
      </button>
    );
  }
  return (
    <span className="cancel-confirm" role="group" aria-label="Cancel this request?">
      <span>Cancel this request?</span>
      <button ref={confirm} type="button" className="button button--danger" aria-disabled={cancel.isPending ? true : undefined} onClick={() => (cancel.isPending ? undefined : cancel.mutate(undefined))}>
        {cancel.isPending ? "Cancelling…" : "Yes, cancel it"}
      </button>
      <button type="button" className="button button--subtle" onClick={() => setAsking(false)}>
        Keep it
      </button>
      {cancel.isError ? (
        <span className="field-error" role="alert">
          {actionFailure(cancel.error, "The request could not be cancelled. Nothing was changed.")}
        </span>
      ) : null}
    </span>
  );
}

function BookCopies({ requestId, copies, location }: { requestId: string; copies: BookCopy[]; location: BookLocation }) {
  const choose = useChooseCopy(location, requestId);
  return <CopyTable copies={copies} choose={choose} />;
}
