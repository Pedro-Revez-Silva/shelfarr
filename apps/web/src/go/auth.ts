import { bootstrapSchema, errorEnvelopeSchema, type Bootstrap } from "../contract";
import { z } from "zod";
import type { AccountGuard } from "../api/account-guard";
import type { MutationLifecycle } from "../api/client";
import { ACCOUNT_HEADER } from "../api/client";
import { ApiError, type FailureKind } from "../api/errors";

const CSRF_HEADER = "X-CSRF-Token";
const REFRESH_MARGIN_MS = 60_000;

const loginResultSchema = z.object({ authenticated: z.literal(true), account: z.string().regex(/^[1-9]\d{0,18}$/), csrf_token: z.string().min(1), expires_in: z.number().int().nonnegative() });
export type LoginResult = z.infer<typeof loginResultSchema>;

const KIND_BY_CODE: Record<string, FailureKind> = {
  invalid_csrf: "csrf",
  rate_limited: "rate_limited",
  server_busy: "busy",
  database_busy: "busy",
  request_timeout: "busy",
  not_found: "not_found",
  signed_out: "signed_out",
  account_changed: "account_changed",
  invalid_credentials: "invalid",
  already_signed_in: "invalid",
  invalid_json: "invalid",
};

export class AuthClient {
  private readonly api: string;
  private readonly fetcher: typeof fetch | undefined;

  constructor(api: string, fetcher?: typeof fetch) {
    this.api = api;
    this.fetcher = fetcher;
  }

  async bootstrap(signal?: AbortSignal): Promise<Bootstrap> {
    const payload = await this.send("GET", "/auth/bootstrap", {}, undefined, signal);
    const parsed = bootstrapSchema.safeParse(payload);
    if (!parsed.success) throw new ApiError("contract", "The server answered with an unexpected shape");
    return parsed.data;
  }

  async login(username: string, password: string, csrf: string, signal?: AbortSignal): Promise<LoginResult> {
    const payload = await this.send("POST", "/auth/login", { [CSRF_HEADER]: csrf }, { username, password }, signal);
    const parsed = loginResultSchema.safeParse(payload);
    if (!parsed.success) throw new ApiError("contract", "The server answered with an unexpected shape");
    return parsed.data;
  }

  async logout(account: string, csrf: string, signal?: AbortSignal): Promise<void> {
    await this.send("POST", "/auth/logout", { [CSRF_HEADER]: csrf, [ACCOUNT_HEADER]: account }, {}, signal);
  }

  private async send(method: "GET" | "POST", path: string, headers: Record<string, string>, body: unknown, signal?: AbortSignal): Promise<unknown> {
    const init: RequestInit = {
      method,
      headers: { Accept: "application/json", ...(body === undefined ? {} : { "Content-Type": "application/json" }), ...headers },
      credentials: "same-origin",
      cache: "no-store",
      redirect: "error",
      referrerPolicy: "same-origin",
    };
    if (signal) init.signal = signal;
    if (body !== undefined) init.body = JSON.stringify(body);
    let response: Response;
    try {
      response = await (this.fetcher ?? fetch)(`${this.api}${path}`, init);
    } catch (error) {
      if (error instanceof DOMException && error.name === "AbortError") throw error;
      throw new ApiError("network", "The server could not be reached");
    }
    const payload = await readJson(response);
    if (!response.ok) throw failure(response, payload);
    return payload;
  }
}

function failure(response: Response, payload: unknown): ApiError {
  const envelope = errorEnvelopeSchema.safeParse(payload);
  const detail = z.object({ reason: z.string().optional() }).safeParse(payload);
  const code = envelope.success ? envelope.data.error : null;
  const reason = detail.success ? (detail.data.reason ?? null) : null;
  const retry = Number.parseInt(response.headers.get("retry-after") ?? "", 10);
  const retryAfter = Number.isFinite(retry) && retry >= 0 ? retry : null;
  if (response.status === 501 && code) return new ApiError("unsupported", `Sign-in is not supported (${code})`, response.status, reason ?? code, null);
  const kind = code ? KIND_BY_CODE[code] : undefined;
  if (kind) return new ApiError(kind, code ?? "", response.status, code, retryAfter);
  return new ApiError(response.status >= 500 ? "server" : "contract", `The server answered ${response.status}`, response.status, code, retryAfter);
}

async function readJson(response: Response): Promise<unknown> {
  if (!(response.headers.get("content-type") ?? "").includes("json")) return null;
  try {
    return await response.json();
  } catch {
    return null;
  }
}

export class CsrfSession {
  private value: string;
  private expiresAt: number;
  private pending: Promise<void> | null = null;
  private readonly auth: AuthClient;
  private readonly guard: AccountGuard;
  private readonly now: () => number;

  constructor(auth: AuthClient, guard: AccountGuard, token: string, expiresInSeconds: number, now: () => number = Date.now) {
    this.auth = auth;
    this.guard = guard;
    this.now = now;
    this.value = token;
    this.expiresAt = now() + expiresInSeconds * 1000;
  }

  token = (): string | null => (this.now() < this.expiresAt ? this.value : null);

  needsRefresh(): boolean {
    return this.now() + REFRESH_MARGIN_MS >= this.expiresAt;
  }

  refresh(signal?: AbortSignal): Promise<void> {
    if (!this.pending) {
      this.pending = this.fetchFresh(signal).finally(() => {
        this.pending = null;
      });
    }
    return this.pending;
  }

  private async fetchFresh(signal?: AbortSignal): Promise<void> {
    let state: Bootstrap;
    try {
      state = await this.auth.bootstrap(signal);
    } catch (error) {
      if (error instanceof DOMException && error.name === "AbortError") throw error;
      return;
    }
    if (!this.guard.isActive()) return;
    if (!state.authenticated) {
      this.guard.lock("signed_out");
      return;
    }
    if (state.account !== this.guard.account) {
      this.guard.lock("account_changed");
      return;
    }
    this.value = state.csrf_token;
    this.expiresAt = this.now() + state.expires_in * 1000;
  }

  lifecycle: MutationLifecycle = {
    prepare: async (signal) => {
      if (this.needsRefresh()) await this.refresh(signal);
    },
    rejected: () => {
      void this.refresh();
    },
  };
}
