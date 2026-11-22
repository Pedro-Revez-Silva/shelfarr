import { z } from "zod";
import type { ApiClient } from "../api/client";
import { serverOverviewSchema, type ServerOverview } from "../contract";
import {
  actionAnswerSchema,
  groupRejectedSchema,
  groupSavedSchema,
  libraryInventorySchema,
  probeAnswerSchema,
  serverSettingsSchema,
  telegramChatActionSchema,
  telegramChatsSchema,
  type GroupRejected,
  type GroupSaved,
  type LibraryInventory,
  type Outcome,
  type ServerSettings,
  type TelegramChat,
  type TelegramChatAction,
} from "./contract";

export type SubmittedValue = string | string[] | null;
export type SubmittedValues = Record<string, SubmittedValue>;

export type GroupSaveAnswer = { kind: "saved"; saved: GroupSaved } | { kind: "rejected"; errors: GroupRejected["errors"] };

const overviewActionSchema = z.looseObject({ account: z.string(), outcome: z.object({ tone: z.enum(["success", "error"]), message: z.string() }) });

const account = (value: { account: string }) => value.account;

export function serverSettings(api: ApiClient, signal?: AbortSignal): Promise<ServerSettings> {
  return api.request({ path: "/admin/settings", schema: serverSettingsSchema, signal, account });
}

export async function saveGroup(api: ApiClient, group: string, values: SubmittedValues, signal?: AbortSignal): Promise<GroupSaveAnswer> {
  const answer = await api.request<GroupSaved | GroupRejected>({
    path: `/admin/settings/groups/${encodeURIComponent(group)}`,
    schema: groupSavedSchema,
    rejection: groupRejectedSchema,
    method: "PUT",
    body: { values },
    signal,
    account,
  });
  return "outcome" in answer ? { kind: "saved", saved: answer } : { kind: "rejected", errors: answer.errors };
}

export async function runProbe(api: ApiClient, probe: string, values: SubmittedValues, signal?: AbortSignal): Promise<Outcome> {
  const answer = await api.request({ path: `/admin/settings/probes/${encodeURIComponent(probe)}`, schema: probeAnswerSchema, method: "POST", body: { values }, signal, account });
  return answer.outcome;
}

export function libraryInventory(api: ApiClient, signal?: AbortSignal): Promise<LibraryInventory> {
  return api.request({ path: "/admin/settings/library", schema: libraryInventorySchema, signal, account });
}

export async function syncLibrary(api: ApiClient, signal?: AbortSignal): Promise<Outcome> {
  const answer = await api.request({ path: "/admin/settings/library/sync", schema: actionAnswerSchema, method: "POST", body: {}, signal, account });
  return answer.outcome;
}

export async function telegramChats(api: ApiClient, signal?: AbortSignal): Promise<TelegramChat[]> {
  const answer = await api.request({ path: "/admin/settings/telegram_chats", schema: telegramChatsSchema, signal, account });
  return answer.chats;
}

export type TelegramChatCommand = { kind: "approve"; code: string } | { kind: "pause" | "resume" | "remove"; id: string };

export function telegramChatCommand(api: ApiClient, command: TelegramChatCommand, signal?: AbortSignal): Promise<TelegramChatAction> {
  const base = "/admin/settings/telegram_chats";
  switch (command.kind) {
    case "approve":
      return api.request({ path: base, schema: telegramChatActionSchema, method: "POST", body: { code: command.code }, signal, account });
    case "remove":
      return api.request({ path: `${base}/${encodeURIComponent(command.id)}`, schema: telegramChatActionSchema, method: "DELETE", signal, account });
    default:
      return api.request({ path: `${base}/${encodeURIComponent(command.id)}/${command.kind}`, schema: telegramChatActionSchema, method: "POST", body: {}, signal, account });
  }
}

export type OverviewAction = "health_check" | "update_check";

export async function runOverviewAction(api: ApiClient, action: OverviewAction, signal?: AbortSignal): Promise<{ outcome: Outcome; overview: ServerOverview | null }> {
  const answer = await api.request({ path: `/admin/overview/${action}`, schema: overviewActionSchema, method: "POST", body: {}, signal, account });
  const overview = serverOverviewSchema.safeParse(answer);
  return { outcome: answer.outcome, overview: overview.success ? overview.data : null };
}
