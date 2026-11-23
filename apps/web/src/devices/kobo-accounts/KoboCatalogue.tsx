import { Link } from "@tanstack/react-router";
import { useId } from "react";
import { ErrorPanel, Loading } from "../../components/States";
import { ToneLine } from "../kobo/KoboParts";
import type { CatalogueSearch, KoboCatalogue } from "./contract";
import { useKoboCatalogue } from "./queries";

export type CatalogueRoute = "/account/devices/kobo-accounts/$accountId" | "/account/devices/kobo-shared/$accountId";

const FILTERS = [
  { value: undefined, label: "All titles" },
  { value: "sendable", label: "Can be sent" },
] as const;

function titles(count: number): string {
  return `${count} ${count === 1 ? "title" : "titles"}`;
}

export function CatalogueCard({ accountId, search, route }: { accountId: string; search: CatalogueSearch; route: CatalogueRoute }) {
  const catalogue = useKoboCatalogue(accountId, search);
  const headingId = useId();
  return (
    <section className="account-card" aria-labelledby={headingId} aria-busy={catalogue.isFetching}>
      {catalogue.data ? (
        <CatalogueBody headingId={headingId} catalogue={catalogue.data} accountId={accountId} route={route} />
      ) : (
        <>
          <h2 id={headingId}>Kobo catalogue</h2>
          {catalogue.isError ? <ErrorPanel error={catalogue.error} onRetry={() => void catalogue.refetch()} /> : <Loading label="Loading this catalogue…" />}
        </>
      )}
    </section>
  );
}

function CatalogueBody({ headingId, catalogue, accountId, route }: { headingId: string; catalogue: KoboCatalogue; accountId: string; route: CatalogueRoute }) {
  const sendable = catalogue.filter === "sendable" ? "sendable" : undefined;
  return (
    <>
      <h2 id={headingId}>Kobo catalogue · {titles(catalogue.count)}</h2>
      <p className="muted">{catalogue.sendable_count} can be sent to a Kobo reader as DRM-free EPUBs.</p>
      <nav aria-label="Catalogue filter" className="kobo-filter">
        {FILTERS.map((option) =>
          option.value === sendable ? (
            <span key={option.label} className="kobo-filter-chip" aria-current="page">
              {option.label}
            </span>
          ) : (
            <Link key={option.label} className="kobo-filter-chip" to={route} params={{ accountId }} search={option.value ? { filter: option.value } : {}}>
              {option.label}
            </Link>
          ),
        )}
      </nav>
      {catalogue.books.length === 0 ? (
        <p>
          {sendable
            ? "No titles in this catalogue can be sent yet."
            : catalogue.kobo_account.last_synced_at
              ? "Kobo returned no catalogue entries for this connection."
              : "The catalogue will appear after the first successful refresh."}
        </p>
      ) : (
        <ul className="kobo-catalogue">
          {catalogue.books.map((book) => (
            <li key={book.id} data-testid="kobo-catalogue-entry">
              <p className="token-name">
                <Link to="/account/devices/kobo-books/$bookId" params={{ bookId: book.id }}>
                  {book.title}
                </Link>
              </p>
              <p className="request-meta">{book.author ?? "Unknown author"}</p>
              <ToneLine notice={{ tone: book.eligibility.tone, text: book.eligibility.label, choosable: false }} />
            </li>
          ))}
        </ul>
      )}
      {catalogue.page > 1 || catalogue.more ? (
        <nav aria-label="Catalogue pages" className="kobo-filter">
          {catalogue.page > 1 ? (
            <Link to={route} params={{ accountId }} search={{ ...(sendable ? { filter: sendable } : {}), ...(catalogue.page > 2 ? { page: String(catalogue.page - 1) } : {}) }}>
              Previous
            </Link>
          ) : null}
          {catalogue.more ? (
            <Link to={route} params={{ accountId }} search={{ ...(sendable ? { filter: sendable } : {}), page: String(catalogue.page + 1) }}>
              Next
            </Link>
          ) : null}
        </nav>
      ) : null}
    </>
  );
}
