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
} as const;

export function ErrorPanel({ error, onRetry, children }: { error: unknown; onRetry?: () => void; children?: ReactNode }) {
  const message = MESSAGES[failureKind(error)];
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
