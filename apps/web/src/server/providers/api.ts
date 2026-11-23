import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import type { z } from "zod";
import type { ApiClient } from "../../api/client";
import { failureKind } from "../../api/errors";
import { useServices } from "../../services";
import type { RecordValues } from "../downloads/api";
import { useIsAdministrator, useServerKeys } from "../queries";
import { providersActionSchema, providersChangedSchema, providersRejectedSchema, providersSchema, type Providers, type ProvidersAction, type ProvidersRejection } from "./contract";

export type ProvidersCommand =
  | { kind: "create"; values: RecordValues }
  | { kind: "update"; id: string; version: string; values: RecordValues }
  | { kind: "remove"; id: string; version: string }
  | { kind: "test"; id: string };

export type ProvidersAnswer = { kind: "done"; action: ProvidersAction } | { kind: "changed"; providers: Providers } | { kind: "rejected"; errors: ProvidersRejection };

type Body = ProvidersAction | z.infer<typeof providersChangedSchema> | z.infer<typeof providersRejectedSchema>;

const account = (value: { account: string }) => value.account;
const BASE = "/admin/acquisition_providers";

export function providers(api: ApiClient, signal?: AbortSignal): Promise<Providers> {
  return api.request({ path: BASE, schema: providersSchema, signal, account });
}

function route(command: ProvidersCommand): { path: string; method: "POST" | "PUT" | "DELETE"; body: unknown } {
  switch (command.kind) {
    case "create":
      return { path: BASE, method: "POST", body: { provider: command.values } };
    case "update":
      return { path: `${BASE}/${encodeURIComponent(command.id)}`, method: "PUT", body: { version: command.version, provider: command.values } };
    case "remove":
      return { path: `${BASE}/${encodeURIComponent(command.id)}`, method: "DELETE", body: { version: command.version } };
    case "test":
      return { path: `${BASE}/${encodeURIComponent(command.id)}/test`, method: "POST", body: {} };
  }
}

export async function runProvidersCommand(api: ApiClient, command: ProvidersCommand, signal?: AbortSignal): Promise<ProvidersAnswer> {
  const { path, method, body } = route(command);
  const answer = await api.request<Body>({
    path,
    method,
    body,
    signal,
    schema: providersActionSchema,
    conflict: providersChangedSchema,
    rejection: providersRejectedSchema,
    account,
  });
  if ("errors" in answer) return { kind: "rejected", errors: answer.errors };
  if ("error" in answer) return { kind: "changed", providers: answer };
  return { kind: "done", action: answer };
}

export function useProvidersKey() {
  return [...useServerKeys().root, "acquisition_providers"] as const;
}

export function useProviders() {
  const { api } = useServices();
  const key = useProvidersKey();
  return useQuery({ queryKey: key, queryFn: ({ signal }) => providers(api, signal), enabled: useIsAdministrator(), refetchOnWindowFocus: false, staleTime: 0 });
}

export function useProvidersCommand() {
  const { api, guard, keys } = useServices();
  const serverKeys = useServerKeys();
  const key = useProvidersKey();
  const client = useQueryClient();
  return useMutation({
    mutationFn: (command: ProvidersCommand) => runProvidersCommand(api, command),
    onSuccess: async (answer) => {
      if (!guard.isActive() || answer.kind === "rejected") return;
      await client.invalidateQueries({ queryKey: key });
    },
    onError: (error) => {
      if (!guard.isActive()) return;
      void client.invalidateQueries({ queryKey: key });
      if (failureKind(error) === "not_found") {
        void client.invalidateQueries({ queryKey: serverKeys.settings });
        void client.invalidateQueries({ queryKey: keys.session });
      }
    },
  });
}
