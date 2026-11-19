import { getRouteApi, Link, useNavigate } from "@tanstack/react-router";
import { useId, useState, type FormEvent } from "react";
import { MAX_REQUEST_QUERY, type RequestFilters, type RequestList, type RequestSummary } from "../contract";
import { useRequests, useSession } from "../queries";
import { useServices } from "../services";
import { usePageTitle } from "../title";
import { Cover } from "./Cover";
import { PageHeading } from "./PageHeading";
import { coverOf, StatusBadges, Time } from "./requestText";
import { EmptyState, ErrorPanel, Loading } from "./States";

const routeApi = getRouteApi("/requests");

type FilterKey = "all" | "attention" | "active" | "awaiting_purchase" | "completed" | "not_found" | "failed";

const FILTERS: { key: FilterKey; label: string; count?: "attention" | "active" }[] = [
  { key: "all", label: "All" },
  { key: "attention", label: "Need Attention", count: "attention" },
  { key: "active", label: "Active", count: "active" },
  { key: "awaiting_purchase", label: "Store Offers" },
  { key: "completed", label: "Completed" },
  { key: "not_found", label: "Not Found" },
  { key: "failed", label: "Cancelled" },
];

export function trimQuery(raw: string | undefined): string | undefined {
  const trimmed = (raw ?? "").replace(/^[ \t\n\v\f\r\0]+|[ \t\n\v\f\r\0]+$/g, "");
  if (trimmed === "") return undefined;
  return [...trimmed].slice(0, MAX_REQUEST_QUERY).join("");
}

function currentFilter(filters: RequestFilters): string {
  if (filters.attention === "true") return "attention";
  return filters.status ?? "all";
}

function keep(filters: RequestFilters, changes: { q?: string | undefined; page?: number }): RequestFilters {
  const next: RequestFilters = {};
  if (filters.status) next.status = filters.status;
  if (filters.attention) next.attention = filters.attention;
  const q = "q" in changes ? changes.q : filters.q;
  if (q) next.q = q;
  if (changes.page && changes.page > 1) next.page = String(changes.page);
  return next;
}

function searchFor(key: FilterKey, q: string | undefined): RequestFilters {
  const next: RequestFilters = {};
  if (q) next.q = q;
  if (key === "attention") next.attention = "true";
  else if (key !== "all") next.status = key;
  return next;
}

export function RequestsPage() {
  const { mode } = useServices();
  if (mode !== "go") {
    return (
      <EmptyState title="That page is not part of this preview">
        <p>Use the navigation to return to your library.</p>
      </EmptyState>
    );
  }
  return <Requests />;
}

function Requests() {
  const raw = routeApi.useSearch();
  const filters: RequestFilters = { ...raw };
  const q = trimQuery(raw.q);
  if (q) filters.q = q;
  else delete filters.q;
  const navigate = useNavigate();
  const session = useSession();
  const list = useRequests(filters);
  const everyone = list.data ? list.data.scope === "all" : Boolean(session.data?.admin);
  const heading = everyone ? "All Requests" : "My Requests";
  usePageTitle(q ? `Requests: ${q}` : heading);
  const key = currentFilter(filters);

  const search = (text: string | undefined) => {
    void navigate({ to: "/requests", search: keep(filters, { q: text }) });
  };

  return (
    <section className="requests" aria-labelledby="requests-heading">
      <header className="page-heading">
        <p className="eyebrow">Requests</p>
        <PageHeading id="requests-heading">{heading}</PageHeading>
        <p className="lede">
          {everyone ? "Every request on this server" : "The books and audiobooks you asked this server for"}, and where each one has got to. Making, cancelling or retrying requests is not part of this preview yet.
        </p>
      </header>

      <nav className="request-filters" aria-label="Request filters">
        <ul>
          {FILTERS.map((filter) => {
            const count = filter.count && list.data ? list.data.counts[filter.count] : 0;
            return (
              <li key={filter.key}>
                <Link
                  to="/requests"
                  search={searchFor(filter.key, q)}
                  className={`filter-link${filter.key === "attention" && count > 0 ? " filter-link--alert" : ""}`}
                  aria-current={filter.key === key ? "page" : undefined}
                  activeOptions={{ exact: true, includeSearch: true }}
                  activeProps={{}}
                >
                  {filter.label}
                  {count > 0 ? <> <span className="filter-count">{count}</span></> : null}
                </Link>
              </li>
            );
          })}
        </ul>
      </nav>

      <RequestSearch key={q ?? ""} query={q} onSearch={search} />

      <ListStatus list={list.data} pending={list.isPending} failed={list.isError} />

      {list.isPending ? <Loading label="Loading requests…" /> : null}
      {list.isError ? <ErrorPanel error={list.error} onRetry={() => void list.refetch()} /> : null}
      {list.data && !list.isError ? <Results list={list.data} filters={filters} filter={key} /> : null}
    </section>
  );
}

function RequestSearch({ query, onSearch }: { query: string | undefined; onSearch: (text: string | undefined) => void }) {
  const [text, setText] = useState(query ?? "");
  const inputId = useId();
  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    onSearch(trimQuery(text));
  };
  return (
    <search className="request-search">
      <form className="search" onSubmit={submit}>
        <label htmlFor={inputId}>Search requests by title or author</label>
        <div className="search-row">
          <input
            id={inputId}
            type="search"
            name="q"
            value={text}
            maxLength={MAX_REQUEST_QUERY}
            enterKeyHint="search"
            autoComplete="off"
            autoCorrect="off"
            autoCapitalize="none"
            spellCheck={false}
            onChange={(event) => setText(event.target.value)}
          />
          <button type="submit" className="button">
            Search
          </button>
          {query ? (
            <button type="button" className="button button--subtle" onClick={() => onSearch(undefined)}>
              Clear
            </button>
          ) : null}
        </div>
      </form>
    </search>
  );
}

function ListStatus({ list, pending, failed }: { list: RequestList | undefined; pending: boolean; failed: boolean }) {
  let text = "";
  if (pending) text = "Loading requests…";
  else if (failed) text = "The requests could not be loaded.";
  else if (list) text = `${list.total} ${list.total === 1 ? "request" : "requests"}${list.total_pages > 1 ? ` · Page ${list.page} of ${list.total_pages}` : ""}`;
  return (
    <p className="result-count" role="status">
      {text}
    </p>
  );
}

function Results({ list, filters, filter }: { list: RequestList; filters: RequestFilters; filter: string }) {
  if (list.items.length === 0) return <Empty filters={filters} filter={filter} />;
  const others = (page: number) => keep(filters, { page });
  return (
    <section className="request-results" aria-labelledby="request-results-heading">
      <h2 id="request-results-heading" className="sr-only">
        Requests on this page
      </h2>
      <ol className="request-list">
        {list.items.map((request) => (
          <li key={request.id}>
            <RequestCard request={request} />
          </li>
        ))}
      </ol>
      {list.total_pages > 1 ? (
        <nav className="pagination" aria-label="Request pages">
          <p>
            {list.total} {list.total === 1 ? "request" : "requests"} · Page {list.page} of {list.total_pages}
          </p>
          <div className="pagination-links">
            {list.page > 1 ? (
              <Link to="/requests" search={others(list.page - 1)} className="button" rel="prev">
                Previous<span className="sr-only"> page</span>
              </Link>
            ) : null}
            {list.page < list.total_pages ? (
              <Link to="/requests" search={others(list.page + 1)} className="button" rel="next">
                Next<span className="sr-only"> page</span>
              </Link>
            ) : null}
          </div>
        </nav>
      ) : null}
    </section>
  );
}

function Empty({ filters, filter }: { filters: RequestFilters; filter: string }) {
  if (!filters.q && filter === "all") {
    return (
      <EmptyState title="No requests yet">
        <p>Search for books and request them to add to your library. Requesting is not part of this preview yet; Discover shows what is already in the library.</p>
        <Link to="/discover" className="button">
          Discover books
        </Link>
      </EmptyState>
    );
  }
  const title = filters.q ? "No matching requests" : filter === "attention" ? "No requests need attention" : "No matching requests";
  const body = filters.q ? `No requests match “${filters.q}”.` : filter === "attention" ? "All requests are processing normally." : "No requests match your current filter.";
  return (
    <EmptyState title={title}>
      <p>{body}</p>
      <Link to="/requests" search={{}} className="button">
        View All Requests
      </Link>
    </EmptyState>
  );
}

function RequestCard({ request }: { request: RequestSummary }) {
  const titleId = useId();
  const available = request.library?.state === "available" ? request.library.publication_id : null;
  return (
    <article className="request-card" aria-labelledby={titleId}>
      <Cover publication={coverOf(request)} />
      <div className="request-copy">
        <h3 id={titleId}>
          <Link to="/requests/$requestId" params={{ requestId: request.id }} className="request-link">
            {request.title}
          </Link>
        </h3>
        {request.author ? <p className="book-author">{request.author}</p> : null}
        <StatusBadges request={request} />
        {request.status === "downloading" && request.download_percent !== null ? (
          <p className="request-progress">
            <progress max={100} value={request.download_percent} aria-label={`Download progress for ${request.title}`} />
            <span>{request.download_percent}%</span>
          </p>
        ) : null}
        <p className="request-meta">
          {request.requested_by && !request.requested_by.self ? <span>Requested by {request.requested_by.name || "an account without a name"}</span> : null}
          <span>
            Requested <Time iso={request.created_at} relative />
          </span>
          {request.completed_at ? (
            <span>
              Completed <Time iso={request.completed_at} relative />
            </span>
          ) : null}
        </p>
        {available ? (
          <Link to="/library/$publicationId" params={{ publicationId: available }} className="button button--subtle request-open">
            Open in Library<span className="sr-only"> for {request.title}</span>
          </Link>
        ) : null}
      </div>
    </article>
  );
}
