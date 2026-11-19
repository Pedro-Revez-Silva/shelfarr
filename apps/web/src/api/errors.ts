export type FailureKind =
  | "signed_out"
  | "account_changed"
  | "not_found"
  | "network"
  | "contract"
  | "invalid"
  | "csrf"
  | "server"
  | "unsupported"
  | "different_account"
  | "invalid_grant"
  | "rate_limited"
  | "busy"
  | "conflict";

export class ApiError extends Error {
  readonly kind: FailureKind;
  readonly status: number | null;
  readonly code: string | null;
  readonly retryAfterSeconds: number | null;

  constructor(kind: FailureKind, message: string, status: number | null = null, code: string | null = null, retryAfterSeconds: number | null = null) {
    super(message);
    this.name = "ApiError";
    this.kind = kind;
    this.status = status;
    this.code = code;
    this.retryAfterSeconds = retryAfterSeconds;
  }
}

export function isApiError(error: unknown): error is ApiError {
  return error instanceof ApiError;
}

export function failureKind(error: unknown): FailureKind {
  return isApiError(error) ? error.kind : "server";
}

export function isLockingFailure(kind: FailureKind): kind is "signed_out" | "account_changed" {
  return kind === "signed_out" || kind === "account_changed";
}

export function unconfirmed(error: unknown): boolean {
  const kind = failureKind(error);
  const status = isApiError(error) ? error.status : null;
  return kind === "network" || kind === "server" || kind === "busy" || (status !== null && status >= 200 && status < 300);
}
