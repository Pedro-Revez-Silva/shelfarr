import { useEffect, useId, useRef, useState, type FormEvent } from "react";
import { ApiError } from "../api/errors";
import { useDocumentTitle } from "../title";
import type { AuthClient, LoginResult } from "./auth";
import { AuthFrame } from "./AuthFrame";

export type LoginToken = { value: string; expiresAt: number };

type Props = {
  auth: AuthClient;
  token: LoginToken;
  availability: { available: boolean; reason: string | null };
  intro: string;
  notice: string | null;
  focusHeading: boolean;
  onSignedIn: (result: LoginResult) => void;
  onAlreadySignedIn: () => void;
  now?: () => number;
};

const REFRESH_MARGIN_MS = 5_000;

const UNAVAILABLE: Record<string, string> = {
  auth_disabled: "This server runs without sign-in. This experimental server cannot sign anyone in that way yet, so these screens are unavailable.",
  browser_origin_not_configured: "This experimental server has not been told its browser address, so sign-in is switched off. Ask whoever runs it to set it.",
};

const REFUSED: Record<string, string> = {
  mfa_not_supported: "This account uses two-step verification, which this experimental server cannot complete yet. Nothing was changed.",
  oidc_account_not_supported: "This account signs in through single sign-on, which this experimental server does not support yet. Nothing was changed.",
  auth_disabled: UNAVAILABLE["auth_disabled"] ?? "",
  browser_origin_not_configured: UNAVAILABLE["browser_origin_not_configured"] ?? "",
};

export function describeSignInFailure(error: unknown): { text: string; credentials: boolean } {
  if (!(error instanceof ApiError)) return { text: "Sign-in failed unexpectedly. Try again.", credentials: false };
  switch (error.kind) {
    case "invalid":
      return { text: "That username and password were not accepted. Check them and try again. After several failed attempts an account is locked for a while.", credentials: true };
    case "csrf":
      return { text: "This page was out of date, so it was refreshed. Your details are still here; sign in again.", credentials: false };
    case "rate_limited":
      return { text: `Too many sign-in attempts. Wait ${waitText(error.retryAfterSeconds)} and try again.`, credentials: false };
    case "busy":
      return { text: "The server is busy. Wait a moment and try again.", credentials: false };
    case "network":
      return { text: "Could not reach the server. Check your connection and try again; your details are still in the form.", credentials: false };
    case "unsupported":
      return { text: REFUSED[error.code ?? ""] ?? "This server cannot sign this account in yet. Nothing was changed.", credentials: false };
    case "not_found":
      return { text: "These screens are not switched on for this server or account.", credentials: false };
    default:
      return { text: "The server had a problem and did not sign you in. Try again in a moment.", credentials: false };
  }
}

function waitText(seconds: number | null): string {
  if (seconds === null) return "a moment";
  if (seconds < 90) return `${Math.max(seconds, 1)} seconds`;
  return `${Math.ceil(seconds / 60)} minutes`;
}

export function SignInPage({ auth, token, availability, intro, notice, focusHeading, onSignedIn, onAlreadySignedIn, now = Date.now }: Props) {
  useDocumentTitle("Sign in");
  const ids = { username: useId(), password: useId(), error: useId(), warning: useId() };
  const heading = useRef<HTMLHeadingElement>(null);
  const summary = useRef<HTMLDivElement>(null);
  const current = useRef(token);
  const submitting = useRef(false);
  const [pending, setPending] = useState(false);
  const [failure, setFailure] = useState<{ text: string; credentials: boolean } | null>(null);
  const [revealed, setRevealed] = useState(false);

  useEffect(() => {
    current.current = token;
  }, [token]);

  useEffect(() => {
    if (focusHeading) heading.current?.focus({ preventScroll: true });
  }, [focusHeading]);

  useEffect(() => {
    if (failure) summary.current?.focus();
  }, [failure]);

  async function freshToken(): Promise<string> {
    if (current.current.expiresAt - now() > REFRESH_MARGIN_MS) return current.current.value;
    const state = await auth.bootstrap();
    if (state.authenticated) {
      onAlreadySignedIn();
      throw new ApiError("invalid", "already signed in", 409, "already_signed_in");
    }
    current.current = { value: state.csrf_token, expiresAt: now() + state.expires_in * 1000 };
    return current.current.value;
  }

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (submitting.current) return;
    const form = new FormData(event.currentTarget);
    const username = form.get("username");
    const password = form.get("password");
    if (typeof username !== "string" || typeof password !== "string") return;
    submitting.current = true;
    setPending(true);
    setFailure(null);
    try {
      const value = await freshToken();
      onSignedIn(await auth.login(username, password, value));
    } catch (error) {
      if (error instanceof ApiError && error.code === "already_signed_in") {
        onAlreadySignedIn();
        return;
      }
      if (error instanceof ApiError && error.kind === "csrf") {
        try {
          const state = await auth.bootstrap();
          if (state.authenticated) {
            onAlreadySignedIn();
            return;
          }
          current.current = { value: state.csrf_token, expiresAt: now() + state.expires_in * 1000 };
        } catch {
          setFailure(describeSignInFailure(new ApiError("network", "")));
          return;
        }
      }
      setFailure(describeSignInFailure(error));
    } finally {
      submitting.current = false;
      setPending(false);
    }
  }

  const unavailable = !availability.available;
  const invalid = failure?.credentials === true;

  return (
    <AuthFrame>
      <section className="auth-card" aria-labelledby="sign-in-heading">
        <h1 id="sign-in-heading" ref={heading} tabIndex={-1}>
          Sign in
        </h1>
        <p className="lede">{intro}</p>
        {notice ? (
          <p className="notice" role="status">
            {notice}
          </p>
        ) : null}
        {unavailable ? (
          <p className="form-error" role="alert">
            {UNAVAILABLE[availability.reason ?? ""] ?? "Sign-in is not available on this server right now."}
          </p>
        ) : (
          <form className="auth-form" method="post" aria-labelledby="sign-in-heading" onSubmit={(event) => void submit(event)}>
            {failure ? (
              <div id={ids.error} className="form-error" role="alert" tabIndex={-1} ref={summary}>
                {failure.text}
              </div>
            ) : null}
            <div className="field">
              <label htmlFor={ids.username}>Username</label>
              <input
                id={ids.username}
                name="username"
                type="text"
                autoComplete="username"
                autoCapitalize="none"
                autoCorrect="off"
                spellCheck={false}
                enterKeyHint="next"
                required
                aria-invalid={invalid}
                aria-describedby={failure ? ids.error : undefined}
              />
            </div>
            <div className="field">
              <label htmlFor={ids.password}>Password</label>
              <div className="password-row">
                <input
                  id={ids.password}
                  name="password"
                  type={revealed ? "text" : "password"}
                  autoComplete="current-password"
                  autoCapitalize="none"
                  autoCorrect="off"
                  spellCheck={false}
                  enterKeyHint="done"
                  required
                  aria-invalid={invalid}
                  aria-describedby={failure ? ids.error : undefined}
                />
                <button
                  type="button"
                  className="button button--icon"
                  aria-pressed={revealed}
                  aria-label="Show password"
                  aria-describedby={ids.warning}
                  onClick={() => setRevealed((value) => !value)}
                >
                  <span aria-hidden="true">{revealed ? "Hide" : "Show"}</span>
                </button>
                <span id={ids.warning} className="sr-only">
                  Warning: this will display your password on the screen.
                </span>
              </div>
            </div>
            <button type="submit" className="button button--primary button--large" disabled={pending} aria-busy={pending}>
              {pending ? "Signing in…" : "Sign in"}
            </button>
          </form>
        )}
      </section>
    </AuthFrame>
  );
}
