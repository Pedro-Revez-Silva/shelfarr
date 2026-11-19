import { getRouteApi, Link, useNavigate } from "@tanstack/react-router";
import { useEffect, useId, useRef, useState, type FormEvent, type ReactNode } from "react";
import { ApiError, failureKind, unconfirmed } from "../api/errors";
import { coverStyles, type DiscoverAnswer, type DiscoverItem, type DiscoverState, type LibraryCopyType, type RequestCreation } from "../contract";
import { useDiscover, useRequestEbook } from "../queries";
import { useServices } from "../services";
import { usePageTitle } from "../title";
import { Cover } from "./Cover";
import { PageHeading } from "./PageHeading";
import { EmptyState, ErrorPanel, Loading } from "./States";

const routeApi = getRouteApi("/discover");

export const MAX_QUERY_CHARACTERS = 200;
const OPEN_LIBRARY = "https://openlibrary.org";

export type CheckedQuery = { kind: "none" } | { kind: "ready"; query: string } | { kind: "too_long" } | { kind: "invalid" };

export function checkQuery(raw: string | undefined): CheckedQuery {
  const query = (raw ?? "").trim();
  if (query === "") return { kind: "none" };
  if ([...query].length > MAX_QUERY_CHARACTERS) return { kind: "too_long" };
  if (/\p{Cc}/u.test(query)) return { kind: "invalid" };
  return { kind: "ready", query };
}

export function DiscoverPage() {
  const { mode } = useServices();
  if (mode !== "go") {
    return (
      <EmptyState title="That page is not part of this preview">
        <p>Use the navigation to return to your library.</p>
      </EmptyState>
    );
  }
  return <Discover />;
}

function Discover() {
  const { q } = routeApi.useSearch();
  const navigate = useNavigate();
  const checked = checkQuery(q);
  const query = checked.kind === "ready" ? checked.query : null;
  usePageTitle(query ? `Discover: ${query}` : "Discover");
  const answer = useDiscover(query);
  const state = answer.isError ? null : (answer.data?.search ?? null);
  const searchable = state === null || state === "available";

  const submit = (text: string) => {
    void navigate({ to: "/discover", search: { q: text } });
  };

  return (
    <section className="discover" aria-labelledby="discover-heading">
      <header className="page-heading">
        <p className="eyebrow">Find books</p>
        <PageHeading id="discover-heading">Discover</PageHeading>
        <p className="lede">
          Search <a href={OPEN_LIBRARY} target="_blank" rel="noopener noreferrer">Open Library<span className="sr-only"> (opens in a new tab)</span></a>, the free catalogue
          run by the Internet Archive, by title or author, and see what is already in your library.
        </p>
      </header>

      {searchable ? (
        <SearchForm source={q ?? ""} initial={checked.kind === "ready" ? checked.query : (q ?? "")} problem={checked.kind === "too_long" || checked.kind === "invalid" ? checked.kind : null} onSearch={submit} />
      ) : null}

      <SearchStatus query={query} answer={answer.data} pending={query !== null && answer.isFetching} failed={answer.isError} />

      {state !== null && state !== "available" ? <Unavailable state={state} retryAfter={answer.data?.retry_after ?? null} checking={answer.isFetching} onCheck={() => void answer.refetch()} /> : null}
      {answer.isError ? <SearchFailure error={answer.error} query={query} onRetry={() => void answer.refetch()} /> : null}
      {query === null && answer.isPending ? <Loading label="Checking whether search is available…" /> : null}
      {answer.data && answer.data.search === "available" && answer.data.query !== null && !answer.isError ? <Results answer={answer.data} onRefresh={() => void answer.refetch()} refreshing={answer.isFetching} /> : null}
    </section>
  );
}

function SearchForm({ source, initial, problem, onSearch }: { source: string; initial: string; problem: "too_long" | "invalid" | null; onSearch: (query: string) => void }) {
  const [text, setText] = useState(initial);
  const [shown, setShown] = useState(source);
  const [blank, setBlank] = useState(false);
  if (shown !== source) {
    setShown(source);
    setText(initial);
    setBlank(false);
  }
  const inputId = useId();
  const hintId = useId();
  const errorId = useId();
  const message = blank ? "Type a title or an author first." : problem === "too_long" ? `Use ${MAX_QUERY_CHARACTERS} characters or fewer.` : problem === "invalid" ? "Use letters, numbers and punctuation only." : null;

  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const trimmed = text.trim();
    if (trimmed === "") {
      setBlank(true);
      return;
    }
    setBlank(false);
    onSearch(trimmed);
  };

  return (
    <search className="discover-search">
      <form className="search" onSubmit={submit} noValidate>
        <label htmlFor={inputId}>Title or author</label>
        <p id={hintId} className="field-hint">
          What you type is sent to Open Library when you press Search.
        </p>
        <div className="search-row">
          <input
            id={inputId}
            type="search"
            name="q"
            value={text}
            maxLength={MAX_QUERY_CHARACTERS}
            enterKeyHint="search"
            autoComplete="off"
            autoCorrect="off"
            autoCapitalize="none"
            spellCheck={false}
            aria-describedby={message ? `${hintId} ${errorId}` : hintId}
            aria-invalid={message ? true : undefined}
            onChange={(event) => {
              setText(event.target.value);
              if (blank) setBlank(false);
            }}
          />
          <button type="submit" className="button button--primary">
            Search
          </button>
        </div>
        {message ? (
          <p id={errorId} className="field-error">
            <span aria-hidden="true">⚠ </span>
            {message}
          </p>
        ) : null}
      </form>
    </search>
  );
}

function SearchStatus({ query, answer, pending, failed }: { query: string | null; answer: DiscoverAnswer | undefined; pending: boolean; failed: boolean }) {
  let text = "";
  if (query !== null && pending) text = `Searching Open Library for “${query}”…`;
  else if (query !== null && failed) text = `The search for “${query}” did not finish.`;
  else if (query !== null && answer && answer.search === "available" && answer.query === query) {
    const count = answer.items.length;
    text = count === 0 ? `No results from Open Library for “${query}”.` : `${count} ${count === 1 ? "result" : "results"} from Open Library for “${query}”.`;
  }
  return (
    <p className="result-count" role="status">
      {text}
    </p>
  );
}

const UNAVAILABLE: Record<Exclude<DiscoverState, "available">, { title: string; body: string }> = {
  server_off: {
    title: "Search is switched off on this server",
    body: "Searching sends what you type to Open Library, so the person who runs this server has to switch it on for this experimental preview first. Your library is not affected.",
  },
  provider_disabled: {
    title: "Open Library is turned off in Shelfarr's settings",
    body: "An administrator has turned off Open Library as a metadata source. This preview cannot search other sources yet.",
  },
  provider_not_selected: {
    title: "Shelfarr is set to search a different source",
    body: "This server's metadata settings choose one source other than Open Library, and this preview can only search Open Library so far.",
  },
  provider_paused: {
    title: "Open Library is paused for now",
    body: "Shelfarr stopped asking Open Library for a while after errors or too many requests.",
  },
};

function Unavailable({ state, retryAfter, checking, onCheck }: { state: Exclude<DiscoverState, "available">; retryAfter: number | null; checking: boolean; onCheck: () => void }) {
  const message = UNAVAILABLE[state];
  return (
    <EmptyState title={message.title}>
      <p>
        {message.body}
        {state === "provider_paused" ? ` ${retryAfter !== null ? `Try again in about ${waitText(retryAfter)}.` : "Try again later."}` : ""}
      </p>
      {state === "server_off" ? null : (
        <button type="button" className="button" onClick={onCheck} disabled={checking}>
          {checking ? "Checking…" : "Check again"}
        </button>
      )}
    </EmptyState>
  );
}

function waitText(seconds: number): string {
  if (seconds < 90) return `${Math.max(1, Math.ceil(seconds))} ${Math.ceil(seconds) === 1 ? "second" : "seconds"}`;
  const minutes = Math.ceil(seconds / 60);
  return `${minutes} minutes`;
}

function SearchFailure({ error, query, onRetry }: { error: unknown; query: string | null; onRetry: () => void }) {
  const code = error instanceof ApiError ? error.code : null;
  const kind = failureKind(error);
  if (kind === "not_found") {
    return (
      <EmptyState title="Discover is not available on this server">
        <p>This server does not offer search yet. Nothing was changed.</p>
      </EmptyState>
    );
  }
  if (kind === "invalid") {
    return (
      <EmptyState title="That search was not accepted">
        <p>Use a title or an author of up to {MAX_QUERY_CHARACTERS} characters, without line breaks or tabs.</p>
      </EmptyState>
    );
  }
  if (kind === "rate_limited") {
    const wait = error instanceof ApiError && error.retryAfterSeconds !== null ? ` Try again in about ${waitText(error.retryAfterSeconds)}.` : " Wait a moment, then try again.";
    return (
      <Failure title="Too many searches right now" onRetry={onRetry}>
        This server sends Open Library at most one search a second, and Open Library may ask it to slow down.{wait}
      </Failure>
    );
  }
  if (code === "search_unavailable") {
    return (
      <Failure title="Open Library could not be reached" onRetry={onRetry}>
        This server could not connect to Open Library{query ? ` to search for “${query}”` : ""}. Try again in a moment.
      </Failure>
    );
  }
  if (code === "search_failed") {
    return (
      <Failure title="Open Library's answer could not be used" onRetry={onRetry}>
        Open Library answered with an error or with something this server does not accept. Try again later.
      </Failure>
    );
  }
  return <ErrorPanel error={error} onRetry={onRetry} />;
}

function Failure({ title, children, onRetry }: { title: string; children: ReactNode; onRetry: () => void }) {
  return (
    <div className="state state--error" role="alert">
      <h2>{title}</h2>
      <p>{children}</p>
      <div className="state-actions">
        <button type="button" className="button" onClick={onRetry}>
          Try again
        </button>
      </div>
    </div>
  );
}

function Results({ answer, onRefresh, refreshing }: { answer: DiscoverAnswer; onRefresh: () => void; refreshing: boolean }) {
  const query = answer.query ?? "";
  return (
    <section className="discover-results" aria-labelledby="discover-results-heading">
      <h2 id="discover-results-heading">Results from Open Library</h2>
      <p className="discover-note">
        Only Open Library is searched here; Shelfarr's classic search may also use other sources your server has set up.{" "}
        {answer.requesting
          ? "You can request an ebook that is not in your library yet. This server is a test setup: it looks for the ebook only in its own copy of the Project Gutenberg catalogue."
          : "Requesting books is not part of this preview yet."}
      </p>
      {answer.items.length === 0 ? (
        <EmptyState title={`Nothing found for “${query}”`}>
          <p>Check the spelling, or try fewer words, only the title, or only the author's surname.</p>
        </EmptyState>
      ) : (
        <ol className="discover-list">
          {answer.items.map((item) => (
            <li key={item.id}>
              <Result item={item} requesting={answer.requesting === true} onRefresh={onRefresh} refreshing={refreshing} />
            </li>
          ))}
        </ol>
      )}
    </section>
  );
}

const COPY_LABELS: Record<LibraryCopyType, string> = { ebook: "ebook", audiobook: "audiobook", comicbook: "comic" };

function styleFor(id: string) {
  let sum = 0;
  for (const character of id) sum = (sum + character.charCodeAt(0)) % coverStyles.length;
  return coverStyles[sum] ?? "clay";
}

function Result({ item, requesting, onRefresh, refreshing }: { item: DiscoverItem; requesting: boolean; onRefresh: () => void; refreshing: boolean }) {
  const titleId = useId();
  const details = [item.first_publish_year !== null ? `First published ${item.first_publish_year}` : null, item.edition_count !== null ? `${item.edition_count} ${item.edition_count === 1 ? "edition" : "editions"}` : null].filter(Boolean).join(" · ");
  return (
    <article className="discover-result" aria-labelledby={titleId}>
      <Cover publication={{ title: item.title, author: item.author, book_type: "ebook", cover: { url: item.cover_url, style: styleFor(item.id) } }} />
      <div className="discover-copy">
        <h3 id={titleId}>{item.title}</h3>
        <p className="book-author">{item.author ?? "Author not listed"}</p>
        {details ? <p className="discover-meta">{details}</p> : null}
        {item.library.length > 0 ? (
          <ul className="discover-library" aria-label="In your library">
            {item.library.map((copy) => (
              <li key={copy.book_type}>
                <Link to="/library/$publicationId" params={{ publicationId: copy.publication_id }} className="button button--subtle">
                  Open the {COPY_LABELS[copy.book_type]}
                  <span className="sr-only"> of {item.title} in your library</span>
                </Link>
              </li>
            ))}
          </ul>
        ) : (
          <p className="discover-meta">No copy to open in your library</p>
        )}
        {requesting && !item.library.some((copy) => copy.book_type === "ebook") ? <RequestEbook item={item} onRefresh={onRefresh} refreshing={refreshing} /> : null}
        <a className="discover-source" href={item.source_url} target="_blank" rel="noopener noreferrer">
          View on Open Library
          <span className="sr-only"> for {item.title} (opens in a new tab)</span>
        </a>
      </div>
    </article>
  );
}

function RequestEbook({ item, onRefresh, refreshing }: { item: DiscoverItem; onRefresh: () => void; refreshing: boolean }) {
  const request = useRequestEbook();
  const status = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (request.isSuccess) status.current?.focus();
  }, [request.isSuccess]);
  const send = () => {
    if (!request.isPending) request.mutate(item.id);
  };
  return (
    <div className="discover-request">
      {request.isSuccess ? null : (
        <button type="button" className="button button--primary" aria-disabled={request.isPending ? true : undefined} onClick={send}>
          {request.isPending ? "Requesting…" : request.isError ? "Try requesting again" : "Request ebook"}
          <span className="sr-only"> of {item.title}</span>
        </button>
      )}
      <div role="status" className="discover-request-status" ref={status} tabIndex={-1}>
        {request.isPending ? <p>Sending the request for “{item.title}”…</p> : null}
        {request.isSuccess ? <RequestOutcome answer={request.data} title={item.title} /> : null}
        {request.isError ? <RequestFailure error={request.error} onRefresh={onRefresh} refreshing={refreshing} /> : null}
      </div>
    </div>
  );
}

function TrackLink({ id, title }: { id: string; title: string }) {
  return (
    <Link to="/requests/$requestId" params={{ requestId: id }} className="button button--subtle">
      Track it in Requests<span className="sr-only"> for {title}</span>
    </Link>
  );
}

function RequestOutcome({ answer, title }: { answer: RequestCreation; title: string }) {
  switch (answer.outcome) {
    case "created":
      return (
        <>
          <p>Requested. Shelfarr will look for the ebook and add it to your library when it is found.</p>
          {answer.warnings.map((warning) => (
            <p key={warning} className="discover-meta">
              {warning}
            </p>
          ))}
          <TrackLink id={answer.request.id} title={title} />
        </>
      );
    case "existing":
      return (
        <>
          <p>You have already requested this ebook. Nothing new was added.</p>
          <TrackLink id={answer.request.id} title={title} />
        </>
      );
    case "already_requested":
      return <p>Someone else has already requested this ebook. Once it arrives it will be in the library for everyone here.</p>;
    case "already_in_library":
      return answer.library ? (
        <>
          <p>This ebook is already in your library.</p>
          <Link to="/library/$publicationId" params={{ publicationId: answer.library.publication_id }} className="button button--subtle">
            Open the ebook<span className="sr-only"> of {title} in your library</span>
          </Link>
        </>
      ) : (
        <p>A copy of this ebook is already recorded, but the Library here cannot open it right now. Nothing new was requested.</p>
      );
  }
}

function RequestFailure({ error, onRefresh, refreshing }: { error: unknown; onRefresh: () => void; refreshing: boolean }) {
  const code = error instanceof ApiError ? error.code : null;
  const kind = failureKind(error);
  if (code === "work_not_offered")
    return (
      <>
        <p className="field-error">This result is from an earlier search. Search again, then request it.</p>
        <button type="button" className="button" aria-disabled={refreshing ? true : undefined} onClick={() => (refreshing ? undefined : onRefresh())}>
          {refreshing ? "Searching…" : "Search again"}
        </button>
      </>
    );
  if (unconfirmed(error))
    return (
      <p className="field-error">
        The server did not confirm the request, so it may or may not have been received. <Link to="/requests">Check Requests</Link> before trying again; while a request is open or waiting for its next search, asking again does not create a second one.
      </p>
    );
  if (kind === "csrf") return <p className="field-error">The page's security check expired. Try again.</p>;
  return <p className="field-error">The request could not be made. Nothing was changed.</p>;
}
