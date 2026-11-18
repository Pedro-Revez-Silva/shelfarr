import type { ReactNode } from "react";
import type { ApiError } from "../api/errors";
import { failureKind } from "../api/errors";

export function Loading({ label }: { label: string }) {
  return (
    <p className="state state--loading" role="status">
      <span className="spinner" aria-hidden="true" />
      {label}
    </p>
  );
}

export function BookGridSkeleton() {
  return (
    <ul className="book-grid book-grid--loading" aria-hidden="true">
      {Array.from({ length: 10 }, (_, index) => (
        <li key={index} className="skeleton-card">
          <span className="skeleton-cover" />
          <span className="skeleton-line" />
          <span className="skeleton-line skeleton-line--short" />
        </li>
      ))}
    </ul>
  );
}

const MESSAGES = {
  network: { title: "Can't reach your server", body: "Check your connection, then try again. Nothing was lost." },
  server: { title: "Your server had a problem", body: "It answered with an error. Try again in a moment." },
  contract: { title: "This page and the server disagree", body: "The server sent something this preview does not understand. Reload the page; if it persists, use the classic library." },
  invalid: { title: "That request was not accepted", body: "Change the search or filters and try again." },
  csrf: { title: "This page is out of date", body: "Reload the page to continue. Nothing was changed." },
  not_found: { title: "Not found", body: "This item is not in your library any more." },
  signed_out: { title: "Your session ended", body: "Sign in again to continue." },
  account_changed: { title: "The account changed", body: "Reload this page to continue." },
  unsupported: { title: "This server cannot show that yet", body: "This experimental server has not learned a format your library contains. Nothing was changed." },
  different_account: { title: "Different account", body: "This belongs to another account. Nothing was changed." },
  invalid_grant: { title: "That code is no longer valid", body: "It has expired or was already used. Start again in the app." },
  rate_limited: { title: "Too many attempts", body: "Wait a moment, then try again." },
  busy: { title: "The server is busy", body: "Try again in a moment. Nothing was changed." },
  conflict: { title: "Changed somewhere else", body: "Reload the page to see the latest details. Nothing was changed." },
} as const;

const UNSUPPORTED: Record<string, string> = {
  unsupported_asset_format: "A book in your library is a PDF or a comic-book (CBZ) file. This experimental server cannot list those yet.",
  unsupported_publication_kind: "Your library includes a comic record. This experimental server cannot list those yet.",
  unsupported_stored_value: "A stored value in your library is in a form this experimental server cannot read yet.",
  unsupported_library_layout: "Your library uses a folder layout (such as linked imports) this experimental server cannot read yet.",
  unsupported_reader_format: "This experimental server cannot show that format yet.",
  unsupported_reader_feature: "This experimental server cannot show that feature yet.",
};

export function ErrorPanel({ error, onRetry, children }: { error: unknown; onRetry?: () => void; children?: ReactNode }) {
  const kind = failureKind(error);
  const base = MESSAGES[kind];
  const code = (error as ApiError | undefined)?.code ?? null;
  const message = kind === "unsupported" && code && UNSUPPORTED[code] ? { ...base, body: `${UNSUPPORTED[code]} Nothing was changed.` } : base;
  const detail = (error as ApiError | undefined)?.status;
  return (
    <div className="state state--error" role="alert">
      <h2>{message.title}</h2>
      <p>{message.body}</p>
      {detail ? <p className="state-detail">Status {detail}</p> : null}
      <div className="state-actions">
        {onRetry ? (
          <button type="button" className="button" onClick={onRetry}>
            Try again
          </button>
        ) : null}
        {children}
      </div>
    </div>
  );
}

export function EmptyState({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="state state--empty">
      <span className="state-mark" aria-hidden="true">
        ✦
      </span>
      <h2>{title}</h2>
      {children}
    </div>
  );
}
