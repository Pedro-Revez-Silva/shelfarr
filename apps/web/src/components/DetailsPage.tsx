import { getRouteApi, Link, useRouter } from "@tanstack/react-router";
import type { PublicationDetail } from "../contract";
import { goReaderLink } from "../reader/links";
import { failureKind } from "../api/errors";
import { usePublication } from "../queries";
import { useServices } from "../services";
import { usePageTitle } from "../title";
import { Cover } from "./Cover";
import { PageHeading } from "./PageHeading";
import { ReadingStatusForm } from "./ReadingStatusForm";
import { ErrorPanel, Loading } from "./States";
import { SaveForOffline } from "../offline/SaveForOffline";

const routeApi = getRouteApi("/library/$publicationId");

export function DetailsPage() {
  const { publicationId } = routeApi.useParams();
  const publication = usePublication(publicationId);
  usePageTitle(publication.data?.title ?? (publication.isError ? "Book not found" : "Loading book"));

  if (publication.isPending) {
    return (
      <section className="details" aria-busy="true">
        <BackToLibrary />
        <Loading label="Loading this book…" />
      </section>
    );
  }

  if (publication.isError) {
    const missing = failureKind(publication.error) === "not_found";
    return (
      <section className="details">
        <BackToLibrary />
        {missing ? (
          <div className="state state--empty" role="alert">
            <h1>This book is no longer in your library</h1>
            <p>It may have been removed from the server, or it was never available to this account.</p>
            <div className="state-actions">
              <Link to="/library" className="button button--primary">
                Back to the library
              </Link>
            </div>
          </div>
        ) : (
          <ErrorPanel error={publication.error} onRetry={() => void publication.refetch()} />
        )}
      </section>
    );
  }

  return <Details publication={publication.data} />;
}

function BackToLibrary() {
  const router = useRouter();
  const canGoBack = router.history.canGoBack();
  if (canGoBack) {
    return (
      <button type="button" className="back-link" onClick={() => router.history.back()}>
        <span aria-hidden="true">← </span>Back to the library
      </button>
    );
  }
  return (
    <Link to="/library" className="back-link">
      <span aria-hidden="true">← </span>Library
    </Link>
  );
}

function primaryLabel(publication: PublicationDetail): string {
  const listening = publication.action === "listen";
  if (publication.reading_status === "finished") return listening ? "Listen again" : "Read again";
  if (publication.progress) return listening ? "Continue listening" : "Continue reading";
  return listening ? "Start listening" : "Start reading";
}

function savableEpub(publication: PublicationDetail): string | null {
  if (publication.availability !== "available" || publication.action !== "read") return null;
  const epubs = publication.files.filter((file) => file.format === "epub");
  return (epubs.find((file) => file.id === publication.progress?.asset_id) ?? epubs[0])?.id ?? null;
}

function Details({ publication }: { publication: PublicationDetail }) {
  const available = publication.availability === "available";
  const { mode, boot, api } = useServices();
  const readerLink = mode === "go" ? goReaderLink(publication, boot.mount, boot.reader_formats) : publication.reader_url;
  const epub = mode === "go" && readerLink ? savableEpub(publication) : null;
  return (
    <article className="details" aria-labelledby="publication-heading">
      <BackToLibrary />
      <div className="details-layout">
        <Cover publication={publication} large />
        <div className="details-main">
          <p className="eyebrow">{publication.format_label}</p>
          <PageHeading id="publication-heading">{publication.title}</PageHeading>
          {publication.author ? <p className="details-author">{publication.author}</p> : null}

          {available && !readerLink ? (
            <div className="primary-action">
              <p className="notice" role="note">
                Opening this {publication.format_label === "Comic" ? "comic" : "PDF"} is not available in this experimental reader yet; it opens EPUBs and audiobooks. Your saved place is kept and you can still set its status below.
              </p>
              {publication.progress || publication.reading_status !== "unread" ? <p className="progress-label">{publication.progress_label}</p> : null}
              {publication.progress?.fraction != null && publication.reading_status === "in_progress" ? (
                <progress className="book-progress" max={1} value={publication.progress.fraction} aria-label="Reading progress" />
              ) : null}
            </div>
          ) : available ? (
            <div className="primary-action">
              <a className="button button--primary button--large" href={readerLink ?? publication.reader_url}>
                {primaryLabel(publication)}
                <span className="sr-only"> {publication.title} in the {publication.action === "listen" ? "player" : "reader"}</span>
              </a>
              {publication.progress || publication.reading_status !== "unread" ? <p className="progress-label">{publication.progress_label}</p> : null}
              {publication.progress?.fraction != null && publication.reading_status === "in_progress" ? (
                <progress className="book-progress" max={1} value={publication.progress.fraction} aria-label="Reading progress" />
              ) : null}
            </div>
          ) : (
            <p className="notice" role="note">
              The files for this book are not available on the server right now, so it cannot be opened. Your saved place is kept.
            </p>
          )}

          {epub ? <SaveForOffline id={publication.id} title={publication.title} currentAsset={epub} load={(signal) => api.reader(publication.id, signal)} /> : null}

          <ReadingStatusForm publication={publication} />

          {mode === "rails" && publication.book_page ? (
            <p className="book-page-link">
              <Link to="/books/$source/$sourceId" params={{ source: publication.book_page.source, sourceId: publication.book_page.id }} search={{}}>
                Formats and requests for this book
              </Link>
            </p>
          ) : null}
        </div>
      </div>

      {publication.description ? (
        <section aria-labelledby="about-heading" className="about">
          <h2 id="about-heading">About this book</h2>
          <p className="description">{publication.description}</p>
        </section>
      ) : null}

      {publication.files.length > 0 ? (
        <section aria-labelledby="files-heading" className="files">
          <h2 id="files-heading">Files on the server</h2>
          <div className="table-wrap">
            <table>
              <caption className="sr-only">Files stored for {publication.title}</caption>
              <thead>
                <tr>
                  <th scope="col">File</th>
                  <th scope="col">Format</th>
                  <th scope="col">Size</th>
                </tr>
              </thead>
              <tbody>
                {publication.files.map((file) => (
                  <tr key={file.id}>
                    <th scope="row">{file.filename}</th>
                    <td>{file.page_count ? `${file.format.toUpperCase()} · ${file.page_count} pages` : file.format.toUpperCase()}</td>
                    <td>{formatBytes(file.size_bytes)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      ) : null}
    </article>
  );
}

export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let value = bytes / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value >= 100 ? Math.round(value) : value.toFixed(1)} ${units[unit]}`;
}
