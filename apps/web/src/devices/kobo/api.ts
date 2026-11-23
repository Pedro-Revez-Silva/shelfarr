import type { ApiClient } from "../../api/client";
import {
  bookKoboSchema,
  koboChangedSchema,
  koboPlaceRefusedSchema,
  koboReaderEnvelopeSchema,
  koboReadersSchema,
  koboRejectedSchema,
  koboRevokedSchema,
  koboSentSchema,
  koboSetupSchema,
  type BookKobo,
  type KoboChanged,
  type KoboDelivery,
  type KoboPlaceRefused,
  type KoboReader,
  type KoboReaderEnvelope,
  type KoboReaders,
  type KoboRejected,
  type KoboRevoked,
  type KoboSent,
  type KoboSettings,
  type KoboSetup,
} from "./contract";

export type NewKoboReader = KoboSettings & { name: string; base_url: string };
export type FieldErrors = Record<string, string[]>;

export type CreateAnswer = { kind: "created"; setup: KoboSetup } | { kind: "rejected"; errors: FieldErrors; messages: string[] };
export type SettingsAnswer = { kind: "saved"; reader: KoboReader; notice: string } | { kind: "rejected"; errors: FieldErrors; messages: string[] } | { kind: "changed"; reader: KoboReader };
export type AddressAnswer = { kind: "created"; setup: KoboSetup } | { kind: "changed"; reader: KoboReader };
export type RevokeAnswer = { kind: "revoked"; notice: string } | { kind: "changed"; reader: KoboReader };
export type PlaceAnswer = { kind: "chosen"; reader: KoboReader; notice: string } | { kind: "refused"; reader: KoboReader; message: string };

const account = (value: { account: string }) => value.account;
const readerPath = (id: string) => `/account/kobo_readers/${encodeURIComponent(id)}`;

export function readers(api: ApiClient, signal?: AbortSignal): Promise<KoboReaders> {
  return api.request({ path: "/account/kobo_readers", schema: koboReadersSchema, signal, account });
}

export async function reader(api: ApiClient, id: string, signal?: AbortSignal): Promise<KoboReader> {
  const envelope = await api.request({ path: readerPath(id), schema: koboReaderEnvelopeSchema, signal, account });
  return envelope.reader;
}

export async function createReader(api: ApiClient, values: NewKoboReader): Promise<CreateAnswer> {
  const answer = await api.request<KoboSetup | KoboRejected>({ path: "/account/kobo_readers", schema: koboSetupSchema, rejection: koboRejectedSchema, method: "POST", body: values, account });
  return "error" in answer ? { kind: "rejected", errors: answer.errors, messages: answer.messages } : { kind: "created", setup: answer };
}

export async function saveSettings(api: ApiClient, id: string, values: KoboSettings, version: string): Promise<SettingsAnswer> {
  const answer = await api.request<KoboReaderEnvelope | KoboRejected | KoboChanged>({
    path: readerPath(id),
    schema: koboReaderEnvelopeSchema,
    rejection: koboRejectedSchema,
    conflict: koboChangedSchema,
    method: "PUT",
    body: { ...values, version },
    account,
  });
  if (!("error" in answer)) return { kind: "saved", reader: answer.reader, notice: answer.notice ?? "Reader settings saved." };
  return answer.error === "invalid_reader" ? { kind: "rejected", errors: answer.errors, messages: answer.messages } : { kind: "changed", reader: answer.reader };
}

export async function newAddress(api: ApiClient, id: string, version: string): Promise<AddressAnswer> {
  const answer = await api.request<KoboSetup | KoboChanged>({ path: `${readerPath(id)}/connection_address`, schema: koboSetupSchema, conflict: koboChangedSchema, method: "POST", body: { version }, account });
  return "error" in answer ? { kind: "changed", reader: answer.reader } : { kind: "created", setup: answer };
}

export async function revoke(api: ApiClient, id: string, version: string): Promise<RevokeAnswer> {
  const answer = await api.request<KoboRevoked | KoboChanged>({ path: `${readerPath(id)}/revoke`, schema: koboRevokedSchema, conflict: koboChangedSchema, method: "POST", body: { version }, account });
  return "error" in answer ? { kind: "changed", reader: answer.reader } : { kind: "revoked", notice: answer.notice };
}

export function sendBook(api: ApiClient, id: string, bookId: string): Promise<KoboSent> {
  return api.request({ path: `${readerPath(id)}/send`, schema: koboSentSchema, method: "POST", body: { book_id: bookId }, account });
}

export async function choosePlace(api: ApiClient, id: string, delivery: Pick<KoboDelivery, "entitlement_id" | "choice">, place: "kobo" | "shelfarr"): Promise<PlaceAnswer> {
  const answer = await api.request<KoboReaderEnvelope | KoboPlaceRefused>({
    path: `${readerPath(id)}/places/${place}`,
    schema: koboReaderEnvelopeSchema,
    conflict: koboPlaceRefusedSchema,
    method: "POST",
    body: { entitlement_id: delivery.entitlement_id, choice: delivery.choice },
    account,
  });
  return "error" in answer ? { kind: "refused", reader: answer.reader, message: answer.message } : { kind: "chosen", reader: answer.reader, notice: answer.notice ?? "" };
}

export async function bookReaders(api: ApiClient, publicationId: string, signal?: AbortSignal): Promise<BookKobo> {
  const answer = await api.request({ path: `/library/${encodeURIComponent(publicationId)}/kobo`, schema: bookKoboSchema, signal, account });
  return answer.kobo;
}
