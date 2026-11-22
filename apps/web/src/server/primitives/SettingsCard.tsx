import type { ReactNode } from "react";

export function SettingsCard({ id, headingId, title, summary, status, children }: { id: string; headingId: string; title: string; summary?: string; status?: ReactNode; children: ReactNode }) {
  return (
    <section id={id} className="settings-card" aria-labelledby={headingId} tabIndex={-1}>
      <header className="settings-card-header">
        <h3 id={headingId}>{title}</h3>
        {status}
        {summary ? <p className="settings-card-summary">{summary}</p> : null}
      </header>
      {children}
    </section>
  );
}

export function CardActions({ children, unsaved }: { children: ReactNode; unsaved: boolean }) {
  return (
    <div className="settings-card-actions">
      {children}
      {unsaved ? (
        <p className="unsaved-note">
          <span aria-hidden="true">● </span>Unsaved changes
        </p>
      ) : null}
    </div>
  );
}

export function AdvancedSection({ count, changed, open, onToggle, children }: { count: number; changed: number; open: boolean; onToggle: (open: boolean) => void; children: ReactNode }) {
  if (count === 0) return null;
  return (
    <details className="settings-advanced" open={open} onToggle={(event) => onToggle(event.currentTarget.open)}>
      <summary>
        Advanced
        {changed > 0 ? <span className="settings-advanced-count"> · {changed} changed</span> : null}
      </summary>
      <div className="settings-advanced-body">{children}</div>
    </details>
  );
}
