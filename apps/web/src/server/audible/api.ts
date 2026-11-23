import { keepPreviousData, useMutation, useQuery, useQueryClient, type QueryClient, type UseQueryResult } from "@tanstack/react-query";
import { useEffect, useRef, useState } from "react";
import type { ApiClient } from "../../api/client";
import { failureKind } from "../../api/errors";
import { useServices } from "../../services";
import { useIsAdministrator, useServerKeys } from "../queries";
import { audibleActionSchema, audibleRejectedSchema, audibleSchema, catalogueSchema, revisionSchema, type Audible, type AudibleAction, type AudibleRejection, type Catalogue } from "./contract";

export type CompanionValues = { url: string; bridge_token: string; enabled: boolean; allow_private_network: boolean; timeout_seconds: string };
export type AutomationValues = { scheduled_sync_enabled: boolean; scheduled_sync_interval_minutes: number; automatic_backup_enabled: boolean };

export type AudibleCommand =
  | { kind: "save"; values: CompanionValues }
  | { kind: "test" }
  | { kind: "start_sign_in"; account: string; locale: string; reregister: boolean }
  | { kind: "complete_sign_in"; sign_in_token: string; response_url: string }
  | { kind: "sync" }
  | { kind: "back_up_existing" }
  | { kind: "dismiss_existing" }
  | { kind: "automation"; values: AutomationValues }
  | { kind: "back_up_item"; id: string; separate_edition: boolean };

export type AudibleAnswer = { kind: "done"; action: AudibleAction } | { kind: "rejected"; errors: AudibleRejection };

const BASE = "/admin/audible";
const POLL_MS = 5_000;
const IDLE_POLL_MS = 20_000;
const account = (value: { account: string }) => value.account;

export function audible(api: ApiClient, signal?: AbortSignal): Promise<Audible> {
  return api.request({ path: BASE, schema: audibleSchema, signal, account });
}

export function revision(api: ApiClient, signal?: AbortSignal): Promise<string> {
  return api.request({ path: `${BASE}/revision`, schema: revisionSchema, signal, account }).then((answer) => answer.revision);
}

export function catalogue(api: ApiClient, query: string, page: number, signal?: AbortSignal): Promise<Catalogue> {
  const params = new URLSearchParams();
  if (query.trim() !== "") params.set("q", query);
  if (page > 1) params.set("page", String(page));
  const text = params.toString();
  return api.request({ path: `${BASE}/catalogue${text ? `?${text}` : ""}`, schema: catalogueSchema, signal, account });
}

function route(command: AudibleCommand): { path: string; method: "POST" | "PUT"; body: unknown } {
  switch (command.kind) {
    case "save":
      return { path: `${BASE}/companion`, method: "PUT", body: { companion: command.values } };
    case "test":
      return { path: `${BASE}/test`, method: "POST", body: {} };
    case "start_sign_in":
      return { path: `${BASE}/sign_in`, method: "POST", body: { account: command.account, locale: command.locale, reregister: command.reregister } };
    case "complete_sign_in":
      return { path: `${BASE}/sign_in/complete`, method: "POST", body: { sign_in_token: command.sign_in_token, response_url: command.response_url } };
    case "sync":
      return { path: `${BASE}/sync`, method: "POST", body: {} };
    case "back_up_existing":
      return { path: `${BASE}/existing_backup`, method: "POST", body: { confirm: true } };
    case "dismiss_existing":
      return { path: `${BASE}/existing_backup/dismiss`, method: "POST", body: {} };
    case "automation":
      return { path: `${BASE}/automation`, method: "PUT", body: { automation: command.values } };
    case "back_up_item":
      return { path: `${BASE}/items/${encodeURIComponent(command.id)}/backup`, method: "POST", body: { separate_edition: command.separate_edition } };
  }
}

export async function runAudibleCommand(api: ApiClient, command: AudibleCommand, signal?: AbortSignal): Promise<AudibleAnswer> {
  const { path, method, body } = route(command);
  const answer = await api.request<AudibleAction | { account: string; error: "invalid_record"; errors: AudibleRejection }>({
    path,
    method,
    body,
    signal,
    schema: audibleActionSchema,
    rejection: audibleRejectedSchema,
    account,
  });
  if ("errors" in answer) return { kind: "rejected", errors: answer.errors };
  return { kind: "done", action: answer };
}

export function useAudibleKeys() {
  const root = [...useServerKeys().root, "audible"] as const;
  return { state: [...root, "state"] as const, catalogue: [...root, "catalogue"] as const, revision: [...root, "revision"] as const };
}

export function useAudible() {
  const { api } = useServices();
  const keys = useAudibleKeys();
  return useQuery({
    queryKey: keys.state,
    queryFn: ({ signal }) => audible(api, signal),
    enabled: useIsAdministrator(),
    refetchOnWindowFocus: false,
    refetchInterval: (query) => (query.state.data?.working ? POLL_MS : false),
    staleTime: 0,
  });
}

async function readAgain(client: QueryClient, queryKey: readonly unknown[]) {
  await client.cancelQueries({ queryKey });
  await client.invalidateQueries({ queryKey });
}

export function useIdleRevision(current: Audible | undefined) {
  const { api } = useServices();
  const keys = useAudibleKeys();
  const client = useQueryClient();
  const idle = current !== undefined && !current.working;
  const latest = useQuery({
    queryKey: keys.revision,
    queryFn: ({ signal }) => revision(api, signal),
    enabled: useIsAdministrator() && idle,
    refetchOnWindowFocus: false,
    refetchInterval: IDLE_POLL_MS,
    staleTime: 0,
  });
  const changed = idle && latest.data !== undefined && latest.data !== current.revision;
  const denied = latest.isError && failureKind(latest.error) === "not_found";
  useEffect(() => {
    if (!changed && !denied) return;
    void client.invalidateQueries({ queryKey: keys.state });
    void readAgain(client, keys.catalogue);
  }, [changed, denied, client, keys.state, keys.catalogue]);
  const working = current?.working ?? false;
  const wasWorking = useRef(working);
  useEffect(() => {
    if (wasWorking.current && !working) void readAgain(client, keys.catalogue);
    wasWorking.current = working;
  }, [working, client, keys.catalogue]);
  return changed;
}

export function useCatalogue(query: string, page: number, working: boolean) {
  const { api } = useServices();
  const keys = useAudibleKeys();
  return useQuery({
    queryKey: [...keys.catalogue, query, page] as const,
    queryFn: ({ signal }) => catalogue(api, query, page, signal),
    enabled: useIsAdministrator(),
    placeholderData: keepPreviousData,
    refetchOnWindowFocus: false,
    refetchInterval: working ? POLL_MS : false,
    staleTime: 0,
  });
}

export function useCurrentCatalogue(catalogue: UseQueryResult<Catalogue>, generation: string) {
  const client = useQueryClient();
  const keys = useAudibleKeys();
  const shown = catalogue.data?.generation;
  const outdated = shown !== undefined && shown !== generation;
  const pair = `${shown ?? ""}|${generation}`;
  const requested = useRef<string | null>(null);
  const [settled, setSettled] = useState<string | null>(null);
  const { isError, isFetching, refetch } = catalogue;
  const readBoth = (target: string) => {
    requested.current = target;
    void client.invalidateQueries({ queryKey: keys.state });
    void refetch({ cancelRefetch: false }).finally(() => setSettled(target));
  };
  useEffect(() => {
    if (outdated && !isError && requested.current !== pair) readBoth(pair);
  });
  return {
    current: !outdated,
    stuck: outdated && !isFetching && (isError || settled === pair),
    retry: () => {
      setSettled(null);
      readBoth(pair);
    },
  };
}

export function useAudibleCommand() {
  const { api, guard, keys: appKeys } = useServices();
  const serverKeys = useServerKeys();
  const keys = useAudibleKeys();
  const client = useQueryClient();
  return useMutation({
    mutationFn: (command: AudibleCommand) => runAudibleCommand(api, command),
    onSuccess: async (answer) => {
      if (!guard.isActive() || answer.kind !== "done") return;
      await client.cancelQueries({ queryKey: keys.state });
      await client.cancelQueries({ queryKey: keys.revision });
      const state = audibleSchema.parse(answer.action);
      client.setQueryData<Audible>(keys.state, state);
      client.setQueryData<string>(keys.revision, state.revision);
      void readAgain(client, keys.catalogue);
    },
    onError: (error) => {
      if (!guard.isActive()) return;
      void client.invalidateQueries({ queryKey: keys.state });
      void client.invalidateQueries({ queryKey: keys.catalogue });
      if (failureKind(error) === "not_found") {
        void client.invalidateQueries({ queryKey: serverKeys.settings });
        void client.invalidateQueries({ queryKey: appKeys.session });
      }
    },
  });
}
