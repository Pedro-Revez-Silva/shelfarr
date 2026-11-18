import { getRouteApi, Link, useNavigate } from "@tanstack/react-router";
import { useId, useState, type FormEvent, type ReactNode } from "react";
import { ApiError, failureKind } from "../api/errors";
import { coverStyles, type DiscoverAnswer, type DiscoverItem, type DiscoverState, type LibraryCopyType } from "../contract";
import { useDiscover } from "../queries";
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
  const state = answer.data?.search ?? null;
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
        <SearchForm initial={checked.kind === "ready" ? checked.query : (q ?? "")} problem={checked.kind === "too_long" || checked.kind === "invalid" ? checked.kind : null} onSearch={submit} />
      ) : null}

      <SearchStatus query={query} answer={answer.data} pending={query !== null && answer.isFetching} failed={answer.isError} />

      {state !== null && state !== "available" ? <Unavailable state={state} retryAfter={answer.data?.retry_after ?? null} checking={answer.isFetching} onCheck={() => void answer.refetch()} /> : null}
      {answer.isError ? <SearchFailure error={answer.error} query={query} onRetry={() => void answer.refetch()} /> : null}
      {query === null && answer.isPending ? <Loading label="Checking whether search is available…" /> : null}
      {answer.data && answer.data.search === "available" && answer.data.query !== null && !answer.isError ? <Results answer={answer.data} /> : null}
    </section>
  );
}

function SearchForm({ initial, problem, onSearch }: { initial: string; problem: "too_long" | "invalid" | null; onSearch: (query: string) => void }) {
  const [text, setText] = useState(initial);
  const [shown, setShown] = useState(initial);
  const [blank, setBlank] = useState(false);
  if (shown !== initial) {
    setShown(initial);
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

function Results({ answer }: { answer: DiscoverAnswer }) {
  const query = answer.query ?? "";
  return (
    <section className="discover-results" aria-labelledby="discover-results-heading">
      <h2 id="discover-results-heading">Results from Open Library</h2>
      <p className="discover-note">
        Only Open Library is searched here; Shelfarr's classic search may also use other sources your server has set up. Requesting books is not part of this preview yet.
      </p>
      {answer.items.length === 0 ? (
        <EmptyState title={`Nothing found for “${query}”`}>
          <p>Check the spelling, or try fewer words, only the title, or only the author's surname.</p>
        </EmptyState>
      ) : (
        <ol className="discover-list">
          {answer.items.map((item) => (
            <li key={item.id}>
              <Result item={item} />
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

function Result({ item }: { item: DiscoverItem }) {
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
        <a className="discover-source" href={item.source_url} target="_blank" rel="noopener noreferrer">
          View on Open Library
          <span className="sr-only"> for {item.title} (opens in a new tab)</span>
        </a>
      </div>
    </article>
  );
}
