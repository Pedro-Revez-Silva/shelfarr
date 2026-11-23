import { Link } from "@tanstack/react-router";
import { useId, useState, type FormEvent, type ReactNode } from "react";
import { failureKind } from "../api/errors";
import { actionFailure, Time } from "../components/requestText";
import { ErrorPanel, Loading } from "../components/States";
import { Said, useSay } from "../server/extras";
import { RemoveZone } from "../server/primitives";
import { useUploadCommand, useUploadMatches, useUploads, type UploadCommand } from "./api";
import type { Upload, UploadBookType, UploadStatus } from "./contract";
import { formatBytes } from "./files";

type Level = 2 | 3 | 4;
type Say = ReturnType<typeof useSay>["say"];

const STATUS_LABELS: Record<UploadStatus, string> = { pending: "Waiting to process", processing: "Processing", completed: "Completed", failed: "Failed" };
const BADGE: Record<UploadStatus, string> = { pending: "pending", processing: "processing", completed: "completed", failed: "failed" };
export const BOOK_TYPE_LABELS: Record<UploadBookType, string> = { ebook: "Ebook", audiobook: "Audiobook", comicbook: "Comic" };

function Heading({ level, id, children, className, focusable = false }: { level: Level | 5; id: string; children: ReactNode; className?: string; focusable?: boolean }) {
  const Tag = `h${level}` as "h2";
  return (
    <Tag id={id} className={className} tabIndex={focusable ? -1 : undefined}>
      {children}
    </Tag>
  );
}

export function UploadList({ admin, page, onPage, level, title }: { admin: boolean; page: number; onPage: (page: number) => void; level: Level; title: string }) {
  const list = useUploads(page);
  const { said, say } = useSay();
  const headingId = useId();
  const data = list.data;
  const focusList = () => document.getElementById(headingId)?.focus();

  return (
    <section className="upload-list" aria-labelledby={headingId}>
      <div className="upload-list-heading">
        <Heading level={level} id={headingId} focusable>
          {title}
        </Heading>
        <p className="result-count" role="status">
          {list.isPending ? "" : data ? `${data.total} ${data.total === 1 ? "upload" : "uploads"}${data.total_pages > 1 ? ` · Page ${data.page} of ${data.total_pages}` : ""}` : ""}
        </p>
      </div>
      <Said said={said} />
      {list.isPending ? <Loading label="Loading uploads…" /> : null}
      {list.isError && !data ? <ErrorPanel error={list.error} onRetry={() => void list.refetch()} /> : null}
      {list.isError && data ? (
        <p className="refresh-problem" role="alert">
          The latest uploads could not be loaded. The list shows what was last read.{" "}
          <button type="button" className="button button--subtle" onClick={() => void list.refetch()}>
            Try again
          </button>
        </p>
      ) : null}
      {data && data.items.length === 0 ? <p className="request-note">No uploads yet. Files added here appear in this list while Shelfarr processes them.</p> : null}
      {data && data.items.length > 0 ? (
        <ol className="request-list upload-rows">
          {data.items.map((upload) => (
            <li key={upload.id}>
              <UploadRow upload={upload} admin={admin} level={(level + 1) as Level | 5} say={say} onRemoved={focusList} />
            </li>
          ))}
        </ol>
      ) : null}
      {data && data.total_pages > 1 ? (
        <nav className="pagination" aria-label={`${title} pages`}>
          <p>
            Page {data.page} of {data.total_pages}
          </p>
          <div className="pagination-links">
            {data.page > 1 ? (
              <button type="button" className="button" onClick={() => onPage(data.page - 1)}>
                Previous<span className="sr-only"> page</span>
              </button>
            ) : null}
            {data.page < data.total_pages ? (
              <button type="button" className="button" onClick={() => onPage(data.page + 1)}>
                Next<span className="sr-only"> page</span>
              </button>
            ) : null}
          </div>
        </nav>
      ) : null}
    </section>
  );
}

function UploadRow({ upload, admin, level, say, onRemoved }: { upload: Upload; admin: boolean; level: Level | 5; say: Say; onRemoved: () => void }) {
  const titleId = useId();
  const by = upload.uploaded_by_you ? "by you" : admin && upload.uploaded_by ? `by ${upload.uploaded_by}` : null;
  return (
    <article className="upload-row" aria-labelledby={titleId}>
      <Heading level={level} id={titleId} className="upload-name">
        {upload.filename}
      </Heading>
      <ul className="request-badges" aria-label="Upload state">
        <li className="badge">{upload.book_type ? BOOK_TYPE_LABELS[upload.book_type] : "Type not known yet"}</li>
        <li className={`badge badge--status badge--${BADGE[upload.status]}`}>{STATUS_LABELS[upload.status]}</li>
        {upload.manual_match ? <li className="badge">Matched by hand</li> : null}
      </ul>
      <p className="request-meta">
        {upload.size !== null ? <span>{formatBytes(upload.size)}</span> : null}
        <span>
          Uploaded {by ? `${by} ` : ""}
          <Time iso={upload.created_at} relative />
        </span>
        {upload.processed_at ? (
          <span>
            Processed <Time iso={upload.processed_at} relative />
          </span>
        ) : null}
      </p>
      <dl className="request-facts upload-facts">
        <div>
          <dt>Read from the file name</dt>
          <dd>
            {upload.parsed ? (
              <>
                {upload.parsed.title} by {upload.parsed.author ?? "Unknown"}
                {upload.parsed.confidence !== null ? ` · ${upload.parsed.confidence}% confident` : ""}
              </>
            ) : (
              "Not read yet"
            )}
          </dd>
        </div>
        {upload.book ? (
          <div>
            <dt>{upload.manual_match ? "Chosen book" : "Matched book"}</dt>
            <dd>
              {upload.book.publication_id ? (
                <Link to="/library/$publicationId" params={{ publicationId: upload.book.publication_id }}>
                  {upload.book.title}
                </Link>
              ) : (
                upload.book.title
              )}
              {upload.book.author ? ` by ${upload.book.author}` : ""}
              {upload.book.acquired ? " · In library" : ""}
            </dd>
          </div>
        ) : null}
      </dl>
      {upload.request_id ? (
        <p className="request-meta">
          <Link to="/requests/$requestId" params={{ requestId: upload.request_id }}>
            Open the request this file fulfils<span className="sr-only"> for {upload.filename}</span>
          </Link>
        </p>
      ) : null}
      {upload.failure ? <p className="upload-failure">{upload.failure}</p> : null}
      {upload.reserved_file ? <p className="request-note">This upload has a reserved library file. Use Retry to reconcile it before changing the matched book.</p> : null}
      {admin && upload.actions ? <UploadActions upload={upload} say={say} onRemoved={onRemoved} /> : null}
    </article>
  );
}

function UploadActions({ upload, say, onRemoved }: { upload: Upload; say: Say; onRemoved: () => void }) {
  const command = useUploadCommand();
  const [matching, setMatching] = useState(false);
  const panelId = useId();
  const actions = upload.actions;
  if (!actions) return null;
  const run = (next: UploadCommand, fallback: string) =>
    command.mutate(next, {
      onSuccess: (outcome) => {
        say(outcome.tone, outcome.message);
        if (next.kind === "remove" && outcome.tone === "success") onRemoved();
      },
      onError: (error) => say("error", actionFailure(error, fallback)),
    });
  return (
    <>
      <div className="copy-actions upload-actions">
        {actions.retry ? (
          <button type="button" className="button button--subtle" aria-disabled={command.isPending ? true : undefined} onClick={() => (command.isPending ? undefined : run({ kind: "retry", id: upload.id }, "The upload could not be retried. Nothing was changed."))}>
            {command.isPending && command.variables?.kind === "retry" ? "Retrying…" : "Retry"}
            <span className="sr-only"> {upload.filename}</span>
          </button>
        ) : null}
        {actions.match ? (
          <button type="button" className="button button--subtle" aria-expanded={matching} aria-controls={panelId} onClick={() => setMatching((open) => !open)}>
            Correct the match<span className="sr-only"> for {upload.filename}</span>
          </button>
        ) : null}
        {actions.remove ? (
          <RemoveZone
            label="Delete"
            confirmLabel="Delete upload"
            question={`Delete ${upload.filename}? A file that is not in the library yet is removed too.`}
            busy={command.isPending && command.variables?.kind === "remove"}
            onRemove={() => run({ kind: "remove", id: upload.id }, "The upload could not be deleted. Nothing was changed.")}
          />
        ) : null}
      </div>
      {actions.match && matching ? (
        <div id={panelId}>
          <MatchPanel upload={upload} say={say} />
        </div>
      ) : null}
    </>
  );
}

function MatchPanel({ upload, say }: { upload: Upload; say: Say }) {
  const [query, setQuery] = useState<string | null>(null);
  const [page, setPage] = useState(1);
  const [draft, setDraft] = useState<string | null>(null);
  const [title, setTitle] = useState<string | null>(null);
  const [author, setAuthor] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const matches = useUploadMatches(upload.id, query, page);
  const command = useUploadCommand();
  const ids = { heading: useId(), search: useId(), title: useId(), author: useId(), error: useId() };
  const data = matches.data;
  const kind = upload.book_type ? BOOK_TYPE_LABELS[upload.book_type].toLowerCase() : "book";

  const choose = (next: UploadCommand) => {
    setError(null);
    command.mutate(next, {
      onSuccess: (outcome) => say(outcome.tone, outcome.message),
      onError: (failure) => setError(actionFailure(failure, "The match could not be saved. Nothing was changed.")),
    });
  };
  const search = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setPage(1);
    setQuery((draft ?? data?.query ?? "").trim());
  };
  const create = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    choose({ kind: "match_new", id: upload.id, title: (title ?? data?.manual_book.title ?? "").trim(), author: (author ?? data?.manual_book.author ?? "").trim() });
  };

  return (
    <section className="upload-match" aria-labelledby={ids.heading}>
      <h4 id={ids.heading}>Correct the match and retry</h4>
      <p className="request-note">Choose a local {kind} or create one with corrected details. Shelfarr keeps your choice on retries and skips automatic matching. Existing library files are kept.</p>
      {error ? (
        <p id={ids.error} className="form-error" role="alert">
          {error}
        </p>
      ) : null}
      <search>
        <form className="upload-match-search" onSubmit={search}>
          <label htmlFor={ids.search}>Search local books by title or author</label>
          <div className="upload-match-row">
            <input id={ids.search} type="search" maxLength={200} value={draft ?? data?.query ?? ""} onChange={(event) => setDraft(event.target.value)} autoComplete="off" />
            <button type="submit" className="button">
              Search books
            </button>
          </div>
          <p className="field-hint">Only books of the same format with no library file or download in progress are shown.</p>
        </form>
      </search>
      {matches.isPending ? <Loading label="Looking for books…" /> : null}
      {matches.isError ? (
        <p className="form-error" role="alert">
          {failureKind(matches.error) === "conflict" ? actionFailure(matches.error, "This upload can't be matched now.") : "The books could not be loaded. Try the search again."}
        </p>
      ) : null}
      {data ? (
        <>
          {data.books.length === 0 ? <p className="request-note">No available books found. Try another search or create a book below.</p> : null}
          <ul className="upload-match-books">
            {data.books.map((book) => (
              <li key={book.id}>
                <span>
                  {book.title}
                  {book.author ? ` by ${book.author}` : ""}
                </span>
                <button type="button" className="button button--subtle" disabled={command.isPending} onClick={() => choose({ kind: "match_book", id: upload.id, bookId: book.id })}>
                  Select and retry<span className="sr-only"> with {book.title}</span>
                </button>
              </li>
            ))}
          </ul>
          {data.page > 1 || data.more ? (
            <nav className="pagination" aria-label="Local book search pages">
              <div className="pagination-links">
                {data.page > 1 ? (
                  <button type="button" className="button button--subtle" onClick={() => setPage(data.page - 1)}>
                    Previous matches
                  </button>
                ) : null}
                {data.more ? (
                  <button type="button" className="button button--subtle" onClick={() => setPage(data.page + 1)}>
                    Next matches
                  </button>
                ) : null}
              </div>
            </nav>
          ) : null}
          <details className="settings-note">
            <summary>Create a book with corrected details</summary>
            <form className="upload-match-create" onSubmit={create}>
              <div className="field">
                <label htmlFor={ids.title}>Title</label>
                <input id={ids.title} type="text" required maxLength={500} value={title ?? data.manual_book.title} onChange={(event) => setTitle(event.target.value)} />
              </div>
              <div className="field">
                <label htmlFor={ids.author}>Author (optional)</label>
                <input id={ids.author} type="text" maxLength={500} value={author ?? data.manual_book.author} onChange={(event) => setAuthor(event.target.value)} />
              </div>
              <div className="form-actions">
                <button type="submit" className="button button--primary" disabled={command.isPending}>
                  {command.isPending ? "Saving…" : "Create book and retry"}
                </button>
              </div>
            </form>
          </details>
        </>
      ) : null}
    </section>
  );
}
