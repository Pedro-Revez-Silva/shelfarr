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
import { accountEnvelopeSchema, accountRejectionSchema, type AccountEnvelope, type AccountRejection, type PasswordChange, type Profile } from "../contract";
import { connectDecisionSchema, connectInspectSchema, type ConnectDecision, type ConnectInspect } from "../contract";
import {
  progressConflictSchema,
  progressEnvelopeSchema,
  readerEnvelopeSchema,
  type ProgressRequest,
  type ReaderPublication,
  type StoredProgress,
} from "../contract";
import type { AccountGuard } from "./account-guard";
import { ApiError, type FailureKind } from "./errors";

export const ACCOUNT_HEADER = "X-Shelfarr-Account";

export type ApiDependencies = {
  boot: Boot;
  guard: AccountGuard;
  csrfToken: () => string | null;
  fetcher?: typeof fetch;
  requestVerification?: () => void;
  mutations?: MutationLifecycle;
};

export type MutationLifecycle = {
  prepare: (signal?: AbortSignal) => Promise<void>;
  rejected: () => void;
};

type RequestOptions<T> = {
  path: string;
  schema: z.ZodType<T>;
  signal?: AbortSignal | undefined;
  method?: "GET" | "PUT" | "POST";
  verifying?: boolean;
  body?: unknown;
  keepalive?: boolean;
  conflict?: z.ZodType<T>;
  rejection?: z.ZodType<T>;
  account: (value: T) => string;
};

export type ProgressAnswer = { kind: "saved"; progress: StoredProgress } | { kind: "conflict"; progress: StoredProgress | null };

export type AccountAnswer = { kind: "saved"; profile: Profile } | { kind: "rejected"; errors: Record<string, string[]> };

type ProgressBody = { account: string; error?: "progress_conflict"; progress: StoredProgress | null };

const FAILURE_BY_CODE: Record<string, FailureKind> = {
  signed_out: "signed_out",
  account_changed: "account_changed",
  not_found: "not_found",
  invalid_csrf: "csrf",
  invalid_request: "invalid",
  invalid_reading_status: "invalid",
  invalid_progress: "invalid",
  different_account: "different_account",
  invalid_grant: "invalid_grant",
  rate_limited: "rate_limited",
  server_busy: "busy",
  database_busy: "busy",
  request_timeout: "busy",
  account_conflict: "conflict",
};

export class ApiClient {
  private readonly deps: ApiDependencies;

  constructor(deps: ApiDependencies) {
    this.deps = deps;
  }

  session(signal?: AbortSignal, verifying = false): Promise<Session> {
    return this.request({ path: "/session", schema: sessionSchema, signal, verifying, account: (value) => value.account.id });
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

  async reader(id: string, signal?: AbortSignal): Promise<ReaderPublication> {
    const envelope = await this.request({ path: `/library/${encodeURIComponent(id)}/reader`, schema: readerEnvelopeSchema, signal, account: (value) => value.account });
    return envelope.publication;
  }

  async saveProgress(id: string, body: ProgressRequest, options: { signal?: AbortSignal; keepalive?: boolean } = {}): Promise<ProgressAnswer> {
    const answer = await this.request<ProgressBody>({
      path: `/library/${encodeURIComponent(id)}/progress`,
      schema: progressEnvelopeSchema,
      conflict: progressConflictSchema,
      method: "PUT",
      body,
      signal: options.signal,
      keepalive: options.keepalive ?? false,
      account: (value) => value.account,
    });
    if (answer.error === "progress_conflict") return { kind: "conflict", progress: answer.progress };
    if (!answer.progress) throw new ApiError("contract", "The server saved a place without returning it");
    return { kind: "saved", progress: answer.progress };
  }

  inspectConnection(code: string, signal?: AbortSignal): Promise<ConnectInspect> {
    const query = new URLSearchParams({ user_code: code });
    return this.request({ path: `/connect${suffix(query)}`, schema: connectInspectSchema, signal, account: (value) => value.account });
  }

  decideConnection(code: string, decision: "allow" | "deny", signal?: AbortSignal): Promise<ConnectDecision> {
    return this.request({
      path: "/connect",
      schema: connectDecisionSchema,
      method: "POST",
      body: { user_code: code, decision },
      signal,
      account: (value) => value.account,
    });
  }

  async account(signal?: AbortSignal): Promise<Profile> {
    const envelope = await this.request({ path: "/account", schema: accountEnvelopeSchema, signal, account: (value) => value.account });
    return envelope.profile;
  }

  updateProfile(name: string, signal?: AbortSignal): Promise<AccountAnswer> {
    return this.accountWrite("/account/profile", "PUT", { name }, signal);
  }

  changePassword(change: PasswordChange, signal?: AbortSignal): Promise<AccountAnswer> {
    return this.accountWrite("/account/password", "POST", change, signal);
  }

  private async accountWrite(path: string, method: "PUT" | "POST", body: unknown, signal: AbortSignal | undefined): Promise<AccountAnswer> {
    const answer = await this.request<AccountEnvelope | AccountRejection>({
      path,
      schema: accountEnvelopeSchema,
      rejection: accountRejectionSchema,
      method,
      body,
      signal,
      account: (value) => value.account,
    });
    return "profile" in answer ? { kind: "saved", profile: answer.profile } : { kind: "rejected", errors: answer.errors };
  }

  private async request<T>(options: RequestOptions<T>): Promise<T> {
    const { boot, guard } = this.deps;
    guard.assertActive();

    const headers: Record<string, string> = { Accept: "application/json", [ACCOUNT_HEADER]: guard.account };
    if (options.method === "PUT" || options.method === "POST") {
      headers["Content-Type"] = "application/json";
      await this.deps.mutations?.prepare(options.signal);
      guard.assertActive();
      const token = this.deps.csrfToken();
      if (token) headers["X-CSRF-Token"] = token;
    }

    let response: Response;
    try {
      const init: RequestInit = { method: options.method ?? "GET", headers, credentials: "same-origin", cache: "no-store", redirect: "error", referrerPolicy: "same-origin" };
      if (options.signal) init.signal = options.signal;
      if (options.keepalive) init.keepalive = true;
      if (options.body !== undefined) init.body = JSON.stringify(options.body);
      response = await (this.deps.fetcher ?? fetch)(`${boot.api}${options.path}`, init);
    } catch (error) {
      if (error instanceof DOMException && error.name === "AbortError") throw error;
      throw new ApiError("network", "The server could not be reached");
    }

    const payload = await readJson(response);

    const conflict = options.conflict !== undefined && response.status === 409;
    const rejected = options.rejection !== undefined && response.status === 422 && options.rejection.safeParse(payload).success;
    if (!response.ok && !conflict && !rejected) throw this.failure(response.status, payload, response, options.verifying ?? false);

    if (!options.verifying) {
      const trusted = await untilAborted(guard.untilSettled(), options.signal);
      guard.assertActive();
      if (!trusted) {
        this.deps.requestVerification?.();
        throw new ApiError("network", "The account could not be confirmed; try again");
      }
    }

    const parsed = (conflict && options.conflict ? options.conflict : rejected && options.rejection ? options.rejection : options.schema).safeParse(payload);
    if (!parsed.success) throw new ApiError("contract", "The server answered with an unexpected shape", response.status);
    if (options.account(parsed.data) !== guard.account) {
      if (!options.verifying) guard.lock("account_changed");
      throw new ApiError("account_changed", "The signed-in account changed", response.status);
    }
    return parsed.data;
  }

  private failure(status: number, payload: unknown, response: Response, verifying: boolean): ApiError {
    const envelope = errorEnvelopeSchema.safeParse(payload);
    const code = envelope.success ? envelope.data.error : null;
    const kind = code ? FAILURE_BY_CODE[code] : undefined;
    if (!verifying && (kind === "signed_out" || kind === "account_changed")) this.deps.guard.lock(kind);
    if (kind === "csrf") this.deps.mutations?.rejected();
    const retry = Number.parseInt(response.headers.get("retry-after") ?? "", 10);
    const retryAfter = Number.isFinite(retry) && retry >= 0 ? retry : null;
    if (kind) return new ApiError(kind, envelope.success ? (envelope.data.message ?? envelope.data.error) : "", status, code, retryAfter);
    if (code?.startsWith("unsupported_") || code === "not_implemented_in_go_runtime" || code === "confined_open_unsupported") return new ApiError("unsupported", `The server cannot show this yet (${code})`, status, code);
    return new ApiError(status >= 500 ? "server" : "contract", `The server answered ${status}`, status, code, retryAfter);
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
