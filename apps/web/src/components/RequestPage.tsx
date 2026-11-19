import { getRouteApi, Link, useRouter } from "@tanstack/react-router";
import { useEffect, useId, useRef, useState, type FormEvent } from "react";
import { ApiError, failureKind, unconfirmed } from "../api/errors";
import type { Acquisition, RequestDetail } from "../contract";
import { selectionRunning, useAcquisition, useRequest, useSelectionFinished, useSelectResult, useSession } from "../queries";
import { useServices } from "../services";
import { usePageTitle } from "../title";
import { Cover } from "./Cover";
import { PageHeading } from "./PageHeading";
import { BOOK_TYPE_LABELS, coverOf, DOWNLOAD_LABELS, relativeTime, StatusBadges, Time } from "./requestText";
import { EmptyState, ErrorPanel, Loading } from "./States";

const routeApi = getRouteApi("/requests/$requestId");

export function RequestPage() {
  const { mode } = useServices();
  if (mode !== "go") {
    return (
      <EmptyState title="That page is not part of this preview">
        <p>Use the navigation to return to your library.</p>
      </EmptyState>
    );
  }
  return <RequestView />;
}

function RequestView() {
  const { requestId } = routeApi.useParams();
  const request = useRequest(requestId);
  const session = useSession();
  usePageTitle(request.isError ? (failureKind(request.error) === "not_found" ? "Request not found" : "Request") : (request.data?.title ?? "Loading request"));

  if (session.isError && !session.data) {
    return (
      <section className="request-details">
        <BackToRequests />
        <ErrorPanel error={session.error} onRetry={() => void session.refetch()} />
      </section>
    );
  }

  if (request.isPending) {
    return (
      <section className="request-details" aria-busy="true">
        <BackToRequests />
        <Loading label="Loading this request…" />
      </section>
    );
  }

  if (request.isError) {
    const missing = failureKind(request.error) === "not_found";
    return (
      <section className="request-details">
        <BackToRequests />
        {missing ? (
          <div className="state state--empty" role="alert">
            <h1>This request is not available</h1>
            <p>It may have been removed, or it is not one this account can see.</p>
            <div className="state-actions">
              <Link to="/requests" className="button button--primary">
                View All Requests
              </Link>
            </div>
          </div>
        ) : (
          <ErrorPanel error={request.error} onRetry={() => void request.refetch()} />
        )}
      </section>
    );
  }

  return <Details request={request.data} admin={session.data?.admin !== undefined} />;
}

function BackToRequests() {
  const router = useRouter();
  if (router.history.canGoBack()) {
    return (
      <button type="button" className="back-link" onClick={() => router.history.back()}>
        <span aria-hidden="true">← </span>Back to Requests
      </button>
    );
  }
  return (
    <Link to="/requests" className="back-link">
      <span aria-hidden="true">← </span>Back to Requests
    </Link>
  );
}

const SELECTION_REASON = "Search results found. Please review and select a result to download.";

function stage(request: RequestDetail): string {
  switch (request.status) {
    case "pending":
      return "Waiting for its turn to be searched.";
    case "searching":
      return request.acquisition === true && request.attention_reason === SELECTION_REASON ? "Copies were found and are waiting for a choice." : "Searching indexers for this book. This may take a moment.";
    case "not_found":
      return request.next_retry_at && Date.parse(request.next_retry_at) > Date.now() ? `Nothing suitable was found yet. Shelfarr will search again ${relativeTime(request.next_retry_at)}.` : "Nothing suitable was found yet.";
    case "downloading":
      return request.download_percent === null ? "Downloading. Progress is not known yet." : `Downloading: ${request.download_percent}% so far.`;
    case "processing":
      return "The download finished and is being added to the library.";
    case "completed":
      return request.library?.state === "available" ? "Completed and in the library." : request.library?.state === "unavailable" ? "Completed. A copy is recorded, but the Library here cannot open it right now." : "Completed.";
    case "failed":
      return "This request was cancelled or failed and is no longer being worked on.";
    case "awaiting_purchase":
      return "Waiting for a purchase. Store offers are not shown in this preview.";
    case "unknown":
      return "The server reported a status this preview does not know yet.";
  }
}

function Details({ request, admin }: { request: RequestDetail; admin: boolean }) {
  const library = request.library;
  return (
    <article className="request-details" aria-labelledby="request-heading">
      <BackToRequests />
      <div className="details-layout">
        <Cover publication={coverOf(request)} large />
        <div className="details-main">
          <p className="eyebrow">{BOOK_TYPE_LABELS[request.book_type]} request</p>
          <PageHeading id="request-heading">{request.title}</PageHeading>
          {request.author ? <p className="details-author">{request.author}</p> : null}
          <StatusBadges request={request} />

          {request.attention_needed ? (
            <div className="attention" role="note">
              <h2>Attention Required</h2>
              <p>{request.attention_reason ?? "This request needs your attention."}</p>
              {!admin && request.acquisition === true && request.attention_reason === SELECTION_REASON ? <p>An administrator chooses which copy to download.</p> : null}
            </div>
          ) : null}

          {admin && request.acquisition === true ? <ChooseCopy request={request} /> : null}

          <div className="request-stage" role="status">
            <p>{stage(request)}</p>
            {request.status === "downloading" && request.download_percent !== null ? <progress max={100} value={request.download_percent} aria-label="Download progress" /> : null}
          </div>

          {library?.state === "available" ? (
            <Link to="/library/$publicationId" params={{ publicationId: library.publication_id }} className="button button--primary request-open">
              Open in Library
            </Link>
          ) : library?.state === "unavailable" && request.status !== "completed" ? (
            <p className="notice" role="note">
              A copy is recorded for this book, but the Library here cannot open it right now.
            </p>
          ) : null}

          <dl className="request-facts">
            {request.requested_by ? (
              <div>
                <dt>Requested by</dt>
                <dd>{request.requested_by.self ? "You" : request.requested_by.name || "An account without a name"}</dd>
              </div>
            ) : null}
            <div>
              <dt>Requested</dt>
              <dd>
                <Time iso={request.created_at} />
              </dd>
            </div>
            {request.completed_at ? (
              <div>
                <dt>Completed</dt>
                <dd>
                  <Time iso={request.completed_at} />
                </dd>
              </div>
            ) : null}
            {request.next_retry_at && Date.parse(request.next_retry_at) > Date.now() ? (
              <div>
                <dt>Next retry</dt>
                <dd>
                  <Time iso={request.next_retry_at} relative />
                </dd>
              </div>
            ) : null}
          </dl>
        </div>
      </div>

      {request.downloads.length > 0 ? (
        <section className="request-downloads" aria-labelledby="downloads-heading">
          <h2 id="downloads-heading">Downloads</h2>
          <p className="request-note">Newest first. Release names and download clients are not shown here.</p>
          <ol>
            {request.downloads.map((download, index) => (
              <li key={index}>
                <span className={`badge badge--download badge--${download.status}`}>{DOWNLOAD_LABELS[download.status]}</span>
                {download.progress !== null ? <span>{download.progress}%</span> : null}
              </li>
            ))}
          </ol>
        </section>
      ) : null}
    </article>
  );
}

const SEARCH_NOTES: Record<NonNullable<Acquisition["search"]>["state"], string> = {
  retry_scheduled: "The last search could not reach the catalogue, so Shelfarr will search again",
  waiting: "Another search for this request was still running, so Shelfarr will look again",
  refused: "This server's settings do not allow searching for this request here. Shelfarr will check again",
};

const FAILURE_TEXT: Record<string, string> = {
  "provider-refused": "The catalogue refused the download.",
  "provider-busy": "The catalogue was busy.",
  "provider-unreachable": "The catalogue could not be reached.",
  "provider-timeout": "The catalogue took too long to answer.",
  "provider-too-large": "The file was larger than this server accepts.",
  "download-not-a-book": "The catalogue sent something that is not an ebook.",
  "download-invalid": "The file was not a readable EPUB.",
  "download-truncated": "The download stopped before the whole file arrived.",
  "download-deadline": "The download took too long.",
  "library-file-exists": "A different file is already in the library at this book's place.",
  cancelled: "The server was stopped during the download.",
  superseded: "The request changed while the copy was downloading.",
  authority_changed: "Your account was no longer allowed to choose a copy when the download was due to start.",
  acquisition_busy: "Another download was running on this server.",
};

function ChooseCopy({ request }: { request: RequestDetail }) {
  const acquisition = useAcquisition(request.id, true);
  const finished = useSelectionFinished(request.id);
  const state = acquisition.data?.selection?.state;
  const previous = useRef(state);
  useEffect(() => {
    if (previous.current !== state && (state === "completed" || state === "failed")) finished();
    previous.current = state;
  }, [state, finished]);

  if (acquisition.isPending) return null;
  if (acquisition.isError) {
    if (failureKind(acquisition.error) === "not_found") return null;
    return (
      <section className="choose-copy" aria-labelledby="choose-copy-heading">
        <h2 id="choose-copy-heading">Choose a copy</h2>
        <ErrorPanel error={acquisition.error} onRetry={() => void acquisition.refetch()} />
      </section>
    );
  }
  const answer = acquisition.data;
  if (answer.search && request.status === "pending") {
    return (
      <p className="notice" role="note">
        {SEARCH_NOTES[answer.search.state]} <Time iso={answer.search.retry_at} relative />.
      </p>
    );
  }
  if (request.status === "completed" || (answer.selection === null && (answer.candidates.length === 0 || request.status !== "searching"))) return null;
  return (
    <section className="choose-copy" aria-labelledby="choose-copy-heading">
      <h2 id="choose-copy-heading">Choose a copy</h2>
      <SelectionStatus answer={answer} />
      {request.status === "searching" && answer.candidates.length > 0 && !selectionRunning(answer) ? <CopyForm request={request} answer={answer} /> : null}
    </section>
  );
}

function SelectionStatus({ answer }: { answer: Acquisition }) {
  const selection = answer.selection;
  let text = "";
  if (selection?.state === "queued") text = "Download queued. It starts as soon as the server finishes its current search. If the server restarts first, choose the copy again.";
  else if (selection?.state === "downloading") text = "Downloading the chosen copy. This page updates by itself.";
  else if (selection?.state === "completed") text = "Downloaded. The ebook is now in the library.";
  else if (selection?.state === "failed")
    text = `The download did not finish. ${FAILURE_TEXT[selection.code ?? ""] ?? "The server could not confirm it."} Nothing was added to the library${answer.candidates.length > 0 ? "; you can choose a copy again." : "."}`;
  return (
    <div className="request-stage" role="status">
      {text ? <p>{text}</p> : null}
      {selectionRunning(answer) ? <progress aria-label="Download in progress" /> : null}
    </div>
  );
}

function CopyForm({ request, answer }: { request: RequestDetail; answer: Acquisition }) {
  const select = useSelectResult(request.id);
  const [chosen, setChosen] = useState(answer.candidates.length === 1 ? (answer.candidates[0]?.id ?? "") : "");
  const [missing, setMissing] = useState(false);
  const firstCopy = useRef<HTMLInputElement>(null);
  const errorId = useId();
  const legendId = useId();
  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (select.isPending) return;
    if (!answer.candidates.some((candidate) => candidate.id === chosen)) {
      setMissing(true);
      firstCopy.current?.focus();
      return;
    }
    setMissing(false);
    select.mutate(chosen);
  };
  return (
    <form className="copy-form" onSubmit={submit} noValidate aria-labelledby={legendId}>
      <fieldset aria-describedby={missing ? errorId : undefined}>
        <legend id={legendId}>Copies found in the Project Gutenberg catalogue</legend>
        {answer.candidates.map((candidate, index) => (
          <div className="copy-option" key={candidate.id}>
            <input
              ref={index === 0 ? firstCopy : undefined}
              type="radio"
              id={`copy-${candidate.id}`}
              name="copy"
              value={candidate.id}
              checked={chosen === candidate.id}
              onChange={() => {
                setChosen(candidate.id);
                setMissing(false);
              }}
            />
            <label htmlFor={`copy-${candidate.id}`}>{candidate.title}</label>
          </div>
        ))}
      </fieldset>
      {missing ? (
        <p id={errorId} className="field-error">
          <span aria-hidden="true">⚠ </span>Choose one copy first.
        </p>
      ) : null}
      <div className="form-actions">
        <button type="submit" className="button button--primary" aria-disabled={select.isPending ? true : undefined}>
          {select.isPending ? "Sending…" : "Download this copy"}
        </button>
      </div>
      {select.isError ? <SelectionFailure error={select.error} /> : null}
    </form>
  );
}

function SelectionFailure({ error }: { error: unknown }) {
  const code = error instanceof ApiError ? error.code : null;
  const kind = failureKind(error);
  let text = "The choice could not be sent. Nothing was changed.";
  if (code === "acquisition_busy") text = "Another download is running on this server. Try again when it has finished.";
  else if (code === "not_selectable") text = "That copy can no longer be chosen. The list shows what can be chosen now.";
  else if (unconfirmed(error)) text = "The server did not confirm the choice. This page shows the current state; choose again only if nothing is downloading.";
  else if (kind === "csrf") text = "The page's security check expired. Try again.";
  return (
    <p className="field-error" role="alert">
      {text}
    </p>
  );
}
