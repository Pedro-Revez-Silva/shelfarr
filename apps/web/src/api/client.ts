import type { z } from "zod";
import {
  continueSchema,
  errorEnvelopeSchema,
  librarySchema,
  publicationEnvelopeSchema,
  sessionSchema,
  type Boot,
  type ContinueShelf,
  type LibraryFilters,
  type LibraryPage,
  type PublicationDetail,
  type ReadingStatus,
  type Session,
} from "../contract";
import type { AccountGuard } from "./account-guard";
import { ApiError, type FailureKind } from "./errors";

export const ACCOUNT_HEADER = "X-Shelfarr-Account";

export type ApiDependencies = {
  boot: Boot;
  guard: AccountGuard;
  csrfToken: () => string | null;
  fetcher?: typeof fetch;
};

type RequestOptions<T> = {
  path: string;
  schema: z.ZodType<T>;
  signal?: AbortSignal | undefined;
  method?: "GET" | "PUT";
  validatesAccount?: boolean;
  body?: unknown;
  account: (value: T) => string;
};

const FAILURE_BY_CODE: Record<string, FailureKind> = {
  signed_out: "signed_out",
  account_changed: "account_changed",
  not_found: "not_found",
  invalid_csrf: "csrf",
  invalid_request: "invalid",
  invalid_reading_status: "invalid",
};

export class ApiClient {
  private readonly deps: ApiDependencies;

  constructor(deps: ApiDependencies) {
    this.deps = deps;
  }

  session(signal?: AbortSignal): Promise<Session> {
    return this.request({ path: "/session", schema: sessionSchema, signal, validatesAccount: true, account: (value) => value.account.id });
  }

  library(filters: LibraryFilters, cursor: string | undefined, signal?: AbortSignal): Promise<LibraryPage> {
    const query = new URLSearchParams();
    if (filters.q) query.set("q", filters.q);
    if (filters.type) query.set("type", filters.type);
    if (filters.status) query.set("status", filters.status);
    if (filters.sort) query.set("sort", filters.sort);
    if (cursor) query.set("cursor", cursor);
    return this.request({ path: `/library${suffix(query)}`, schema: librarySchema, signal, account: (value) => value.account });
  }

  continueReading(filters: LibraryFilters, signal?: AbortSignal): Promise<ContinueShelf> {
    const query = new URLSearchParams();
    if (filters.type) query.set("type", filters.type);
    return this.request({ path: `/continue${suffix(query)}`, schema: continueSchema, signal, account: (value) => value.account });
  }

  async publication(id: string, signal?: AbortSignal): Promise<PublicationDetail> {
    const envelope = await this.request({
      path: `/library/${encodeURIComponent(id)}`,
      schema: publicationEnvelopeSchema,
      signal,
      account: (value) => value.account,
    });
    return envelope.publication;
  }

  async setReadingStatus(id: string, status: ReadingStatus, signal?: AbortSignal): Promise<PublicationDetail> {
    const envelope = await this.request({
      path: `/library/${encodeURIComponent(id)}/reading_status`,
      schema: publicationEnvelopeSchema,
      method: "PUT",
      body: { status },
      signal,
      account: (value) => value.account,
    });
    return envelope.publication;
  }

  private async request<T>(options: RequestOptions<T>): Promise<T> {
    const { boot, guard } = this.deps;
    guard.assertActive();

    const headers: Record<string, string> = { Accept: "application/json", [ACCOUNT_HEADER]: guard.account };
    if (options.method === "PUT") {
      headers["Content-Type"] = "application/json";
      const token = this.deps.csrfToken();
      if (token) headers["X-CSRF-Token"] = token;
    }

    let response: Response;
    try {
      const init: RequestInit = { method: options.method ?? "GET", headers, credentials: "same-origin", cache: "no-store", redirect: "error", referrerPolicy: "same-origin" };
      if (options.signal) init.signal = options.signal;
      if (options.body !== undefined) init.body = JSON.stringify(options.body);
      response = await (this.deps.fetcher ?? fetch)(`${boot.api}${options.path}`, init);
    } catch (error) {
      if (error instanceof DOMException && error.name === "AbortError") throw error;
      throw new ApiError("network", "The server could not be reached");
    }

    const payload = await readJson(response);
    guard.assertActive();

    if (!response.ok) throw this.failure(response.status, payload);

    if (!options.validatesAccount) {
      const confirmed = await untilAborted(guard.confirmed(), options.signal);
      guard.assertActive();
      if (!confirmed) throw new ApiError("network", "The account could not be confirmed; try again");
    }

    const parsed = options.schema.safeParse(payload);
    if (!parsed.success) throw new ApiError("contract", "The server answered with an unexpected shape", response.status);
    if (options.account(parsed.data) !== guard.account) {
      guard.lock("account_changed");
      throw new ApiError("account_changed", "The signed-in account changed", response.status);
    }
    return parsed.data;
  }

  private failure(status: number, payload: unknown): ApiError {
    const envelope = errorEnvelopeSchema.safeParse(payload);
    const kind = envelope.success ? FAILURE_BY_CODE[envelope.data.error] : undefined;
    if (kind === "signed_out" || kind === "account_changed") this.deps.guard.lock(kind);
    if (kind) return new ApiError(kind, envelope.success ? (envelope.data.message ?? envelope.data.error) : "", status);
    return new ApiError(status >= 500 ? "server" : "contract", `The server answered ${status}`, status);
  }
}

function untilAborted<T>(promise: Promise<T>, signal: AbortSignal | undefined): Promise<T> {
  if (!signal) return promise;
  if (signal.aborted) return Promise.reject(new DOMException("Aborted", "AbortError"));
  return new Promise<T>((resolve, reject) => {
    const onAbort = () => reject(new DOMException("Aborted", "AbortError"));
    signal.addEventListener("abort", onAbort, { once: true });
    promise.then(
      (value) => {
        signal.removeEventListener("abort", onAbort);
        resolve(value);
      },
      (error: unknown) => {
        signal.removeEventListener("abort", onAbort);
        reject(error);
      },
    );
  });
}

async function readJson(response: Response): Promise<unknown> {
  const type = response.headers.get("content-type") ?? "";
  if (!type.includes("json")) return null;
  try {
    return await response.json();
  } catch {
    return null;
  }
}

function suffix(query: URLSearchParams): string {
  const text = query.toString();
  return text ? `?${text}` : "";
}
