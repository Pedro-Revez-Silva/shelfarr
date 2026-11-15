import type { ReactNode } from "react";

export function AuthFrame({ children }: { children: ReactNode }) {
  return (
    <div className="auth-shell">
      <header className="auth-header">
        <span className="wordmark">
          <svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" aria-hidden="true" focusable="false">
            <path d="M4 4h5v16H4zM10 7h4v13h-4zM16 4l4-1 3 16-4 1z" />
          </svg>
          shelfarr
        </span>
        <span className="preview-badge">Experimental server</span>
      </header>
      <main id="main" className="auth-main">
        {children}
      </main>
    </div>
  );
}
