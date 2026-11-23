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
import { discoverSchema, type DiscoverAnswer } from "../contract";
import { requestEnvelopeSchema, requestListSchema, type RequestDetail, type RequestFilters, type RequestList } from "../contract";
import { acquisitionSchema, requestCreationSchema, selectionEnvelopeSchema, type Acquisition, type RequestCreation, type Selection } from "../contract";
import { serverOverviewSchema, type ServerOverview } from "../contract";
import { bookEnvelopeSchema, bookRequestOutcomeSchema, catalogueSchema, requestActionSchema, type Book, type BookAddress, type BookFormat, type BookRequestOutcome, type CatalogueAnswer } from "../contract";
import { metadataConflictSchema, metadataRejectionSchema, metadataSettingsSchema, type MetadataChange, type MetadataRejection, type MetadataSettings } from "../contract";
import { accountEnvelopeSchema, accountRejectionSchema, type AccountEnvelope, type AccountRejection, type PasswordChange, type Profile } from "../contract";
import { backupCodesSchema, createdTokenSchema, twoFactorSetupSchema, type CreatedToken, type RequestActionAnswer, type TwoFactorSetup } from "../contract";
import { connectDecisionSchema, connectInspectSchema, type ConnectDecision, type ConnectInspect } from "../contract";
import { notificationChangeSchema, notificationListSchema, type NotificationChange, type NotificationList } from "../contract";
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

export type ManualLink = { kind: "magnet" | "nzb"; url: string; replace_library_file: boolean };
export type RequestWithdrawal = { expected_revision: string; remove_client_jobs: boolean };
export type RequestCopyChoice = { result_id: string } | { result_id: string; expected_revision: string; replace_library_file: boolean };

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
  method?: "GET" | "PUT" | "POST" | "DELETE";
  verifying?: boolean;
  body?: unknown;
  form?: FormData;
  keepalive?: boolean;
  conflict?: z.ZodType<T>;
  rejection?: z.ZodType<T>;
  account: (value: T) => string;
};

export type ProgressAnswer = { kind: "saved"; progress: StoredProgress } | { kind: "conflict"; progress: StoredProgress | null };

export type MetadataAnswer = { kind: "saved"; settings: MetadataSettings } | { kind: "conflict"; settings: MetadataSettings } | { kind: "rejected"; errors: MetadataRejection["errors"] };

type MetadataBody = (MetadataSettings & { error?: "settings_conflict" }) | MetadataRejection;

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
  invalid_query: "invalid",
  search_rate_limited: "rate_limited",
  work_not_offered: "invalid",
  not_selectable: "conflict",
  copies_changed: "conflict",
  replacement_unconfirmed: "conflict",
  acquisition_busy: "conflict",
  search_blocked: "conflict",
  cannot_cancel: "conflict",
  request_rejected: "invalid",
  search_unavailable: "busy",
  cannot_retry: "conflict",
  cannot_remove: "conflict",
  request_changed: "conflict",
  manual_rejected: "invalid",
  invalid_code: "invalid",
  invalid_password: "invalid",
  invalid_scopes: "invalid",
  invalid_token: "invalid",
  two_factor_enabled: "conflict",
  two_factor_disabled: "conflict",
  two_factor_not_started: "conflict",
  oidc_not_linked: "conflict",
  uploads_disabled: "conflict",
  upload_closed: "conflict",
  upload_rejected: "invalid",
  upload_refused: "conflict",
  match_rejected: "invalid",
  match_unavailable: "conflict",
  reader_not_found: "not_found",
  book_not_found: "not_found",
  kobo_send_refused: "invalid",
  connection_address_saved: "invalid",
  kobo_account_not_found: "not_found",
  kobo_book_not_found: "not_found",
  catalogue_not_found: "not_found",
  kobo_limit_reached: "conflict",
  kobo_account_removed: "conflict",
  invalid_kobo_account: "invalid",
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

  discover(query: string | null, signal?: AbortSignal): Promise<DiscoverAnswer> {
    const params = new URLSearchParams();
    if (query !== null) params.set("q", query);
    return this.request({ path: `/discover${suffix(params)}`, schema: discoverSchema, signal, account: (value) => value.account });
  }

  requests(filters: RequestFilters, signal?: AbortSignal): Promise<RequestList> {
    const params = new URLSearchParams();
    if (filters.status) params.set("status", filters.status);
    if (filters.attention) params.set("attention", filters.attention);
    if (filters.q) params.set("q", filters.q);
    if (filters.page) params.set("page", filters.page);
    return this.request({ path: `/requests${suffix(params)}`, schema: requestListSchema, signal, account: (value) => value.account });
  }

  async requestDetail(id: string, signal?: AbortSignal): Promise<RequestDetail> {
    const envelope = await this.request({ path: `/requests/${encodeURIComponent(id)}`, schema: requestEnvelopeSchema, signal, account: (value) => value.account });
    return envelope.request;
  }

  requestEbook(workId: string, signal?: AbortSignal): Promise<RequestCreation> {
    return this.request({ path: "/requests", schema: requestCreationSchema, method: "POST", body: { work_id: workId, book_type: "ebook" }, signal, account: (value) => value.account });
  }

  acquisition(id: string, signal?: AbortSignal): Promise<Acquisition> {
    return this.request({ path: `/requests/${encodeURIComponent(id)}/acquisition`, schema: acquisitionSchema, signal, account: (value) => value.account });
  }

  async selectResult(id: string, resultId: string, signal?: AbortSignal): Promise<Selection> {
    const envelope = await this.request({
      path: `/requests/${encodeURIComponent(id)}/selection`,
      schema: selectionEnvelopeSchema,
      method: "POST",
      body: { result_id: resultId },
      signal,
      account: (value) => value.account,
    });
    return envelope.selection;
  }

  catalogue(query: string, signal?: AbortSignal): Promise<CatalogueAnswer> {
    return this.request({ path: `/discover${suffix(new URLSearchParams({ q: query }))}`, schema: catalogueSchema, signal, account: (value) => value.account });
  }

  async book(address: BookLocation, signal?: AbortSignal): Promise<Book> {
    const envelope = await this.request({ path: `${bookPath(address)}${suffix(bookQuery(address))}`, schema: bookEnvelopeSchema, signal, account: (value) => value.account });
    return envelope.book;
  }

  requestBook(address: BookLocation, choice: RequestChoice, signal?: AbortSignal): Promise<BookRequestOutcome> {
    const body = { book_type: choice.format, ...(choice.language ? { language: choice.language } : {}), ...(choice.notes ? { notes: choice.notes } : {}) };
    return this.request({ path: `${bookPath(address)}/requests${suffix(bookQuery(address))}`, schema: bookRequestOutcomeSchema, method: "POST", body, signal, account: (value) => value.account });
  }

  chooseCopy(requestId: string, resultId: string, signal?: AbortSignal): Promise<unknown> {
    return this.requestAction(`/requests/${encodeURIComponent(requestId)}/selection`, { result_id: resultId }, signal);
  }

  chooseRequestCopy(requestId: string, choice: RequestCopyChoice, signal?: AbortSignal): Promise<RequestActionAnswer> {
    return this.requestAction(`/requests/${encodeURIComponent(requestId)}/selection`, choice, signal);
  }

  searchAgain(requestId: string, signal?: AbortSignal): Promise<unknown> {
    return this.requestAction(`/requests/${encodeURIComponent(requestId)}/search`, {}, signal);
  }

  cancelRequest(requestId: string, signal?: AbortSignal): Promise<unknown> {
    return this.requestAction(`/requests/${encodeURIComponent(requestId)}/cancel`, {}, signal);
  }

  retryRequest(requestId: string, signal?: AbortSignal): Promise<RequestActionAnswer> {
    return this.requestAction(`/requests/${encodeURIComponent(requestId)}/retry`, {}, signal);
  }

  removeRequest(requestId: string, signal?: AbortSignal): Promise<RequestActionAnswer> {
    return this.requestAction(`/requests/${encodeURIComponent(requestId)}/remove`, {}, signal);
  }

  withdrawRequest(requestId: string, withdrawal: RequestWithdrawal, signal?: AbortSignal): Promise<RequestActionAnswer> {
    return this.requestAction(`/requests/${encodeURIComponent(requestId)}/withdraw`, withdrawal, signal);
  }

  addManualLink(requestId: string, link: ManualLink, signal?: AbortSignal): Promise<RequestActionAnswer> {
    const body = link.kind === "magnet" ? { kind: "magnet", magnet_url: link.url } : { kind: "nzb", nzb_url: link.url };
    return this.requestAction(`/requests/${encodeURIComponent(requestId)}/manual`, { ...body, replace_library_file: link.replace_library_file }, signal);
  }

  private requestAction(path: string, body: unknown, signal: AbortSignal | undefined): Promise<RequestActionAnswer> {
    return this.request({ path, schema: requestActionSchema, method: "POST", body, signal, account: (value) => value.account });
  }

  notifications(signal?: AbortSignal): Promise<NotificationList> {
    return this.request({ path: "/notifications", schema: notificationListSchema, signal, account: (value) => value.account });
  }

  markNotificationRead(id: string, signal?: AbortSignal): Promise<NotificationChange> {
    return this.notificationChange(`/notifications/${encodeURIComponent(id)}/read`, {}, signal);
  }

  markNotificationsRead(through: string, signal?: AbortSignal): Promise<NotificationChange> {
    return this.notificationChange("/notifications/read", { through }, signal);
  }

  clearNotifications(through: string, signal?: AbortSignal): Promise<NotificationChange> {
    return this.notificationChange("/notifications/clear", { through }, signal);
  }

  private notificationChange(path: string, body: unknown, signal: AbortSignal | undefined): Promise<NotificationChange> {
    return this.request({ path, schema: notificationChangeSchema, method: "POST", body, signal, account: (value) => value.account });
  }

  serverOverview(signal?: AbortSignal): Promise<ServerOverview> {
    return this.request({ path: "/admin/overview", schema: serverOverviewSchema, signal, account: (value) => value.account });
  }

  metadataSettings(signal?: AbortSignal): Promise<MetadataSettings> {
    return this.request({ path: "/admin/settings/metadata", schema: metadataSettingsSchema, signal, account: (value) => value.account });
  }

  async saveMetadataSettings(revision: string, change: MetadataChange, signal?: AbortSignal): Promise<MetadataAnswer> {
    const answer = await this.request<MetadataBody>({
      path: "/admin/settings/metadata",
      schema: metadataSettingsSchema,
      conflict: metadataConflictSchema,
      rejection: metadataRejectionSchema,
      method: "PUT",
      body: { revision, open_library: change },
      signal,
      account: (value) => value.account,
    });
    if (answer.error === "invalid_settings") return { kind: "rejected", errors: answer.errors };
    const { error, ...settings } = answer;
    return error === "settings_conflict" ? { kind: "conflict", settings } : { kind: "saved", settings };
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

  async startTwoFactor(signal?: AbortSignal): Promise<TwoFactorSetup> {
    const answer = await this.request({ path: "/account/two_factor/setup", schema: twoFactorSetupSchema, method: "POST", body: {}, signal, account: (value) => value.account });
    return answer.setup;
  }

  async enableTwoFactor(code: string, signal?: AbortSignal): Promise<string[]> {
    const answer = await this.request({ path: "/account/two_factor/enable", schema: backupCodesSchema, method: "POST", body: { otp_code: code }, signal, account: (value) => value.account });
    return answer.backup_codes;
  }

  async newBackupCodes(password: string, signal?: AbortSignal): Promise<string[]> {
    const answer = await this.request({ path: "/account/two_factor/backup_codes", schema: backupCodesSchema, method: "POST", body: { password }, signal, account: (value) => value.account });
    return answer.backup_codes;
  }

  disableTwoFactor(password: string, signal?: AbortSignal): Promise<Profile> {
    return this.profileAction("/account/two_factor/disable", { password }, signal);
  }

  createApiToken(name: string, scopes: string[], signal?: AbortSignal): Promise<CreatedToken> {
    return this.request({ path: "/account/api_tokens", schema: createdTokenSchema, method: "POST", body: { name, scopes }, signal, account: (value) => value.account });
  }

  revokeApiToken(id: string, signal?: AbortSignal): Promise<Profile> {
    return this.profileAction(`/account/api_tokens/${encodeURIComponent(id)}/revoke`, {}, signal);
  }

  unlinkSingleSignOn(currentPassword: string, signal?: AbortSignal): Promise<Profile> {
    return this.profileAction("/account/oidc/unlink", { current_password: currentPassword }, signal);
  }

  private async profileAction(path: string, body: unknown, signal: AbortSignal | undefined): Promise<Profile> {
    const envelope = await this.request({ path, schema: accountEnvelopeSchema, method: "POST", body, signal, account: (value) => value.account });
    return envelope.profile;
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

  async request<T>(options: RequestOptions<T>): Promise<T> {
    const { boot, guard } = this.deps;
    guard.assertActive();

    const headers: Record<string, string> = { Accept: "application/json", [ACCOUNT_HEADER]: guard.account };
    if (options.method === "PUT" || options.method === "POST" || options.method === "DELETE") {
      if (options.form === undefined) headers["Content-Type"] = "application/json";
      await this.deps.mutations?.prepare(options.signal);
      guard.assertActive();
      const token = this.deps.csrfToken();
      if (token) headers["X-CSRF-Token"] = token;
    }

    let response: Response;
    const askedAt = Date.now();
    try {
      const init: RequestInit = { method: options.method ?? "GET", headers, credentials: "same-origin", cache: "no-store", redirect: "error", referrerPolicy: "same-origin" };
      if (options.signal) init.signal = options.signal;
      if (options.keepalive) init.keepalive = true;
      if (options.form !== undefined) init.body = options.form;
      else if (options.body !== undefined) init.body = JSON.stringify(options.body);
      response = await (this.deps.fetcher ?? fetch)(`${boot.api}${options.path}`, init);
    } catch (error) {
      if (error instanceof DOMException && error.name === "AbortError") throw error;
      throw new ApiError("network", "The server could not be reached");
    }

    const payload = await readJson(response);

    const conflict = options.conflict !== undefined && response.status === 409;
    const rejected = options.rejection !== undefined && response.status === 422 && options.rejection.safeParse(payload).success;
    if (!response.ok && !conflict && !rejected) throw this.failure(response.status, payload, response, options.verifying ?? false, askedAt);

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
      if (!options.verifying) guard.lock("account_changed", askedAt);
      throw new ApiError("account_changed", "The signed-in account changed", response.status);
    }
    return parsed.data;
  }

  private failure(status: number, payload: unknown, response: Response, verifying: boolean, askedAt: number): ApiError {
    const envelope = errorEnvelopeSchema.safeParse(payload);
    const code = envelope.success ? envelope.data.error : null;
    const kind = code ? FAILURE_BY_CODE[code] : undefined;
    if (!verifying && (kind === "signed_out" || kind === "account_changed")) this.deps.guard.lock(kind, askedAt);
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

export type BookLocation = BookAddress & { metadata?: string | undefined };
export type RequestChoice = { format: BookFormat["book_type"] | "both"; language?: string | undefined; notes?: string | undefined };

function bookPath(address: BookLocation): string {
  return `/books/${encodeURIComponent(address.source)}/${encodeURIComponent(address.id)}`;
}

function bookQuery(address: BookLocation): URLSearchParams {
  const query = new URLSearchParams();
  if (address.metadata) query.set("metadata", address.metadata);
  return query;
}

function suffix(query: URLSearchParams): string {
  const text = query.toString();
  return text ? `?${text}` : "";
}
