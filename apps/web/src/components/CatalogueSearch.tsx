import { getRouteApi, Link, useNavigate } from "@tanstack/react-router";
import { useEffect, useId, useRef, useState, type FormEvent } from "react";
import { ApiError, failureKind } from "../api/errors";
import type { CatalogueAnswer, CatalogueItem, RequestOptions } from "../contract";
import { useCatalogue, useRequestBook, useSession } from "../queries";
import { actionFailure } from "./requestText";
import { choiceFor, NO_EXTRAS, offersLanguage, outcomeSentence, RejectedFormats, RequestExtrasFields, requestLabel, requestPlan, type RequestFormat } from "./RequestChoices";
import { Cover } from "./Cover";
import { FindTabs, YourRequests } from "./FindRequests";
import { checkQuery, MAX_QUERY_CHARACTERS } from "./DiscoverPage";
import { PageHeading } from "./PageHeading";
import { EmptyState, ErrorPanel, Loading } from "./States";

const routeApi = getRouteApi("/find");

export function CatalogueSearch() {
  const { q } = routeApi.useSearch();
  const navigate = useNavigate();
  const session = useSession();
  const checked = checkQuery(q);
  const query = checked.kind === "ready" ? checked.query : null;
  const answer = useCatalogue(query);

  return (
    <section className="discover" aria-labelledby="discover-heading">
      <header className="page-heading">
        <p className="eyebrow">Find books</p>
        <PageHeading id="discover-heading">Find</PageHeading>
        <p className="lede">Search the catalogues this server uses by title or author, see what is already in the library, and request a book from its result or its page.</p>
      </header>
      <FindTabs />
      <SearchForm
        source={q ?? ""}
        initial={query ?? q ?? ""}
        problem={checked.kind === "too_long" || checked.kind === "invalid" ? checked.kind : null}
        onSearch={(text) => void navigate({ to: "/find", search: { q: text } })}
      />
      <p className="result-count" role="status">
        {query === null ? "" : answer.isFetching ? `Searching for “${query}”…` : answer.data ? countText(answer.data) : answer.isError ? `The search for “${query}” did not finish.` : ""}
      </p>
      {query !== null && answer.isPending ? <Loading label="Searching the catalogue…" /> : null}
      {answer.isError ? <SearchFailure error={answer.error} onRetry={() => void answer.refetch()} /> : null}
      {answer.data && answer.data.unavailable.length > 0 ? (
        <p className="notice" role="note">
          {answer.data.unavailable.join(", ")} could not be reached, so these results may be incomplete.{" "}
          <button type="button" className="button button--subtle" aria-disabled={answer.isFetching ? true : undefined} onClick={() => (answer.isFetching ? undefined : void answer.refetch())}>
            {answer.isFetching ? "Searching…" : "Search again"}
          </button>
        </p>
      ) : null}
      {answer.data ? <Results answer={answer.data} /> : null}
      {query === null ? <YourRequests /> : null}
      {session.data ? (
        <p className="discover-note">
          Need series, collections or comics? <a href={session.data.links.discover}>Use the classic search<span className="sr-only"> (opens the classic Shelfarr app)</span></a>.
        </p>
      ) : null}
    </section>
  );
}

function countText(answer: CatalogueAnswer): string {
  if (answer.providers.length === 0) return "No catalogue is switched on for this server.";
  const count = answer.items.length;
  return count === 0 ? `No results for “${answer.query}”.` : `${count} ${count === 1 ? "result" : "results"} for “${answer.query}” from ${answer.providers.join(", ")}.`;
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
        <div className="search-row">
          <input
            id={inputId}
            type="search"
            name="q"
            value={text}
            maxLength={MAX_QUERY_CHARACTERS}
            enterKeyHint="search"
            autoComplete="off"
            spellCheck={false}
            aria-describedby={message ? errorId : undefined}
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

function SearchFailure({ error, onRetry }: { error: unknown; onRetry: () => void }) {
  const code = error instanceof ApiError ? error.code : null;
  if (failureKind(error) === "invalid") {
    return (
      <EmptyState title="That search was not accepted">
        <p>Use a title or an author of up to {MAX_QUERY_CHARACTERS} characters, without line breaks or tabs.</p>
      </EmptyState>
    );
  }
  if (code === "search_unavailable" || code === "search_failed") {
    return (
      <div className="state state--error" role="alert">
        <h2>{code === "search_unavailable" ? "The catalogue could not be reached" : "The catalogue's answer could not be used"}</h2>
        <p>Try again in a moment. Your library is not affected.</p>
        <div className="state-actions">
          <button type="button" className="button" onClick={onRetry}>
            Try again
          </button>
        </div>
      </div>
    );
  }
  return <ErrorPanel error={error} onRetry={onRetry} />;
}

function Results({ answer }: { answer: CatalogueAnswer }) {
  if (answer.providers.length === 0) {
    return (
      <EmptyState title="No catalogue is switched on">
        <p>This server has no metadata source turned on for books, so there is nothing to search. An administrator can turn one on in Shelfarr's settings.</p>
      </EmptyState>
    );
  }
  if (answer.items.length === 0) {
    return (
      <EmptyState title={`Nothing found for “${answer.query}”`}>
        <p>Check the spelling, or try fewer words, only the title, or only the author's surname.</p>
      </EmptyState>
    );
  }
  return (
    <ol className="discover-list">
      {answer.items.map((item) => (
        <li key={`${item.book.source}:${item.book.id}`}>
          <Result item={item} query={answer.query} options={answer.request_options ?? null} />
        </li>
      ))}
    </ol>
  );
}

const STATE_TEXT: Record<CatalogueItem["formats"][number]["state"], string> = {
  requestable: "not in library",
  requested: "requested",
  requested_by_someone: "requested by someone here",
  in_library: "in library",
};

function Result({ item, query, options }: { item: CatalogueItem; query: string; options: RequestOptions | null }) {
  const titleId = useId();
  const owned = item.formats.some((format) => format.state === "in_library");
  return (
    <article className={owned ? "discover-result discover-result--owned" : "discover-result"} aria-labelledby={titleId}>
      <Cover publication={{ title: item.title, author: item.author, book_type: "ebook", cover: item.cover }} />
      <div className="discover-copy">
        <h3 id={titleId}>
          <Link
            to="/books/$source/$sourceId"
            params={{ source: item.book.source, sourceId: item.book.id }}
            search={{ q: query, ...(item.book.metadata ? { metadata: item.book.metadata } : {}) }}
          >
            {item.title}
          </Link>
        </h3>
        <p className="book-author">{item.author ?? "Author not listed"}</p>
        <p className="discover-meta">{[item.year !== null ? `First published ${item.year}` : null, `From ${item.source_name}`].filter(Boolean).join(" · ")}</p>
        <ul className="discover-formats" aria-label="On this server">
          {item.formats.map((format) => (
            <li key={format.book_type} className={`format-chip format-chip--${format.state}`}>
              {format.book_type === "ebook" ? "Ebook" : "Audiobook"}: {STATE_TEXT[format.state]}
            </li>
          ))}
        </ul>
        {options ? <ResultRequest item={item} query={query} options={options} /> : null}
      </div>
    </article>
  );
}

function ResultRequest({ item, query, options }: { item: CatalogueItem; query: string; options: RequestOptions }) {
  const request = useRequestBook({ source: item.book.source, id: item.book.id, metadata: item.book.metadata ?? undefined });
  const [pressed, setPressed] = useState<RequestFormat | null>(null);
  const [extras, setExtras] = useState(NO_EXTRAS);
  const done = useRef<HTMLParagraphElement>(null);
  const plan = requestPlan(item.formats, options);
  const succeeded = request.isSuccess;
  useEffect(() => {
    if (succeeded) done.current?.focus();
  }, [succeeded]);
  const send = (format: RequestFormat) => {
    if (request.isPending) return;
    setPressed(format);
    request.mutate(choiceFor(format, extras, options), { onSuccess: () => setExtras((current) => ({ ...current, notes: "" })) });
  };
  if (plan.length === 0 && request.isIdle) return null;
  return (
    <div className="result-request">
      {request.isSuccess ? (
        <p ref={done} tabIndex={-1} className="result-request-done">
          {outcomeSentence(request.data.results, item.formats)}{" "}
          <Link to="/books/$source/$sourceId" params={{ source: item.book.source, sourceId: item.book.id }} search={{ q: query, ...(item.book.metadata ? { metadata: item.book.metadata } : {}) }}>
            Follow it on its page<span className="sr-only">: {item.title}</span>
          </Link>
        </p>
      ) : null}
      {plan.length > 0 ? (
        <div className="result-request-actions">
          {plan.map((entry) => {
            const mine = pressed === entry.format;
            return (
              <button key={entry.format} type="button" className="button" aria-disabled={request.isPending ? true : undefined} onClick={() => send(entry.format)}>
                {mine && request.isPending ? "Requesting…" : mine && request.isError ? "Try requesting again" : requestLabel(entry.format)}
                <span className="sr-only"> of {item.title}</span>
              </button>
            );
          })}
        </div>
      ) : null}
      {plan.length > 0 && offersLanguage(options) ? <RequestExtrasFields options={options} extras={extras} onChange={setExtras} disabled={request.isPending} /> : null}
      {request.isError ? (
        <p className="field-error" role="alert">
          {actionFailure(request.error, "The request could not be made. Nothing was changed.")}
        </p>
      ) : null}
      {request.isSuccess ? <RejectedFormats results={request.data.results} /> : null}
    </div>
  );
}
