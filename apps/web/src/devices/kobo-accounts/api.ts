import type { ApiClient } from "../../api/client";
import {
  koboAccountDisconnectedSchema,
  koboAccountEnvelopeSchema,
  koboAccountRefusalSchema,
  koboAccountsSchema,
  koboBookEnvelopeSchema,
  koboBookRefusalSchema,
  koboCatalogueSchema,
  type CatalogueSearch,
  type KoboAccount,
  type KoboAccountDisconnected,
  type KoboAccountEnvelope,
  type KoboAccountRefusal,
  type KoboAccounts,
  type KoboBook,
  type KoboBookEnvelope,
  type KoboBookRefusal,
  type KoboCatalogue,
} from "./contract";

export type AccountAnswer = { kind: "done"; kobo_account: KoboAccount; notice: string | null } | { kind: "refused"; kobo_account: KoboAccount; message: string; changed: boolean };
export type DisconnectAnswer = { kind: "disconnected"; notice: string } | { kind: "refused"; kobo_account: KoboAccount; message: string; changed: boolean };
export type BookAnswer = { kind: "done"; book: KoboBook; notice: string | null } | { kind: "refused"; book: KoboBook; message: string; changed: boolean };

const account = (value: { account: string }) => value.account;
const accountPath = (id: string) => `/account/kobo_accounts/${encodeURIComponent(id)}`;
const bookPath = (id: string) => `/kobo_books/${encodeURIComponent(id)}`;

export function accounts(api: ApiClient, signal?: AbortSignal): Promise<KoboAccounts> {
  return api.request({ path: "/account/kobo_accounts", schema: koboAccountsSchema, signal, account });
}

export async function koboAccount(api: ApiClient, id: string, signal?: AbortSignal): Promise<KoboAccount> {
  return (await api.request({ path: accountPath(id), schema: koboAccountEnvelopeSchema, signal, account })).kobo_account;
}

export async function connect(api: ApiClient, name: string): Promise<KoboAccount> {
  return (await api.request({ path: "/account/kobo_accounts", schema: koboAccountEnvelopeSchema, method: "POST", body: { name }, account })).kobo_account;
}

export async function poll(api: ApiClient, id: string, signal?: AbortSignal): Promise<KoboAccount> {
  return (await api.request({ path: `${accountPath(id)}/poll`, schema: koboAccountEnvelopeSchema, method: "POST", body: {}, signal, account })).kobo_account;
}

async function accountWrite(api: ApiClient, path: string, body: unknown): Promise<AccountAnswer> {
  const answer = await api.request<KoboAccountEnvelope | KoboAccountRefusal>({ path, schema: koboAccountEnvelopeSchema, conflict: koboAccountRefusalSchema, rejection: koboAccountRefusalSchema, method: "POST", body, account });
  if ("error" in answer) return { kind: "refused", kobo_account: answer.kobo_account, message: answer.message, changed: answer.error === "kobo_account_changed" };
  return { kind: "done", kobo_account: answer.kobo_account, notice: answer.notice ?? null };
}

export function refresh(api: ApiClient, id: string): Promise<AccountAnswer> {
  return accountWrite(api, `${accountPath(id)}/refresh`, {});
}

export function share(api: ApiClient, id: string, recipientId: string): Promise<AccountAnswer> {
  return accountWrite(api, `${accountPath(id)}/shares`, { recipient_id: recipientId });
}

export function stopSharing(api: ApiClient, id: string, shareId: string): Promise<AccountAnswer> {
  return accountWrite(api, `${accountPath(id)}/shares/${encodeURIComponent(shareId)}/remove`, {});
}

export async function disconnect(api: ApiClient, id: string, version: string): Promise<DisconnectAnswer> {
  const answer = await api.request<KoboAccountDisconnected | KoboAccountRefusal>({
    path: `${accountPath(id)}/disconnect`,
    schema: koboAccountDisconnectedSchema,
    conflict: koboAccountRefusalSchema,
    method: "POST",
    body: { version },
    account,
  });
  if ("error" in answer) return { kind: "refused", kobo_account: answer.kobo_account, message: answer.message, changed: true };
  return { kind: "disconnected", notice: answer.notice };
}

export async function catalogue(api: ApiClient, id: string, search: CatalogueSearch, signal?: AbortSignal): Promise<KoboCatalogue> {
  const query = new URLSearchParams();
  if (search.filter) query.set("filter", search.filter);
  if (search.page) query.set("page", search.page);
  const suffix = query.size ? `?${query.toString()}` : "";
  return (await api.request({ path: `/kobo_catalogues/${encodeURIComponent(id)}${suffix}`, schema: koboCatalogueSchema, signal, account })).catalogue;
}

export async function book(api: ApiClient, id: string, signal?: AbortSignal): Promise<KoboBook> {
  return (await api.request({ path: bookPath(id), schema: koboBookEnvelopeSchema, signal, account })).book;
}

async function bookWrite(api: ApiClient, path: string, body: unknown): Promise<BookAnswer> {
  const answer = await api.request<KoboBookEnvelope | KoboBookRefusal>({ path, schema: koboBookEnvelopeSchema, conflict: koboBookRefusalSchema, rejection: koboBookRefusalSchema, method: "POST", body, account });
  if ("error" in answer) return { kind: "refused", book: answer.book, message: answer.message, changed: answer.error === "copy_changed" };
  return { kind: "done", book: answer.book, notice: answer.notice ?? null };
}

export function prepare(api: ApiClient, id: string, copy: string | null): Promise<BookAnswer> {
  return bookWrite(api, `${bookPath(id)}/prepare`, { copy });
}

export function deliver(api: ApiClient, id: string, readerId: string, copy: string | null): Promise<BookAnswer> {
  return bookWrite(api, `${bookPath(id)}/deliver`, { reader_id: readerId, copy });
}
