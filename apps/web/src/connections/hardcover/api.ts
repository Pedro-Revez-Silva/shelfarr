import type { ApiClient } from "../../api/client";
import {
  hardcoverAuthorizationSchema,
  hardcoverDevicePollSchema,
  hardcoverEnvelopeSchema,
  hardcoverRefusalSchema,
  type HardcoverDevicePoll,
  type HardcoverEnvelope,
  type HardcoverRefusal,
  type HardcoverState,
} from "./contract";

export type HardcoverAnswer = { kind: "done"; hardcover: HardcoverState; notice: string | null } | { kind: "refused"; hardcover: HardcoverState; message: string; changed: boolean };
export type AuthorizeAnswer = { kind: "redirect"; url: string } | Extract<HardcoverAnswer, { kind: "refused" }>;
export type Version = string | null;

const account = (value: { account: string }) => value.account;
const ROOT = "/account/hardcover";

function refused(answer: HardcoverRefusal): Extract<HardcoverAnswer, { kind: "refused" }> {
  return { kind: "refused", hardcover: answer.hardcover, message: answer.message, changed: answer.error === "hardcover_changed" };
}

export async function state(api: ApiClient, signal?: AbortSignal): Promise<HardcoverState> {
  return (await api.request({ path: ROOT, schema: hardcoverEnvelopeSchema, signal, account })).hardcover;
}

async function write(api: ApiClient, path: string, body: unknown): Promise<HardcoverAnswer> {
  const answer = await api.request<HardcoverEnvelope | HardcoverRefusal>({ path: `${ROOT}${path}`, schema: hardcoverEnvelopeSchema, conflict: hardcoverRefusalSchema, rejection: hardcoverRefusalSchema, method: "POST", body, account });
  if ("error" in answer) return refused(answer);
  return { kind: "done", hardcover: answer.hardcover, notice: answer.notice ?? null };
}

export function connectApiKey(api: ApiClient, apiKey: string, version: Version): Promise<HardcoverAnswer> {
  return write(api, "/api_key", { api_key: apiKey, version });
}

export function startCode(api: ApiClient, version: Version): Promise<HardcoverAnswer> {
  return write(api, "/device", { version });
}

export function cancelCode(api: ApiClient, userCode: string): Promise<HardcoverAnswer> {
  return write(api, "/device/cancel", { user_code: userCode });
}

export function disconnect(api: ApiClient, version: string): Promise<HardcoverAnswer> {
  return write(api, "/disconnect", { version });
}

export async function authorize(api: ApiClient, version: Version): Promise<AuthorizeAnswer> {
  const answer = await api.request<{ account: string; authorization_url: string } | HardcoverRefusal>({
    path: `${ROOT}/authorize`,
    schema: hardcoverAuthorizationSchema,
    conflict: hardcoverRefusalSchema,
    method: "POST",
    body: { version },
    account,
  });
  return "error" in answer ? refused(answer) : { kind: "redirect", url: answer.authorization_url };
}

export async function pollCode(api: ApiClient, signal?: AbortSignal): Promise<HardcoverDevicePoll | Extract<HardcoverAnswer, { kind: "refused" }>> {
  const answer = await api.request<HardcoverDevicePoll | HardcoverRefusal>({ path: `${ROOT}/device/poll`, schema: hardcoverDevicePollSchema, conflict: hardcoverRefusalSchema, method: "POST", body: {}, signal, account });
  return "error" in answer ? refused(answer) : answer;
}
