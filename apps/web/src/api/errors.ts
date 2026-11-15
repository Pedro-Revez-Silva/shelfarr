export type FailureKind = "signed_out" | "account_changed" | "not_found" | "network" | "contract" | "invalid" | "csrf" | "server";

export class ApiError extends Error {
  readonly kind: FailureKind;
  readonly status: number | null;

  constructor(kind: FailureKind, message: string, status: number | null = null) {
    super(message);
    this.name = "ApiError";
    this.kind = kind;
    this.status = status;
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
