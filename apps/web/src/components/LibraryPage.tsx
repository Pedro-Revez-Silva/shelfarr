import { getRouteApi, Link, useNavigate } from "@tanstack/react-router";
import { useCallback, useMemo } from "react";
import type { LibraryFilters } from "../contract";
import { flattenLibrary, useContinueReading, useLibrary, useSession } from "../queries";
import { useServices } from "../services";
import { useListRestoration } from "../restoration";
import { usePageTitle } from "../title";
import { ContinueShelf } from "./ContinueShelf";
import { LibraryControls } from "./LibraryControls";
import { PageHeading } from "./PageHeading";
import { PublicationCard } from "./PublicationCard";
import { BookGridSkeleton, EmptyState, ErrorPanel } from "./States";

const routeApi = getRouteApi("/library");

function compact(filters: LibraryFilters): LibraryFilters {
  const next: LibraryFilters = {};
  if (filters.q) next.q = filters.q;
  if (filters.type) next.type = filters.type;
  if (filters.status) next.status = filters.status;
  if (filters.sort && filters.sort !== "recent") next.sort = filters.sort;
  return next;
}

export function LibraryPage() {
  const filters = routeApi.useSearch();
  const navigate = useNavigate();
  const { boot, mode } = useServices();
  usePageTitle(filters.q ? `Search: ${filters.q}` : "Library");
  const session = useSession();
  const library = useLibrary(filters);
  const filtered = Boolean(filters.q || filters.type || filters.status);
  const showContinue = !filters.q && !filters.status;
  const reading = useContinueReading(filters, showContinue);
  const items = useMemo(() => flattenLibrary(library.data), [library.data]);
  const libraryPath = `${boot.mount}/library`;

  const persist = useListRestoration({
    isSuccess: library.isSuccess,
    pageCount: library.data?.pages.length ?? 0,
    hasNextPage: library.hasNextPage,
    isFetchingNextPage: library.isFetchingNextPage,
    fetchNextPage: library.fetchNextPage,
    isListLocation: useCallback(() => window.location.pathname === libraryPath, [libraryPath]),
  });

  const change = (next: LibraryFilters) => {
    void navigate({ to: "/library", search: compact(next) });
  };

  const serverName = session.data?.server.name;

  return (
    <section aria-labelledby="library-heading" className="library">
      <header className="page-heading">
        <p className="eyebrow">On {serverName ?? "your server"}</p>
        <PageHeading id="library-heading">Library</PageHeading>
        <p className="lede">The books and audiobooks stored on this server, ready to read or listen to.</p>
        {mode === "rails" ? (
          <div className="state-actions">
            <Link className="button button--subtle" to="/library/uploads">
              Uploads
            </Link>
            {boot.offline ? (
              <a className="button button--subtle" href={boot.offline.downloads}>
                Downloads
              </a>
            ) : null}
          </div>
        ) : null}
      </header>

      {showContinue && reading.data ? <ContinueShelf items={reading.data.items} /> : null}

      <section aria-labelledby="shelf-heading" className="shelf">
        <h2 id="shelf-heading">{filters.q ? "Search results" : "On your shelf"}</h2>
        <LibraryControls filters={filters} onChange={change} />

        {library.isPending ? <BookGridSkeleton /> : null}
        {library.isError && !library.data ? <ErrorPanel error={library.error} onRetry={() => void library.refetch()} /> : null}

        {library.isSuccess && items.length === 0 ? (
          filtered ? (
            <EmptyState title="No books match these filters">
              <p>Try another title or author, or clear the filters to see everything on this server.</p>
              <button type="button" className="button" onClick={() => change({})}>
                Clear filters
              </button>
            </EmptyState>
          ) : (
            <EmptyState title="Nothing on this server yet">
              <p>{mode === "go" ? "Acquired ebooks and audiobooks appear here." : "Acquired ebooks, comics and audiobooks appear here."}</p>
              {mode === "rails" ? (
                <Link className="button" to="/find">
                  Find books
                </Link>
              ) : null}
            </EmptyState>
          )
        ) : null}

        {items.length > 0 ? (
          <>
            <p className="result-count" role="status">
              Showing {items.length} {items.length === 1 ? "book" : "books"}
              {library.hasNextPage ? " so far" : ""}
            </p>
            <ul className="book-grid" onClickCapture={persist}>
              {items.map((item) => (
                <li key={item.id}>
                  <PublicationCard publication={item} />
                </li>
              ))}
            </ul>
            {library.isFetchNextPageError ? (
              <div className="inline-error" role="alert">
                <p>More books could not be loaded.</p>
                <button type="button" className="button" onClick={() => void library.fetchNextPage()}>
                  Try again
                </button>
              </div>
            ) : null}
            {library.hasNextPage ? (
              <div className="load-more">
                <button type="button" className="button" disabled={library.isFetchingNextPage} onClick={() => void library.fetchNextPage()}>
                  {library.isFetchingNextPage ? "Loading…" : "Load more books"}
                </button>
              </div>
            ) : (
              <p className="end-note">That is everything on this shelf.</p>
            )}
          </>
        ) : null}
      </section>
    </section>
  );
}
