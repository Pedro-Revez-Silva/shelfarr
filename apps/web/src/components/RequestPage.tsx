import { getRouteApi, Link, useRouter } from "@tanstack/react-router";
import { failureKind } from "../api/errors";
import type { RequestDetail } from "../contract";
import { scopeChanged, useRequest, useSession } from "../queries";
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
  const rechecking = scopeChanged(request.failureReason) && !request.isError;
  usePageTitle(request.isError ? "Request not found" : rechecking ? "Loading request" : (request.data?.title ?? "Loading request"));

  if (session.isError && !session.data) {
    return (
      <section className="request-details">
        <BackToRequests />
        <ErrorPanel error={session.error} onRetry={() => void session.refetch()} />
      </section>
    );
  }

  if (request.isPending || rechecking) {
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

  return <Details request={request.data} />;
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

function stage(request: RequestDetail): string {
  switch (request.status) {
    case "pending":
      return "Waiting for its turn to be searched.";
    case "searching":
      return "Searching indexers for this book. This may take a moment.";
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

function Details({ request }: { request: RequestDetail }) {
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
            </div>
          ) : null}

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
