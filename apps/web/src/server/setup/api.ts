import type { ApiClient } from "../../api/client";
import { setupMovedSchema, setupRejectedSchema, setupSavedSchema, setupStateSchema, type SetupMoved, type SetupRejected, type SetupSaved, type SetupState, type SetupStepId } from "./contract";

export type SetupValues = Record<string, string | boolean>;
export type SetupSaveAnswer = { kind: "saved"; saved: SetupSaved } | { kind: "rejected"; message: string };

const account = (value: { account: string }) => value.account;

export function setupState(api: ApiClient, step: string | undefined, signal?: AbortSignal): Promise<SetupState> {
  const query = step ? `?${new URLSearchParams({ step })}` : "";
  return api.request({ path: `/admin/setup${query}`, schema: setupStateSchema, signal, account });
}

export async function saveSetupStep(api: ApiClient, step: SetupStepId, values: SetupValues, signal?: AbortSignal): Promise<SetupSaveAnswer> {
  const answer = await api.request<SetupSaved | SetupRejected>({
    path: `/admin/setup/steps/${encodeURIComponent(step)}`,
    schema: setupSavedSchema,
    rejection: setupRejectedSchema,
    method: "PUT",
    body: { values },
    signal,
    account,
  });
  return "outcome" in answer ? { kind: "saved", saved: answer } : { kind: "rejected", message: answer.message };
}

export function skipSetup(api: ApiClient, step: SetupStepId, exit: boolean, signal?: AbortSignal): Promise<SetupMoved> {
  return api.request({ path: "/admin/setup/skip", schema: setupMovedSchema, method: "POST", body: { step, exit }, signal, account });
}

export function restartSetup(api: ApiClient, signal?: AbortSignal): Promise<SetupMoved> {
  return api.request({ path: "/admin/setup/restart", schema: setupMovedSchema, method: "POST", body: {}, signal, account });
}
