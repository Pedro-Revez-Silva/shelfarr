import type { ApiClient } from "../../api/client";
import {
  ownAccountSchema,
  peopleSchema,
  personChangedSchema,
  personEnvelopeSchema,
  personRejectedSchema,
  personRemovedSchema,
  type OwnAccount,
  type People,
  type PersonChanged,
  type PersonEnvelope,
  type PersonRejected,
  type PersonRemoved,
  type PersonRole,
} from "./contract";

export type FieldErrors = Record<string, string[]>;
export type ProfileValues = { name: string; username: string; role: PersonRole };
export type NewPerson = ProfileValues & { password: string; password_confirmation: string };
export type PasswordValues = { password: string; password_confirmation: string };

export type Refusal = { kind: "rejected"; errors: FieldErrors } | { kind: "own_account"; message: string } | { kind: "changed"; person: PersonEnvelope };
export type PersonAnswer = { kind: "saved"; person: PersonEnvelope } | Refusal;
export type RemovalAnswer = { kind: "removed"; id: string } | Refusal;

const account = (value: { account: string }) => value.account;
const refusal = personRejectedSchema.or(ownAccountSchema);

function refused(answer: PersonRejected | OwnAccount | PersonChanged): Refusal {
  switch (answer.error) {
    case "invalid_user":
      return { kind: "rejected", errors: answer.errors };
    case "own_account":
      return { kind: "own_account", message: answer.message };
    default:
      return { kind: "changed", person: { account: answer.account, user: answer.user, administrators: answer.administrators } };
  }
}

function personAnswer(answer: PersonEnvelope | PersonRejected | OwnAccount | PersonChanged): PersonAnswer {
  return "error" in answer ? refused(answer) : { kind: "saved", person: answer };
}

const personPath = (id: string) => `/admin/users/${encodeURIComponent(id)}`;

export function people(api: ApiClient, signal?: AbortSignal): Promise<People> {
  return api.request({ path: "/admin/users", schema: peopleSchema, signal, account });
}

export function person(api: ApiClient, id: string, signal?: AbortSignal): Promise<PersonEnvelope> {
  return api.request({ path: personPath(id), schema: personEnvelopeSchema, signal, account });
}

export async function addPerson(api: ApiClient, values: NewPerson): Promise<PersonAnswer> {
  return personAnswer(await api.request<PersonEnvelope | PersonRejected | OwnAccount>({ path: "/admin/users", schema: personEnvelopeSchema, rejection: refusal, method: "POST", body: values, account }));
}

export async function saveProfile(api: ApiClient, id: string, values: ProfileValues, version: string): Promise<PersonAnswer> {
  return personAnswer(
    await api.request<PersonEnvelope | PersonRejected | OwnAccount | PersonChanged>({
      path: personPath(id),
      schema: personEnvelopeSchema,
      rejection: refusal,
      conflict: personChangedSchema,
      method: "PUT",
      body: { ...values, version },
      account,
    }),
  );
}

export async function setPassword(api: ApiClient, id: string, values: PasswordValues): Promise<PersonAnswer> {
  return personAnswer(await api.request<PersonEnvelope | PersonRejected | OwnAccount>({ path: `${personPath(id)}/password`, schema: personEnvelopeSchema, rejection: refusal, method: "PUT", body: values, account }));
}

export async function removePerson(api: ApiClient, id: string, version: string): Promise<RemovalAnswer> {
  const answer = await api.request<PersonRemoved | PersonRejected | OwnAccount | PersonChanged>({
    path: `${personPath(id)}/remove`,
    schema: personRemovedSchema,
    rejection: refusal,
    conflict: personChangedSchema,
    method: "POST",
    body: { version },
    account,
  });
  return "error" in answer ? refused(answer) : { kind: "removed", id: answer.removed };
}
