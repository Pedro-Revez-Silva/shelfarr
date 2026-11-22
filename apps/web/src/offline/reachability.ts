import { ApiError } from "../api/errors";

export function serverUnreachable(error: unknown): boolean {
  if (!(error instanceof ApiError)) return false;
  return error.kind === "network" || error.status === 502 || error.status === 503 || error.status === 504;
}

export function definitiveRefusal(error: unknown): boolean {
  return error instanceof ApiError && typeof error.status === "number" && error.status >= 400 && error.status < 500;
}
