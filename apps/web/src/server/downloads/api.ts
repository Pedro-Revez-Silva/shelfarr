import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import type { z } from "zod";
import type { ApiClient } from "../../api/client";
import { failureKind } from "../../api/errors";
import { useServices } from "../../services";
import { useIsAdministrator, useServerKeys } from "../queries";
import { downloadsActionSchema, downloadsChangedSchema, downloadsRejectedSchema, downloadsSchema, type Downloads, type DownloadsAction, type DownloadsRejection } from "./contract";

export type RecordValues = Record<string, string | boolean>;

export type DownloadsCommand =
  | { kind: "create_client"; values: RecordValues }
  | { kind: "update_client"; id: string; version: string; values: RecordValues }
  | { kind: "remove_client"; id: string; version: string; rules: string[] }
  | { kind: "test_client"; id: string }
  | { kind: "move_client"; id: string; version: string; neighbour: string; direction: "up" | "down" }
  | { kind: "create_rule"; values: RecordValues }
  | { kind: "update_rule"; id: string; version: string; values: RecordValues }
  | { kind: "remove_rule"; id: string; version: string };

export type DownloadsAnswer = { kind: "done"; action: DownloadsAction } | { kind: "changed"; downloads: Downloads } | { kind: "rejected"; errors: DownloadsRejection };

type Body = DownloadsAction | z.infer<typeof downloadsChangedSchema> | z.infer<typeof downloadsRejectedSchema>;

const account = (value: { account: string }) => value.account;
const BASE = "/admin/downloads";

export function downloads(api: ApiClient, signal?: AbortSignal): Promise<Downloads> {
  return api.request({ path: BASE, schema: downloadsSchema, signal, account });
}

function route(command: DownloadsCommand): { path: string; method: "POST" | "PUT" | "DELETE"; body: unknown } {
  switch (command.kind) {
    case "create_client":
      return { path: `${BASE}/clients`, method: "POST", body: { client: command.values } };
    case "update_client":
      return { path: `${BASE}/clients/${encodeURIComponent(command.id)}`, method: "PUT", body: { version: command.version, client: command.values } };
    case "remove_client":
      return { path: `${BASE}/clients/${encodeURIComponent(command.id)}`, method: "DELETE", body: { version: command.version, rules: command.rules } };
    case "test_client":
      return { path: `${BASE}/clients/${encodeURIComponent(command.id)}/test`, method: "POST", body: {} };
    case "move_client":
      return { path: `${BASE}/clients/${encodeURIComponent(command.id)}/move`, method: "POST", body: { version: command.version, neighbour: command.neighbour, direction: command.direction } };
    case "create_rule":
      return { path: `${BASE}/rules`, method: "POST", body: { rule: command.values } };
    case "update_rule":
      return { path: `${BASE}/rules/${encodeURIComponent(command.id)}`, method: "PUT", body: { version: command.version, rule: command.values } };
    case "remove_rule":
      return { path: `${BASE}/rules/${encodeURIComponent(command.id)}`, method: "DELETE", body: { version: command.version } };
  }
}

export async function runDownloadsCommand(api: ApiClient, command: DownloadsCommand, signal?: AbortSignal): Promise<DownloadsAnswer> {
  const { path, method, body } = route(command);
  const answer = await api.request<Body>({
    path,
    method,
    body,
    signal,
    schema: downloadsActionSchema,
    conflict: downloadsChangedSchema,
    rejection: downloadsRejectedSchema,
    account,
  });
  if ("errors" in answer) return { kind: "rejected", errors: answer.errors };
  if ("error" in answer) return { kind: "changed", downloads: answer };
  return { kind: "done", action: answer };
}

export function useDownloadsKey() {
  return [...useServerKeys().root, "downloads"] as const;
}

export function useDownloads() {
  const { api } = useServices();
  const key = useDownloadsKey();
  return useQuery({ queryKey: key, queryFn: ({ signal }) => downloads(api, signal), enabled: useIsAdministrator(), refetchOnWindowFocus: false, staleTime: 0 });
}

export function useDownloadsCommand() {
  const { api, guard, keys } = useServices();
  const serverKeys = useServerKeys();
  const key = useDownloadsKey();
  const client = useQueryClient();
  return useMutation({
    mutationFn: (command: DownloadsCommand) => runDownloadsCommand(api, command),
    onSuccess: async (answer) => {
      if (!guard.isActive() || answer.kind === "rejected") return;
      void client.invalidateQueries({ queryKey: keys.serverOverview });
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
